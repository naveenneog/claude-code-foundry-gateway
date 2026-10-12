import assert from 'node:assert/strict';
import { once } from 'node:events';
import { existsSync, readFileSync } from 'node:fs';
import { mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { StringDecoder } from 'node:string_decoder';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { validatePreflight, validateProgressEvent, validateStepList } from '../tools/installer-ui/installer-contract.mjs';
import { createAzureLease } from '../tools/installer-ui/azure-lease.mjs';
import { createInstallerUiServer } from '../tools/installer-ui/server.mjs';
import { preflightFingerprint } from '../tools/installer-ui/preflight-record.mjs';
import { readProgressFile } from '../tools/installer-ui/run-transport.mjs';

const stubInstaller = fileURLToPath(new URL('./installer-ui-stub.mjs', import.meta.url));
const passingAnswers = { schemaVersion: 1, SubscriptionId: '00000000-0000-4000-8000-000000000093' };
const identityOne = { signedIn: true, user: 'operator@example.com', tenantId: 'tenant-1', subscriptionId: '00000000-0000-4000-8000-000000000093' };

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function alive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function start(extra = {}) {
  const scratch = join(tmpdir(), `p93-g7-${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`);
  await rm(scratch, { recursive: true, force: true });
  await mkdir(scratch, { recursive: true });
  const log = join(scratch, 'stub.ndjson');
  const logs = [];
  const env = { P93_INSTALLER_UI_STUB_LOG: log, ...(extra.env || {}) };
  if (extra.az) {
    const az = join(scratch, 'az.cmd');
    const accountFile = join(scratch, 'account.json');
    await writeFile(accountFile, JSON.stringify({ id: identityOne.subscriptionId, name: 'Sub One', tenantId: identityOne.tenantId, user: { name: identityOne.user } }), 'utf8');
    await writeFile(az, `@echo off\r\nnode "${az.replace(/\\/g, '\\\\')}.mjs" %*\r\n`, 'utf8');
    await writeFile(`${az}.mjs`, `
import { readFileSync } from 'node:fs';
const joined = process.argv.slice(2).join(' ');
if (joined.startsWith('account show')) { console.log(readFileSync(process.env.P93_G7_ACCOUNT_FILE, 'utf8')); process.exit(0); }
console.error('unexpected az ' + joined); process.exit(2);
`, 'utf8');
    env.PATH = `${scratch};${process.env.PATH}`;
    env.P93_G7_ACCOUNT_FILE = accountFile;
  }
  const server = await createInstallerUiServer({
    token: 'g7-token-with-at-least-32-bytes-0000',
    csrfToken: 'g7-csrf-token-with-at-least-32-bytes',
    stubInstaller: extra.stubInstaller || stubInstaller,
    idleMs: 60_000,
    env,
    log: (line) => logs.push(line),
    readIdentity: extra.az ? extra.readIdentity : (extra.readIdentity ?? (async () => identityOne)),
    beforeRunSpawn: extra.beforeRunSpawn,
    readOnlyTimeoutMs: extra.readOnlyTimeoutMs,
    readOnlyOutputCapBytes: extra.readOnlyOutputCapBytes,
  });
  const address = await server.listenAsync('127.0.0.1');
  const base = `http://127.0.0.1:${address.port}`;
  const boot = await fetch(`${base}/?token=${encodeURIComponent(server.token)}`, { redirect: 'manual' });
  const cookie = boot.headers.get('set-cookie').split(';')[0];
  const session = await (await fetch(`${base}/api/session`, { headers: { cookie } })).json();
  return {
    base,
    cookie,
    csrfToken: session.csrfToken,
    log,
    logs,
    scratch,
    accountFile: env.P93_G7_ACCOUNT_FILE,
    server,
    async fetch(path, options = {}) {
      const headers = { cookie, ...(options.headers || {}) };
      if (options.method === 'POST') headers['x-csrf-token'] ??= session.csrfToken;
      return fetch(`${base}${path}`, { ...options, headers });
    },
    stubCalls() {
      return existsSync(log) ? readFileSync(log, 'utf8').trim().split(/\r?\n/).filter(Boolean).map((line) => JSON.parse(line)) : [];
    },
    async close() {
      await server.cleanup();
      server.close();
      await once(server, 'close').catch(() => {});
      await rm(scratch, { recursive: true, force: true });
    },
  };
}

async function passingPreflight(app, body = {}) {
  const response = await app.fetch('/api/preflight', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ answers: { ...passingAnswers, ...(body.answers || {}) }, steps: body.steps ?? ['resource-group'] }),
  });
  const json = await response.json();
  assert.equal(response.status, 200, JSON.stringify(json));
  assert.match(json.fingerprint, /^[0-9a-f]{64}$/);
  return json;
}

