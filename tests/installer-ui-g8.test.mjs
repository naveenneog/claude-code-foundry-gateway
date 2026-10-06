import assert from 'node:assert/strict';
import { once } from 'node:events';
import { access, mkdir, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { validatePreflight, validateProgressEvent } from '../tools/installer-ui/installer-contract.mjs';
import { createInstallerUiServer, loadSchema, shutdownInstallerUiServer } from '../tools/installer-ui/server.mjs';
import { preflightFingerprint } from '../tools/installer-ui/preflight-record.mjs';
import { createAzureLease } from '../tools/installer-ui/azure-lease.mjs';

const stubInstaller = fileURLToPath(new URL('./installer-ui-stub.mjs', import.meta.url));
const passingAnswers = { schemaVersion: 1, SubscriptionId: '00000000-0000-4000-8000-000000000093' };
const identityOne = { signedIn: true, user: 'operator@example.com', tenantId: 'tenant-1', subscriptionId: passingAnswers.SubscriptionId };

async function start(extra = {}) {
  const scratch = join(tmpdir(), `p93-g8-${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`);
  await rm(scratch, { recursive: true, force: true });
  await mkdir(scratch, { recursive: true });
  const server = await createInstallerUiServer({
    token: 'g8-token-with-at-least-32-bytes-0000',
    csrfToken: 'g8-csrf-token-with-at-least-32-bytes',
    stubInstaller: extra.stubInstaller || stubInstaller,
    idleMs: extra.idleMs || 60_000,
    env: extra.env || {},
    readIdentity: extra.readIdentity ?? (async () => identityOne),
    readOnlyTimeoutMs: extra.readOnlyTimeoutMs,
    tempRoot: extra.tempRoot,
    beforeRunSpawn: extra.beforeRunSpawn,
    onAzureQueued: extra.onAzureQueued,
  });
  const address = await server.listenAsync('127.0.0.1');
  const base = `http://127.0.0.1:${address.port}`;
  const boot = await fetch(`${base}/?token=${encodeURIComponent(server.token)}`, { redirect: 'manual' });
  const cookie = boot.headers.get('set-cookie').split(';')[0];
  const csrfToken = (await (await fetch(`${base}/api/session`, { headers: { cookie } })).json()).csrfToken;
  return {
    server,
    scratch,
    base,
    cookie,
    csrfToken,
    async fetch(path, options = {}) {
      const headers = { cookie, ...(options.headers || {}) };
      if (options.method === 'POST') headers['x-csrf-token'] ??= csrfToken;
      return fetch(`${base}${path}`, { ...options, headers });
    },
    async close() {
      await server.cleanup();
      server.close();
      await once(server, 'close').catch(() => {});
      await rm(scratch, { recursive: true, force: true });
    },
  };
}

function passCheck(id) {
  return { id, result: 'PASS', reason: null, message: `${id} passed`, remedy: '', problems: [] };
}

function payload(checks, result = 'PASS') {
  return { schemaVersion: 1, installer: 'pwsh', answersSchemaVersion: 1, result, checks };
}

test('R3-3 preflight adapter requires the producer check set and recomputes result', async () => {
  const expectedCheckIds = (await loadSchema())['x-preflightChecks'].map((check) => check.id);
  const allPass = expectedCheckIds.map(passCheck);
  assert.doesNotThrow(() => validatePreflight(payload(allPass), { expectedCheckIds }));
  assert.throws(() => validatePreflight(payload([]), { expectedCheckIds }), /zero checks/);
  assert.throws(() => validatePreflight(payload([...allPass, passCheck(expectedCheckIds[0])]), { expectedCheckIds }), /duplicate check id/);
  assert.throws(() => validatePreflight(payload([...allPass.slice(1), passCheck('unknown.check')]), { expectedCheckIds }), /unknown check id/);
  assert.throws(() => validatePreflight(payload(allPass.slice(1)), { expectedCheckIds }), /missing expected check/);

  for (const reason of ['not-signed-in', 'prerequisite-failed', 'not-evaluated']) {
    const checks = allPass.map((check) => ({ ...check }));
    checks[0] = { ...checks[0], result: 'NOT-RUN', reason };
    assert.throws(() => validatePreflight(payload(checks, 'PASS'), { expectedCheckIds }), /result PASS does not match recomputed FAIL/);
  }
  const noBlocking = allPass.map((check) => ({ ...check }));
  noBlocking[0] = { ...noBlocking[0], result: 'NOT-RUN', reason: 'not-applicable' };
  assert.doesNotThrow(() => validatePreflight(payload(noBlocking, 'PASS'), { expectedCheckIds }));

  assert.throws(() => validatePreflight(payload(allPass, 'FAIL'), { expectedCheckIds }), /result FAIL does not match recomputed PASS/);
  assert.throws(() => validatePreflight(payload([{ ...allPass[0], result: 'NOT-RUN', reason: undefined }, ...allPass.slice(1)]), { expectedCheckIds }), /NOT-RUN check .* reason/);
  assert.throws(() => validatePreflight(payload([{ ...allPass[0], result: 'NOT-RUN', reason: 'new-reason' }, ...allPass.slice(1)]), { expectedCheckIds }), /unsupported reason/);
  assert.throws(() => validatePreflight(payload([{ ...allPass[0], reason: 'not-signed-in' }, ...allPass.slice(1)]), { expectedCheckIds }), /PASS check .* reason/);
});

test('R3-5 idle shutdown waits for an authenticated run request body being admitted', async () => {
  const app = await start({ idleMs: 200 });
  try {
    const { request: httpRequest } = await import('node:http');
    let req;
    const responsePromise = new Promise((resolve, reject) => {
      const url = new URL(`${app.base}/api/run/stream`);
      req = httpRequest(url, {
        method: 'POST',
        headers: {
          cookie: app.cookie,
          'x-csrf-token': app.csrfToken,
          'content-type': 'application/json',
          'transfer-encoding': 'chunked',
        },
      }, (res) => {
        let text = '';
        res.on('data', (chunk) => { text += chunk.toString('utf8'); });
        res.on('end', () => resolve({ status: res.statusCode, text }));
      });
      req.on('error', reject);
      req.flushHeaders();
    });
    await new Promise((resolve) => setTimeout(resolve, 450));
    const session = await fetch(`${app.base}/api/session`, { headers: { cookie: app.cookie } });
    assert.equal(session.status, 200, 'server is still listening while it awaits the request body');
    req.end(JSON.stringify({ answers: passingAnswers, steps: ['resource-group'], fingerprint: '0'.repeat(64) }));
    const response = await responsePromise;
    assert.equal(response.status, 409, response.text);
    await once(app.server, 'installer-ui-stopped');
  } finally {
    await app.close().catch(() => {});
  }
});

test('R3-2 server records run admission states by client request id', async () => {
  let releaseIdentity;
  const heldIdentity = new Promise((resolve) => { releaseIdentity = resolve; });
  let identityEntered;
  const identityStarted = new Promise((resolve) => { identityEntered = resolve; });
  let holdIdentity = false;
  const app = await start({
    readIdentity: async () => {
      identityEntered?.();
      if (holdIdentity) await heldIdentity;
      return identityOne;
    },
  });
  try {
    const preflight = await passingPreflight(app);
    holdIdentity = true;
    const requestId = 'r3-2-admission-0001';
    const run = app.fetch('/api/run/stream', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-client-request-id': requestId },
      body: JSON.stringify({ answers: passingAnswers, steps: ['resource-group'], fingerprint: preflight.fingerprint }),
    });
    await identityStarted;
    let status = await (await app.fetch(`/api/run/status?request=${requestId}`)).json();
    assert.equal(status.admission.state, 'admitting');
    releaseIdentity();
    const response = await run;
    assert.equal(response.status, 200);
    await response.text();
    status = await (await app.fetch(`/api/run/status?request=${requestId}`)).json();
    assert.equal(status.admission.state, 'started');
    assert.equal(status.admission.runId, status.id);
    assert.equal(status.clientRequestId, requestId);

    const refusedId = 'r3-2-refused-0001';
    const refused = await app.fetch('/api/run/stream', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-client-request-id': refusedId },
      body: JSON.stringify({ answers: passingAnswers, steps: ['resource-group'], fingerprint: '0'.repeat(64) }),
    });
    assert.equal(refused.status, 409);
    status = await (await app.fetch(`/api/run/status?request=${refusedId}`)).json();
    assert.equal(status.admission.state, 'refused');
    assert.equal(status.admission.reason, 'preflight-required');
    assert.equal((await app.fetch('/api/run/stream', { method: 'POST', headers: { 'content-type': 'application/json', 'x-client-request-id': 'bad id' }, body: '{}' })).status, 400);
    assert.equal((await (await app.fetch('/api/run/status?request=unknown-request')).json()).admission, null);
  } finally {
    releaseIdentity?.();
    await app.close();
  }
});

