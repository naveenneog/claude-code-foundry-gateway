import assert from 'node:assert/strict';
import { once } from 'node:events';
import { existsSync, readFileSync } from 'node:fs';
import { mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { validatePreflight, validateProgressEvent, validateStepList } from '../tools/installer-ui/installer-contract.mjs';
import { createInstallerUiServer } from '../tools/installer-ui/server.mjs';

const stubInstaller = fileURLToPath(new URL('./installer-ui-stub.mjs', import.meta.url));
const passingAnswers = { schemaVersion: 1, SubscriptionId: '00000000-0000-4000-8000-000000000093' };
const identityOne = { signedIn: true, user: 'operator@example.com', tenantId: 'tenant-1', subscriptionId: '00000000-0000-4000-8000-000000000093' };

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function start(extra = {}) {
  const scratch = join(tmpdir(), `p93-g7-${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`);
  await rm(scratch, { recursive: true, force: true });
  await mkdir(scratch, { recursive: true });
  const log = join(scratch, 'stub.ndjson');
  const logs = [];
  const env = { P93_INSTALLER_UI_STUB_LOG: log, ...(extra.env || {}) };
  const server = await createInstallerUiServer({
    token: 'g7-token-with-at-least-32-bytes-0000',
    csrfToken: 'g7-csrf-token-with-at-least-32-bytes',
    stubInstaller: extra.stubInstaller || stubInstaller,
    idleMs: 60_000,
    env,
    log: (line) => logs.push(line),
    readIdentity: extra.readIdentity ?? (async () => identityOne),
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
    const accepted = await app.fetch('/api/prefill', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ kind: 'subscriptions' }) });
    assert.notEqual(accepted.status, 403);
  } finally {
    await app.close();
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
    const calls = app.stubCalls().filter((call) => call.mode === 'powershell' && call.args.includes('-Preflight'));
    assert.equal(calls.length, 2);
    assert.ok(calls[0].endedAt <= calls[1].startedAt, JSON.stringify(calls));
  } finally {
    await app.close();
  }
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
  const app = await start({ env: { P93_INSTALLER_UI_STUB_PREFLIGHT_DELAY_MS: '500' }, readOnlyTimeoutMs: 100 });
  try {
    const first = app.fetch('/api/preflight', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ answers: passingAnswers, steps: ['resource-group'] }) });
    await sleep(25);
    const second = await app.fetch('/api/preflight', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ answers: passingAnswers, steps: ['gateway-deployment'] }) });
    assert.equal(second.status, 504);
    assert.match((await second.json()).error, /preflight timed out after 100 ms/);
    await first;
    assert.equal(app.stubCalls().filter((call) => call.args.includes('-Preflight')).length, 1);
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
  assert.throws(() => validatePreflight({ schemaVersion: 1, installer: 'pwsh', answersSchemaVersion: 1, result: 'PASS', checks: [{ id: 'x', result: 'FAIL', message: 'bad', remedy: '', reason: null }] }), /PASS includes a FAIL check/);
  assert.doesNotThrow(() => validatePreflight({ schemaVersion: 1, installer: 'pwsh', answersSchemaVersion: 1, result: 'PASS', checks: [{ id: 'x', result: 'NOT-RUN', message: 'skip', remedy: '', reason: 'not-signed-in' }] }));
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

test('S7 oversized progress lines become one error and later progress still arrives', async () => {
  const app = await start({ env: { P93_INSTALLER_UI_STUB_PROGRESS_LONG_LINE: '70000' } });
  try {
    const result = await stream(app, { steps: ['resource-group'] });
    assert.equal(result.response.status, 200);
    assert.equal(result.events.filter((event) => event.type === 'error' && /progress line exceeded/.test(event.message)).length, 1);
    assert.ok(result.events.some((event) => event.type === 'progress' && event.event === 'completed' && event.message === 'after long progress'));
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