async function stream(app, body) {
  const preflight = body.fingerprint ? null : await passingPreflight(app, body);
  const response = await app.fetch('/api/run/stream', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ answers: { ...passingAnswers, ...(body.answers || {}) }, steps: body.steps ?? ['resource-group'], fingerprint: body.fingerprint ?? preflight.fingerprint, fullRun: body.fullRun, confirmFullRun: body.confirmFullRun }),
  });
  const text = await response.text();
  return { response, text, events: text.trim() ? text.trim().split(/\r?\n/).map((line) => JSON.parse(line)) : [] };
}

test('S1 bootstrap token is not the session cookie before or after bootstrap', async () => {
  const app = await start();
  try {
    const tokenCookie = `installer_token=${encodeURIComponent(app.server.token)}`;
    assert.equal((await fetch(`${app.base}/api/session`, { headers: { cookie: tokenCookie } })).status, 401);
    assert.notEqual(app.cookie, tokenCookie);
    assert.equal((await fetch(`${app.base}/api/session`, { headers: { cookie: tokenCookie } })).status, 401);
    assert.equal((await fetch(`${app.base}/api/session`, { headers: { cookie: app.cookie } })).status, 200);
    const accepted = await app.fetch('/api/run/stop', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ runId: 'missing' }) });
    assert.equal(accepted.status, 404, 'the CSRF check passed and the unknown run id answered 404');
  } finally {
    await app.close();
  }
});

test('S1 bootstrap token cookie is rejected before the bootstrap request', async () => {
  const server = await createInstallerUiServer({
    token: 'g7-unbootstrapped-token-with-at-least-32-bytes',
    csrfToken: 'g7-unbootstrapped-csrf-with-at-least-32-bytes',
    stubInstaller: stubInstaller,
    idleMs: 60_000,
    readIdentity: async () => identityOne,
  });
  const address = await server.listenAsync('127.0.0.1');
  const base = `http://127.0.0.1:${address.port}`;
  const tokenCookie = `installer_token=${encodeURIComponent(server.token)}`;
  try {
    assert.equal((await fetch(`${base}/api/session`, { headers: { cookie: tokenCookie } })).status, 401);
    const boot = await fetch(`${base}/?token=${encodeURIComponent(server.token)}`, { redirect: 'manual' });
    const issuedCookie = boot.headers.get('set-cookie').split(';')[0];
    assert.equal((await fetch(`${base}/api/session`, { headers: { cookie: tokenCookie } })).status, 401);
    assert.equal((await fetch(`${base}/api/session`, { headers: { cookie: issuedCookie } })).status, 200);
  } finally {
    await server.cleanup();
    server.close();
    await once(server, 'close').catch(() => {});
  }
});

test('S2 stop requested before spawn prevents the installer child from starting', async () => {
  let releaseSpawn;
  const spawnBarrier = new Promise((resolve) => { releaseSpawn = resolve; });
  const app = await start({ beforeRunSpawn: async () => spawnBarrier });
  try {
    const preflight = await passingPreflight(app);
    const runResponse = app.fetch('/api/run/stream', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ answers: passingAnswers, steps: ['resource-group'], fingerprint: preflight.fingerprint }),
    });
    let status;
    for (let i = 0; i < 50; i++) {
      status = await (await app.fetch('/api/run/status')).json();
      if (status.id) break;
      await sleep(20);
    }
    assert.ok(status.id, 'run is visible before the child is spawned');
    const stop = await app.fetch('/api/run/stop', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ runId: status.id }) });
    assert.equal(stop.status, 200);
    releaseSpawn();
    const text = await (await runResponse).text();
    const events = text.trim().split(/\r?\n/).filter(Boolean).map((line) => JSON.parse(line));
    assert.equal(events.some((event) => event.event === 'started' || event.event === 'completed'), false);
    assert.equal(events.at(-1).state, 'stopped');
    assert.equal(app.stubCalls().some((call) => call.args.includes('-Yes')), false);
  } finally {
    await app.close();
  }
});