test('R3-2 refused admissions are recorded for every pre-start failure path', async () => {
  const app = await start();
  try {
    async function assertRefused(requestId, response, expectedStatus) {
      assert.equal(response.status, expectedStatus);
      const body = await response.json().catch(() => ({}));
      const status = await (await app.fetch(`/api/run/status?request=${requestId}`)).json();
      assert.equal(status.admission.state, 'refused');
      assert.equal(status.admission.error, body.error);
      assert.equal(status.admission.reason, body.reason);
    }

    await assertRefused('r3-2-bad-body-0001', await app.fetch('/api/run/stream', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-client-request-id': 'r3-2-bad-body-0001' },
      body: '{',
    }), 400);

    await assertRefused('r3-2-unknown-step-0001', await app.fetch('/api/run/stream', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-client-request-id': 'r3-2-unknown-step-0001' },
      body: JSON.stringify({ answers: passingAnswers, steps: ['not-a-real-step'], fingerprint: '0'.repeat(64) }),
    }), 400);
  } finally {
    await app.close();
  }

  const badList = await start({ env: { P93_INSTALLER_UI_STUB_BAD_LIST: 'type' } });
  try {
    await (async () => {
      const response = await badList.fetch('/api/run/stream', {
        method: 'POST',
        headers: { 'content-type': 'application/json', 'x-client-request-id': 'r3-2-bad-list-0001' },
        body: JSON.stringify({ answers: passingAnswers, steps: ['resource-group'], fingerprint: '0'.repeat(64) }),
      });
      assert.equal(response.status, 502);
      const body = await response.json();
      const status = await (await badList.fetch('/api/run/status?request=r3-2-bad-list-0001')).json();
      assert.equal(status.admission.state, 'refused');
      assert.equal(status.admission.error, body.error);
    })();
  } finally {
    await badList.close();
  }

  let releaseIdentity;
  const heldIdentity = new Promise((resolve) => { releaseIdentity = resolve; });
  let identityEntered;
  const identityStarted = new Promise((resolve) => { identityEntered = resolve; });
  const busy = await start({
    readIdentity: async () => {
      identityEntered();
      await heldIdentity;
      return identityOne;
    },
  });
  try {
    const identity = busy.fetch('/api/identity').catch(() => {});
    await identityStarted;
    const response = await busy.fetch('/api/run/stream', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-client-request-id': 'r3-2-lease-busy-0001' },
      body: JSON.stringify({ answers: passingAnswers, steps: ['resource-group'], fingerprint: '0'.repeat(64) }),
    });
    assert.equal(response.status, 409);
    const body = await response.json();
    const status = await (await busy.fetch('/api/run/status?request=r3-2-lease-busy-0001')).json();
    assert.equal(status.admission.state, 'refused');
    assert.equal(status.admission.error, body.error);
    assert.equal(status.admission.reason, 'azure-busy');
    releaseIdentity();
    await identity;
  } finally {
    releaseIdentity?.();
    await busy.close();
  }
});

