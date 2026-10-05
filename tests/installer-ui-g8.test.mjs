import assert from 'node:assert/strict';
import { once } from 'node:events';
import { mkdir, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { validatePreflight, validateProgressEvent } from '../tools/installer-ui/installer-contract.mjs';
import { createInstallerUiServer, loadSchema } from '../tools/installer-ui/server.mjs';
import { preflightFingerprint } from '../tools/installer-ui/preflight-record.mjs';

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
    stubInstaller,
    idleMs: 60_000,
    env: extra.env || {},
    readIdentity: extra.readIdentity ?? (async () => identityOne),
  });
  const address = await server.listenAsync('127.0.0.1');
  const base = `http://127.0.0.1:${address.port}`;
  const boot = await fetch(`${base}/?token=${encodeURIComponent(server.token)}`, { redirect: 'manual' });
  const cookie = boot.headers.get('set-cookie').split(';')[0];
  const csrfToken = (await (await fetch(`${base}/api/session`, { headers: { cookie } })).json()).csrfToken;
  return {
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
    const fingerprint = preflightFingerprint({ answers: passingAnswers, scope: ['resource-group'], engine: 'pwsh' });
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