test('S3 queued preflights do not overlap', async () => {
  const app = await start({ env: { P93_INSTALLER_UI_STUB_PREFLIGHT_DELAY_MS: '250', P93_INSTALLER_UI_STUB_TIMES: '1' } });
  try {
    const [one, two] = await Promise.all([
      app.fetch('/api/preflight', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ answers: passingAnswers, steps: ['resource-group'] }) }),
      app.fetch('/api/preflight', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ answers: passingAnswers, steps: ['gateway-deployment'] }) }),
    ]);
    assert.equal(one.status, 200);
    assert.equal(two.status, 200);
    const endTimes = new Map(readFileSync(`${app.log}.times`, 'utf8').trim().split(/\r?\n/).filter(Boolean).map((line) => {
      const entry = JSON.parse(line);
      return [entry.pid, entry.endedAt];
    }));
    const calls = app.stubCalls().filter((call) => call.mode === 'powershell' && call.args.includes('-Preflight')).map((call) => ({ ...call, endedAt: endTimes.get(call.pid) }));
    assert.equal(calls.length, 2);
    assert.ok(calls[0].endedAt <= calls[1].startedAt, JSON.stringify(calls));
  } finally {
    await app.close();
  }
});

test('S3 Azure lease serves queued reads in arrival order and refuses run conflicts', async () => {
  const lease = createAzureLease();
  const read = await lease.acquire('identity', 'read', 1000);
  const served = [];
  const a = lease.acquire('prefill', 'read', 1000).then((entry) => {
    served.push(entry.operation);
    return entry;
  });
  const b = lease.acquire('preflight', 'read', 1000).then((entry) => {
    served.push(entry.operation);
    return entry;
  });
  await assert.rejects(() => lease.acquire('run', 'run', 1000), { status: 409, operation: 'identity' });
  read.release();
  const leaseA = await a;
  assert.deepEqual(served, ['prefill']);
  read.release();
  assert.deepEqual(served, ['prefill']);
  leaseA.release();
  const leaseB = await b;
  assert.deepEqual(served, ['prefill', 'preflight']);
  leaseB.release();

  const run = await lease.acquire('run', 'run', 0);
  await assert.rejects(() => lease.acquire('identity', 'read', 1000), { status: 409, operation: 'run' });
  await assert.rejects(() => lease.acquire('run', 'run', 0), { status: 409, operation: 'run' });
  run.release();
});

test('S3 Azure lease drops timed-out queued reads instead of serving them later', async () => {
  const lease = createAzureLease();
  const holder = await lease.acquire('identity', 'read', 1000);
  const queued = lease.acquire('preflight', 'read', 20);
  // Bounded, so a queued read that never times out fails this test instead of hanging the file.
  const settled = await Promise.race([queued.then(() => 'served', (error) => error), sleep(5000).then(() => 'still waiting after 5 s')]);
  assert.equal(settled?.status, 504, `the queued read was ${typeof settled === 'string' ? settled : 'refused another way'}; a queued read times out while it waits`);
  holder.release();
  const next = await lease.acquire('prefill', 'read', 1000);
  assert.equal(next.operation, 'prefill');
  next.release();
});