test('R3-3 progress adapter rejects empty step ids on per-step events only', () => {
  const base = { schemaVersion: 1, time: '2026-10-05T00:00:00Z', runId: '0123456789abcdef0123456789abcdef', stepId: '', event: 'failed', message: 'failed', resumeCommand: '' };
  assert.doesNotThrow(() => validateProgressEvent(base));
  assert.doesNotThrow(() => validateProgressEvent({ ...base, event: 'refused' }));
  for (const event of ['started', 'completed', 'skipped-verified', 'warning']) {
    assert.throws(() => validateProgressEvent({ ...base, event }), /event .* needs a stepId/);
  }
});

test('R3-3 impossible PASS with blocking NOT-RUN returns 502 and stores no fingerprint', async () => {
  const app = await start({ env: { P93_INSTALLER_UI_STUB_PREFLIGHT_IMPOSSIBLE_PASS_NOTRUN: '1' } });
  try {
    const response = await app.fetch('/api/preflight', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ answers: passingAnswers, steps: ['resource-group'] }),
    });
    assert.equal(response.status, 502);
    assert.match((await response.json()).error, /result PASS does not match recomputed FAIL/);
    const fingerprint = preflightFingerprint({ answers: passingAnswers, scope: ['resource-group'], engine: 'pwsh', identity: identityOne });
    const run = await app.fetch('/api/run/stream', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ answers: passingAnswers, steps: ['resource-group'], fingerprint }),
    });
    assert.equal(run.status, 409);
    assert.equal((await run.json()).reason, 'preflight-required');
  } finally {
    await app.close();
  }
});

