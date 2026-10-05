import assert from 'node:assert/strict';
import { once } from 'node:events';
import { mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { createInstallerUiServer } from '../tools/installer-ui/server.mjs';

const stubInstaller = fileURLToPath(new URL('./installer-ui-stub.mjs', import.meta.url));
const passingAnswers = { schemaVersion: 1, SubscriptionId: '00000000-0000-4000-8000-000000000093' };
const identityOne = { signedIn: true, user: 'operator@example.com', tenantId: 'tenant-1', subscriptionId: passingAnswers.SubscriptionId };
const preflightBody = JSON.stringify({ answers: passingAnswers, steps: ['resource-group'] });

function scratchPath(name) {
  return join(tmpdir(), `p93-g9-${name}-${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`);
}

async function start(extra = {}) {
  const scratch = scratchPath('server');
  await mkdir(scratch, { recursive: true });
  const server = await createInstallerUiServer({
    token: 'g9-token-with-at-least-32-bytes-0000',
    csrfToken: 'g9-csrf-token-with-at-least-32-bytes',
    stubInstaller,
    idleMs: 60_000,
    env: extra.env || {},
    readIdentity: async () => identityOne,
    beforeRunSpawn: extra.beforeRunSpawn,
  });
  const address = await server.listenAsync('127.0.0.1');
  const base = `http://127.0.0.1:${address.port}`;
  const boot = await fetch(`${base}/?token=${encodeURIComponent(server.token)}`, { redirect: 'manual' });
  const cookie = boot.headers.get('set-cookie').split(';')[0];
  const csrfToken = (await (await fetch(`${base}/api/session`, { headers: { cookie } })).json()).csrfToken;
  return {
    fetch(path, options = {}) {
      const headers = { cookie, ...(options.headers || {}) };
      if (options.method === 'POST') {
        headers['x-csrf-token'] ??= csrfToken;
        headers['content-type'] ??= 'application/json';
      }
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

async function passingPreflight(app) {
  const response = await app.fetch('/api/preflight', { method: 'POST', body: preflightBody });
  const json = await response.json();
  assert.equal(response.status, 200, JSON.stringify(json));
  assert.match(json.fingerprint, /^[0-9a-f]{64}$/);
  return json;
}

function runWith(app, fingerprint) {
  return app.fetch('/api/run/stream', { method: 'POST', body: JSON.stringify({ answers: passingAnswers, steps: ['resource-group'], fingerprint }) });
}

async function assertPreflightRequired(response, label) {
  const text = await response.text();
  assert.equal(response.status, 409, `${label}: ${text.slice(0, 300)}`);
  assert.equal(JSON.parse(text).reason, 'preflight-required', label);
}

// Waits until the stub's call log (one JSON record per installer call) satisfies `ready`.
async function waitForCalls(log, ready, what) {
  const until = Date.now() + 20_000;
  for (;;) {
    let calls = [];
    try {
      calls = (await readFile(log, 'utf8')).split('\n').filter(Boolean).map((line) => JSON.parse(line));
    } catch {}
    if (ready(calls)) return;
    if (Date.now() > until) throw new Error(`${what} did not happen within 20 s`);
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
}

function within(promise, what, ms = 30_000) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${what} did not happen within ${ms} ms`)), ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

test('R4-1 a preflight retry whose step list fails clears the earlier pass for the same answers', async () => {
  const marker = scratchPath('bad-list');
  const app = await start({ env: { P93_INSTALLER_UI_STUB_BAD_LIST_MARKER: marker } });
  try {
    const pass = await passingPreflight(app);
    await writeFile(marker, '');
    const retry = await app.fetch('/api/preflight', { method: 'POST', body: preflightBody });
    const retryText = await retry.text();
    assert.equal(retry.status, 502, retryText.slice(0, 300));
    assert.match(retryText, /step list/);
    await rm(marker, { force: true });
    await assertPreflightRequired(await runWith(app, pass.fingerprint), 'run after the failed retry');
  } finally {
    await app.close();
    await rm(marker, { force: true });
  }
});

test('R4-1 a preflight retry refused while a run holds Azure CLI clears the earlier pass for the same answers', async () => {
  let releaseRun;
  let runEntered;
  const held = new Promise((resolve) => { releaseRun = resolve; });
  const runHeld = new Promise((resolve) => { runEntered = resolve; });
  const app = await start({ beforeRunSpawn: async () => { runEntered(); await held; } });
  let first;
  try {
    const pass = await passingPreflight(app);
    first = runWith(app, pass.fingerprint);
    first.catch(() => {});
    await within(runHeld, 'The run reaching the point before its installer child');
    const retry = await app.fetch('/api/preflight', { method: 'POST', body: preflightBody });
    const retryJson = await retry.json();
    assert.equal(retry.status, 409, JSON.stringify(retryJson));
    assert.equal(retryJson.reason, 'azure-busy');
    releaseRun();
    const firstResponse = await within(first, 'The held run answering');
    assert.equal(firstResponse.status, 200);
    assert.match(await within(firstResponse.text(), 'The held run ending'), /"type":"summary"/);
    await assertPreflightRequired(await runWith(app, pass.fingerprint), 'run after the refused retry');
  } finally {
    releaseRun?.();
    await first?.then((response) => response.body?.cancel()).catch(() => {});
    await app.close();
  }
});

test('R4-1 a pass stored while a later attempt waits for Azure CLI does not outlive that attempt', async () => {
  const hold = scratchPath('hold');
  const counter = scratchPath('bad-second');
  const log = scratchPath('calls');
  await writeFile(hold, '');
  const app = await start({
    env: {
      P93_INSTALLER_UI_STUB_PREFLIGHT_HOLD_MARKER: hold,
      P93_INSTALLER_UI_STUB_BAD_PREFLIGHT_ON_SECOND: 'type',
      P93_INSTALLER_UI_STUB_BAD_PREFLIGHT_ON_SECOND_COUNTER: counter,
      P93_INSTALLER_UI_STUB_LOG: log,
    },
  });
  const isPreflight = (call) => call.args.includes('-Preflight');
  try {
    const first = app.fetch('/api/preflight', { method: 'POST', body: preflightBody });
    first.catch(() => {});
    await waitForCalls(log, (calls) => calls.some(isPreflight), 'The first attempt starting its preflight child');
    const second = app.fetch('/api/preflight', { method: 'POST', body: preflightBody });
    second.catch(() => {});
    // The second attempt lists steps only after its entry point, and then waits for the lease the first attempt holds.
    await waitForCalls(log, (calls) => calls.slice(calls.findIndex(isPreflight) + 1).some((call) => call.args.includes('-ListSteps')), 'The second attempt listing steps');
    await rm(hold, { force: true });
    const firstResponse = await within(first, 'The first attempt answering');
    const pass = await firstResponse.json();
    assert.equal(firstResponse.status, 200, JSON.stringify(pass));
    assert.match(pass.fingerprint, /^[0-9a-f]{64}$/);
    const secondResponse = await within(second, 'The second attempt answering');
    assert.equal(secondResponse.status, 502, (await secondResponse.text()).slice(0, 300));
    await assertPreflightRequired(await runWith(app, pass.fingerprint), 'run with the earlier attempt\'s pass');
  } finally {
    await rm(hold, { force: true });
    await app.close();
    await rm(counter, { force: true });
    await rm(log, { force: true });
  }
});