test('S3 reads are refused while a run holds the Azure lease', async () => {
  const app = await start({ env: { P93_INSTALLER_UI_STUB_DELAY_MS: '3000' } });
  try {
    const preflight = await passingPreflight(app, { steps: ['resource-group'] });
    const run = app.fetch('/api/run/stream', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ answers: passingAnswers, steps: ['resource-group'], fingerprint: preflight.fingerprint }),
    }).then((response) => response.text());
    for (let i = 0; i < 50; i++) {
      const status = await (await app.fetch('/api/run/status')).json();
      if (status.currentStepId) break;
      await sleep(20);
    }
    const identity = await app.fetch('/api/identity');
    const prefill = await app.fetch('/api/prefill', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ kind: 'subscriptions' }) });
    assert.deepEqual(await identity.json(), { error: 'Azure CLI work is already active.', reason: 'azure-busy', operation: 'run' });
    assert.deepEqual(await prefill.json(), { error: 'Azure CLI work is already active.', reason: 'azure-busy', operation: 'run' });
    await run;
  } finally {
    await app.close();
  }
});

test('S3 a run is refused while a preflight holds the Azure lease', async () => {
  const app = await start({ env: { P93_INSTALLER_UI_STUB_PREFLIGHT_DELAY_MS: '500' } });
  try {
    const slow = app.fetch('/api/preflight', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ answers: passingAnswers, steps: ['resource-group'] }) });
    await sleep(100);
    const response = await app.fetch('/api/run/stream', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ answers: passingAnswers, steps: ['resource-group'], fingerprint: '0'.repeat(64) }) });
    assert.equal(response.status, 409);
    assert.deepEqual(await response.json(), { error: 'Azure CLI work is already active.', reason: 'azure-busy', operation: 'preflight' });
    await slow;
  } finally {
    await app.close();
  }
});

test('S3 a queued read that times out while waiting starts no child', async () => {
  let releaseIdentity;
  const identityGate = new Promise((resolve) => { releaseIdentity = resolve; });
  const app = await start({ readOnlyTimeoutMs: 100, readIdentity: async () => { await identityGate; return identityOne; } });
  let second;
  try {
    const first = app.fetch('/api/identity');
    await sleep(25);
    second = app.fetch('/api/preflight', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ answers: passingAnswers, steps: ['gateway-deployment'] }) });
    // The holder is released in every case, so a queued read that never times out fails this test instead of hanging it.
    const outcome = await Promise.race([second, sleep(15_000).then(() => null)]);
    try {
      assert.ok(outcome, 'the queued preflight was still waiting after 15 s; a queued read times out while it waits');
      assert.equal(outcome.status, 504);
      assert.match((await outcome.json()).error, /preflight timed out after 100 ms/);
      assert.equal(app.stubCalls().filter((call) => call.args.includes('-Preflight')).length, 0);
    } finally {
      releaseIdentity();
    }
    assert.equal((await first).status, 200);
  } finally {
    await second?.catch(() => {});
    await app.close();
  }
});

test('S3 run-admission refusals release the Azure lease', async () => {
  let identity = identityOne;
  const app = await start({ readIdentity: async () => identity });
  try {
    const preflight = await passingPreflight(app);
    identity = { ...identityOne, tenantId: 'tenant-2' };
    const changed = await app.fetch('/api/run/stream', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ answers: passingAnswers, steps: ['resource-group'], fingerprint: preflight.fingerprint }) });
    assert.equal(changed.status, 409);
    assert.equal((await changed.json()).reason, 'identity-changed');
    assert.equal((await app.fetch('/api/identity')).status, 200);

    const missing = await app.fetch('/api/run/stream', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ answers: passingAnswers, steps: ['resource-group'], fingerprint: '0'.repeat(64) }) });
    assert.equal(missing.status, 409);
    assert.equal((await missing.json()).reason, 'preflight-required');
    assert.equal((await app.fetch('/api/identity')).status, 200);
  } finally {
    await app.close();
  }
});

test('S4 a live PFX run is refused before a run is created', async () => {
  const app = await start();
  try {
    const answers = { ...passingAnswers, AddressMode: 'custom', AddressCertificateSource: 'Pfx' };
    const preflight = await passingPreflight(app, { answers });
    const response = await app.fetch('/api/run/stream', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ answers, steps: ['resource-group'], fingerprint: preflight.fingerprint }) });
    assert.equal(response.status, 409);
    assert.deepEqual(await response.json(), { error: 'A PFX certificate is installed from a terminal because the installer asks for the PFX password only when it runs without -Yes.', reason: 'pfx-needs-terminal' });
    assert.equal(app.stubCalls().some((call) => call.args.includes('-Yes')), false);
  } finally {
    await app.close();
  }
});