test('R3-3 server passes the expected preflight check set into validation', async () => {
  const app = await start({ env: { P93_INSTALLER_UI_STUB_PREFLIGHT_OMIT_CHECK: 'address.inputs' } });
  try {
    const response = await app.fetch('/api/preflight', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ answers: passingAnswers, steps: ['resource-group'] }),
    });
    const body = await response.json();
    assert.equal(response.status, 502);
    assert.match(body.error, /missing expected check address\.inputs/);
    const fingerprint = preflightFingerprint({ answers: passingAnswers, scope: ['resource-group'], engine: 'pwsh', identity: identityOne });
    const run = await app.fetch('/api/run/stream', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ answers: passingAnswers, steps: ['resource-group'], fingerprint }),
    });
    assert.equal(run.status, 409);
    assert.equal((await run.json()).reason, 'preflight-required');
  } finally {
    await app.close();
  }
});

test('R3-3 installer stub emits every schema preflight check id exactly once', async () => {
  const expectedCheckIds = (await loadSchema())['x-preflightChecks'].map((check) => check.id).sort();
  const answersPath = join(tmpdir(), `p93-g8-answers-${process.pid}-${Date.now()}.json`);
  await import('node:fs/promises').then(({ writeFile }) => writeFile(answersPath, JSON.stringify(passingAnswers), 'utf8'));
  try {
    const { spawn } = await import('node:child_process');
    const child = spawn(process.execPath, [stubInstaller, 'pwsh', '-AnswersPath', answersPath, '-Preflight', '-Json'], { cwd: fileURLToPath(new URL('..', import.meta.url)), shell: false, windowsHide: true, env: { ...process.env, CI: '1', FORCE_COLOR: '0' } });
    let stdout = '';
    child.stdout.on('data', (chunk) => { stdout += chunk.toString('utf8'); });
    const [code] = await once(child, 'close');
    const body = JSON.parse(stdout);
    assert.equal(code, 0);
    assert.equal(body.result, 'PASS');
    assert.deepEqual(body.checks.map((check) => check.id).sort(), expectedCheckIds);
    assert.equal(body.checks.find((check) => check.id === 'target.tenant').result, 'PASS');
  } finally {
    await rm(answersPath, { force: true });
  }
});

async function passingPreflight(app, answers = passingAnswers) {
  const response = await app.fetch('/api/preflight', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ answers, steps: ['resource-group'] }),
  });
  const json = await response.json();
  assert.equal(response.status, 200, JSON.stringify(json));
  assert.match(json.fingerprint, /^[0-9a-f]{64}$/);
  return json;
}