test('S4 custom address runs with omitted or KeyVault certificate source are not PFX refusals', async () => {
  for (const source of [undefined, 'KeyVault']) {
    const app = await start();
    try {
      const answers = { ...passingAnswers, AddressMode: 'custom' };
      if (source) answers.AddressCertificateSource = source;
      const preflight = await passingPreflight(app, { answers });
      const response = await app.fetch('/api/run/stream', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ answers, steps: ['resource-group'], fingerprint: preflight.fingerprint }) });
      assert.notEqual(response.status, 409);
      assert.doesNotMatch(await response.text(), /pfx-needs-terminal/);
    } finally {
      await app.close();
    }
  }
});

test('S5 passing preflight returns identity and scope and the same identity is admitted', async () => {
  const app = await start();
  try {
    const preflight = await passingPreflight(app, { steps: ['gateway-deployment', 'resource-group'] });
    assert.deepEqual(preflight.identity, identityOne);
    assert.deepEqual(preflight.scope, ['gateway-deployment', 'resource-group']);
    const run = await stream(app, { steps: ['resource-group'], fingerprint: preflight.fingerprint });
    assert.equal(run.response.status, 200);
    assert.equal(run.events.at(-1).type, 'summary');
  } finally {
    await app.close();
  }
});

test('S5 failing preflight carries neither identity nor scope', async () => {
  const app = await start({ env: { P93_INSTALLER_UI_STUB_PREFLIGHT_FAIL: '1' } });
  try {
    const response = await app.fetch('/api/preflight', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ answers: passingAnswers, steps: ['resource-group'] }) });
    const body = await response.json();
    assert.equal(response.status, 200);
    assert.equal(body.preflight.result, 'FAIL');
    assert.equal(body.identity, undefined);
    assert.equal(body.scope, undefined);
  } finally {
    await app.close();
  }
});

test('S5 identity read failure after PASS prevents recording a preflight pass', async () => {
  const identityError = new Error('identity read timed out for test');
  identityError.status = 504;
  const app = await start({ readIdentity: async () => { throw identityError; } });
  try {
    const response = await app.fetch('/api/preflight', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ answers: passingAnswers, steps: ['resource-group'] }) });
    const body = await response.json();
    assert.equal(response.status, 504);
    assert.match(body.error, /identity read timed out for test/);
    const wouldBeFingerprint = preflightFingerprint({ answers: passingAnswers, scope: ['resource-group'], engine: 'pwsh' });
    const run = await app.fetch('/api/run/stream', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ answers: passingAnswers, steps: ['resource-group'], fingerprint: wouldBeFingerprint }) });
    assert.equal(run.status, 409);
    assert.equal((await run.json()).reason, 'preflight-required');
  } finally {
    await app.close();
  }
});

test('S5 default identity script detects tenant changes through fake az', async () => {
  const app = await start({ az: true });
  try {
    const preflight = await passingPreflight(app);
    await writeFile(app.accountFile, JSON.stringify({ id: identityOne.subscriptionId, name: 'Sub One', tenantId: 'tenant-2', user: { name: identityOne.user } }), 'utf8');
    const response = await app.fetch('/api/run/stream', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ answers: passingAnswers, steps: ['resource-group'], fingerprint: preflight.fingerprint }) });
    assert.equal(response.status, 409);
    const body = await response.json();
    assert.equal(body.reason, 'identity-changed');
    assert.match(body.error, /tenant changed/);
  } finally {
    await app.close();
  }
});

for (const [name, changed] of [
  ['tenant', { ...identityOne, tenantId: 'tenant-2' }],
  ['subscription', { ...identityOne, subscriptionId: '00000000-0000-4000-8000-000000000094' }],
  ['user', { ...identityOne, user: 'other@example.com' }],
]) {
  test(`S5 run is refused when the ${name} identity changes`, async () => {
    let identity = identityOne;
    const app = await start({ readIdentity: async () => identity });
    try {
      const preflight = await passingPreflight(app);
      identity = changed;
      const response = await app.fetch('/api/run/stream', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ answers: passingAnswers, steps: ['resource-group'], fingerprint: preflight.fingerprint }) });
      assert.equal(response.status, 409);
      const body = await response.json();
      assert.equal(body.reason, 'identity-changed');
      assert.match(body.error, new RegExp(`${name} changed`));
      assert.equal(app.stubCalls().some((call) => call.args.includes('-Yes')), false);
    } finally {
      await app.close();
    }
  });
}