test('R3-1 an identity-read failure clears an earlier pass for the same answers', async () => {
  let identity = identityOne;
  const identityApp = await start({ readIdentity: async () => {
    if (!identity) throw Object.assign(new Error('identity failed for R3-1'), { status: 504 });
    return identity;
  } });
  try {
    const pass = await passingPreflight(identityApp);
    identity = null;
    const failed = await identityApp.fetch('/api/preflight', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ answers: passingAnswers, steps: ['resource-group'] }) });
    assert.equal(failed.status, 504);
    const run = await identityApp.fetch('/api/run/stream', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ answers: passingAnswers, steps: ['resource-group'], fingerprint: pass.fingerprint }) });
    assert.equal(run.status, 409);
    assert.equal((await run.json()).reason, 'preflight-required');
  } finally {
    await identityApp.close();
  }

});

test('R3-1 malformed preflight output clears an earlier pass for the same answers', async () => {
  const counterPath = join(tmpdir(), `p93-r3-1-bad-preflight-${process.pid}-${Date.now()}.count`);
  await rm(counterPath, { force: true });
  await rm('type.count', { force: true });
  const malformedApp = await start({ env: { P93_INSTALLER_UI_STUB_BAD_PREFLIGHT_ON_SECOND: 'type', P93_INSTALLER_UI_STUB_BAD_PREFLIGHT_ON_SECOND_COUNTER: counterPath } });
  try {
    const pass = await passingPreflight(malformedApp);
    const failed = await malformedApp.fetch('/api/preflight', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ answers: passingAnswers, steps: ['resource-group'] }) });
    assert.equal(failed.status, 502, 'malformed');
    await assert.rejects(() => access('type.count'));
    const run = await malformedApp.fetch('/api/run/stream', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ answers: passingAnswers, steps: ['resource-group'], fingerprint: pass.fingerprint }) });
    assert.equal(run.status, 409, 'malformed');
    assert.equal((await run.json()).reason, 'preflight-required', 'malformed');
  } finally {
    await malformedApp.close();
    await rm(counterPath, { force: true });
    await rm('type.count', { force: true });
  }
});

test('R3-1 a preflight timeout clears an earlier pass for the same answers', async () => {
  const timeoutCounter = join(tmpdir(), `p93-r3-1-timeout-${process.pid}-${Date.now()}.count`);
  await rm(timeoutCounter, { force: true });
  const timeoutApp = await start({ env: { P93_INSTALLER_UI_STUB_PREFLIGHT_HANG_ON_SECOND: timeoutCounter }, readOnlyTimeoutMs: 3000 });
  try {
    const response = await timeoutApp.fetch('/api/preflight', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ answers: passingAnswers, steps: ['resource-group'] }) });
    const pass = await response.json();
    assert.equal(response.status, 200, JSON.stringify(pass));
    assert.match(pass.fingerprint, /^[0-9a-f]{64}$/);
    const failed = await timeoutApp.fetch('/api/preflight', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ answers: passingAnswers, steps: ['resource-group'] }) });
    assert.equal(failed.status, 504, 'timeout');
    const run = await timeoutApp.fetch('/api/run/stream', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ answers: passingAnswers, steps: ['resource-group'], fingerprint: pass.fingerprint }) });
    assert.equal(run.status, 409, 'timeout');
    assert.equal((await run.json()).reason, 'preflight-required', 'timeout');
  } finally {
    await timeoutApp.close();
    await rm(timeoutCounter, { force: true });
  }
});

test('R3-1 preflight fingerprints include the passing identity snapshot', async () => {
  let identity = identityOne;
  const app = await start({ readIdentity: async () => identity });
  try {
    const first = await passingPreflight(app);
    identity = { ...identityOne, subscriptionId: '00000000-0000-4000-8000-000000000094' };
    const second = await passingPreflight(app);
    assert.notEqual(first.fingerprint, second.fingerprint);
    const oldRun = await app.fetch('/api/run/stream', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ answers: passingAnswers, steps: ['resource-group'], fingerprint: first.fingerprint }) });
    assert.equal(oldRun.status, 409);
    assert.equal((await oldRun.json()).reason, 'preflight-required');
  } finally {
    await app.close();
  }
});