test('S6 step list adapter rejects empty, duplicate and unknown dependency step ids', () => {
  const base = { schemaVersion: 1, installer: 'pwsh', checkpoint: null, runId: null, steps: [{ id: 'one', title: 'One', dependencies: [], state: 'not-started' }] };
  assert.throws(() => validateStepList({ ...base, steps: [{ ...base.steps[0], id: '' }] }), /step 0 id is empty/);
  assert.throws(() => validateStepList({ ...base, steps: [base.steps[0], { ...base.steps[0] }] }), /duplicate step id one/);
  assert.throws(() => validateStepList({ ...base, steps: [{ ...base.steps[0], dependencies: ['missing'] }] }), /unknown dependency missing/);
});

test('S6 preflight adapter requires messages and no FAIL checks in a PASS result', () => {
  assert.throws(() => validatePreflight({ schemaVersion: 1, installer: 'pwsh', answersSchemaVersion: 1, result: 'PASS', checks: [{ id: 'x', result: 'PASS' }] }), /field message is not text/);
  assert.throws(() => validatePreflight({ schemaVersion: 1, installer: 'pwsh', answersSchemaVersion: 1, result: 'PASS', checks: [{ id: 'x', result: 'FAIL', message: 'bad', remedy: '', reason: null }] }), /result PASS does not match recomputed FAIL/);
  assert.throws(() => validatePreflight({ schemaVersion: 1, installer: 'pwsh', answersSchemaVersion: 1, result: 'PASS', checks: [{ id: 'x', result: 'NOT-RUN', message: 'skip', remedy: '', reason: 'not-signed-in' }] }), /result PASS does not match recomputed FAIL/);
});

test('S6 progress adapter requires producer text fields but allows whole-run failed events', () => {
  const base = { schemaVersion: 1, time: '2026-10-05T00:00:00Z', runId: '0123456789abcdef0123456789abcdef', stepId: '', event: 'failed', message: 'failed', resumeCommand: '' };
  assert.doesNotThrow(() => validateProgressEvent(base));
  assert.throws(() => validateProgressEvent({ ...base, message: undefined }), /field message is not text/);
  assert.throws(() => validateProgressEvent({ ...base, resumeCommand: undefined }), /field resumeCommand is not text/);
  assert.throws(() => validateProgressEvent({ ...base, stepId: undefined }), /field stepId is not text/);
});

test('S7 read-only output preserves multibyte characters split across chunks', async () => {
  const app = await start({ env: { P93_INSTALLER_UI_STUB_PREFLIGHT_MULTIBYTE: '1' } });
  try {
    const response = await app.fetch('/api/preflight', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ answers: passingAnswers }) });
    assert.equal(response.status, 502);
    assert.match((await response.json()).detail, /split 😀 line/);
  } finally {
    await app.close();
  }
});

test('S7 read-only output over the cap is stopped with 502', async () => {
  const app = await start({ env: { P93_INSTALLER_UI_STUB_PREFLIGHT_LARGE_STDOUT: '200' }, readOnlyOutputCapBytes: 100 });
  try {
    const response = await app.fetch('/api/preflight', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ answers: passingAnswers }) });
    assert.equal(response.status, 502);
    assert.match((await response.json()).error, /preflight output exceeded the 100 byte cap/);
  } finally {
    await app.close();
  }
});