test('R3-4 Azure lease close refuses queued and later acquisitions', async () => {
  const lease = createAzureLease();
  const holder = await lease.acquire('identity', 'read', 1000);
  const queued = lease.acquire('preflight', 'read', 1000);
  lease.close();
  await assert.rejects(queued, { status: 503, reason: 'installer-ui-stopping' });
  await assert.rejects(() => lease.acquire('prefill', 'read', 1000), { status: 503, reason: 'installer-ui-stopping' });
  holder.release();
});

test('R3-4 shutdown closes the Azure lease before queued reads can spawn children', async () => {
  let releaseIdentity;
  const heldIdentity = new Promise((resolve) => { releaseIdentity = resolve; });
  let identityEntered;
  const identityStarted = new Promise((resolve) => { identityEntered = resolve; });
  let preflightQueued;
  const preflightWaiting = new Promise((resolve) => { preflightQueued = resolve; });
  const tempRoot = join(tmpdir(), `p93-g8-r3-4-temp-${process.pid}-${Date.now()}`);
  const app = await start({
    tempRoot,
    readIdentity: async () => {
      identityEntered();
      await heldIdentity;
      return identityOne;
    },
    onAzureQueued: (operation) => {
      if (operation === 'preflight') preflightQueued();
    },
  });
  try {
    const identity = app.fetch('/api/identity');
    identity.catch(() => {});
    await identityStarted;
    const preflight = app.fetch('/api/preflight', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ answers: passingAnswers, steps: ['resource-group'] }) });
    preflight.catch(() => {});
    // Shutdown starts only once the preflight waits for the Azure lease behind the held identity read.
    let timer;
    await Promise.race([preflightWaiting, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('The preflight did not wait for the Azure lease within 30000 ms')), 30_000); })]).finally(() => clearTimeout(timer));
    const shutdown = shutdownInstallerUiServer(app.server, 'test shutdown');
    releaseIdentity();
    const [, preflightResult] = await Promise.allSettled([identity, preflight]);
    assert.equal(preflightResult.status, 'fulfilled');
    assert.equal(preflightResult.value.status, 503);
    assert.equal((await preflightResult.value.json()).reason, 'installer-ui-stopping');
    await shutdown;
    const entries = await import('node:fs/promises').then(({ readdir }) => readdir(tempRoot).catch(() => []));
    assert.deepEqual(entries.filter((name) => name.startsWith('claude-installer-ui-')), []);
  } finally {
    releaseIdentity();
    await app.close().catch(() => {});
    await rm(tempRoot, { recursive: true, force: true });
  }
});

test('R3-4 shutdown spawn guard refuses work that held the run lease before spawn', async () => {
  let releaseSpawn;
  const heldSpawn = new Promise((resolve) => { releaseSpawn = resolve; });
  let spawnEntered;
  const spawnStarted = new Promise((resolve) => { spawnEntered = resolve; });
  const logPath = join(tmpdir(), `p93-r3-4-spawn-${process.pid}-${Date.now()}.jsonl`);
  const app = await start({
    env: { P93_INSTALLER_UI_STUB_LOG: logPath },
    beforeRunSpawn: async () => {
      spawnEntered();
      await heldSpawn;
    },
  });
  try {
    const pass = await passingPreflight(app);
    const run = app.fetch('/api/run/stream', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ answers: passingAnswers, steps: ['resource-group'], fingerprint: pass.fingerprint }),
    }).catch((error) => error);
    await spawnStarted;
    const cleanup = app.server.cleanup();
    releaseSpawn();
    await cleanup;
    await run;
    let status = await (await app.fetch('/api/run/status')).json();
    for (let i = 0; i < 20 && status.state === 'running'; i++) {
      await new Promise((resolve) => setTimeout(resolve, 25));
      status = await (await app.fetch('/api/run/status')).json();
    }
    assert.equal(status.state, 'exited');
    assert.notEqual(status.exitCode, 0);
    const logText = await readFile(logPath, 'utf8');
    const calls = logText.trim().split(/\r?\n/).filter(Boolean).map((line) => JSON.parse(line));
    assert.equal(calls.some((call) => call.args.includes('-Yes')), false);
  } finally {
    releaseSpawn?.();
    await app.close().catch(() => {});
    await rm(logPath, { force: true });
  }
});