test('S7 read-only output over the cap kills a child that keeps writing', async () => {
  const pidFile = join(tmpdir(), `p93-g7-stream-pid-${process.pid}-${Date.now()}.txt`);
  const app = await start({ env: { P93_INSTALLER_UI_STUB_PREFLIGHT_STREAM_PID: pidFile }, readOnlyOutputCapBytes: 4096, readOnlyTimeoutMs: 10_000 });
  try {
    const response = await app.fetch('/api/preflight', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ answers: passingAnswers }) });
    assert.equal(response.status, 502);
    assert.match((await response.json()).error, /preflight output exceeded the 4096 byte cap/);
    assert.equal(app.stubCalls().filter((call) => call.args.includes('-Preflight')).length, 1);
    const pid = Number(await readFile(pidFile, 'utf8'));
    for (let i = 0; i < 20 && alive(pid); i++) await sleep(50);
    assert.equal(alive(pid), false, `pid ${pid} should be gone`);
  } finally {
    await app.close();
    await rm(pidFile, { force: true });
  }
});

test('S7 progress file reads are chunked to 64 KiB', async () => {
  const scratch = join(tmpdir(), `p93-g7-progress-chunks-${process.pid}-${Date.now()}`);
  const progress = join(scratch, 'progress.ndjson');
  await mkdir(scratch, { recursive: true });
  try {
    const text = 'a'.repeat(200 * 1024);
    await writeFile(progress, text, 'utf8');
    const chunks = [];
    await readProgressFile(progress, { offset: 0, decoder: new StringDecoder('utf8') }, async (chunk) => {
      chunks.push(chunk);
    }, true);
    assert.ok(chunks.length > 3);
    assert.equal(chunks.every((chunk) => Buffer.byteLength(chunk) <= 64 * 1024), true);
    assert.equal(chunks.join(''), text);
  } finally {
    await rm(scratch, { recursive: true, force: true });
  }
});

test('S7 oversized progress lines become one error and later progress still arrives', async () => {
  // 70000 bytes pass the 64 KiB cap once before the newline arrives; 200000 bytes pass it again while the line is still discarded.
  for (const length of ['70000', '200000']) {
    const app = await start({ env: { P93_INSTALLER_UI_STUB_PROGRESS_LONG_LINE: length } });
    try {
      const result = await stream(app, { steps: ['resource-group'] });
      assert.equal(result.response.status, 200);
      assert.equal(result.events.filter((event) => event.type === 'error' && /progress line exceeded/.test(event.message)).length, 1, `one error for a ${length}-byte line`);
      assert.ok(result.events.some((event) => event.type === 'progress' && event.event === 'completed' && event.message === 'after long progress'));
    } finally {
      await app.close();
    }
  }
});

test('S7 every oversized progress line is one error and complete oversized lines are capped', async () => {
  const app = await start({ env: { P93_INSTALLER_UI_STUB_PROGRESS_LONG_LINES: '2' } });
  try {
    const result = await stream(app, { steps: ['resource-group'] });
    assert.equal(result.response.status, 200);
    assert.equal(result.events.filter((event) => event.type === 'error' && /progress line exceeded/.test(event.message)).length, 2);
    assert.ok(result.events.some((event) => event.type === 'progress' && event.message === 'after long progress 1'));
    assert.ok(result.events.some((event) => event.type === 'progress' && event.message === 'after long progress 2'));
  } finally {
    await app.close();
  }
});

test('S8 refused Origin and Fetch Metadata checks are logged with terminal diagnostics', async () => {
  const app = await start();
  try {
    const origin = await app.fetch('/api/preflight', { method: 'POST', headers: { 'content-type': 'application/json', origin: 'https://preview.example.test', 'x-forwarded-host': 'cloudshell.example.test', 'x-forwarded-proto': 'https', 'x-forwarded-prefix': '/preview' }, body: '{}' });
    assert.equal(origin.status, 403);
    const fetchSite = await app.fetch('/api/steps', { headers: { 'sec-fetch-site': 'cross-site', 'x-forwarded-host': 'cloudshell.example.test', 'x-forwarded-proto': 'https', 'x-forwarded-prefix': '/preview' } });
    assert.equal(fetchSite.status, 403);
    const text = app.logs.join('\n');
    assert.match(text, /origin=https:\/\/preview\.example\.test/);
    assert.match(text, /sec-fetch-site=cross-site/);
    assert.match(text, /x-forwarded-host=cloudshell\.example\.test/);
    assert.match(text, /x-forwarded-prefix=\/preview/);
  } finally {
    await app.close();
  }
});
