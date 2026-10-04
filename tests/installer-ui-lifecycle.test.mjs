import assert from 'node:assert/strict';
import { once } from 'node:events';
import { existsSync, readFileSync } from 'node:fs';
import { mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { createInstallerUiServer, shutdownInstallerUiServer } from '../tools/installer-ui/server.mjs';

const stub = fileURLToPath(new URL('./installer-ui-stub.mjs', import.meta.url));
const scratchRoot = join(tmpdir(), 'p93-installer-ui-lifecycle');
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const passingAnswers = { schemaVersion: 1, SubscriptionId: '00000000-0000-4000-8000-000000000093' };

async function start(env = {}, options = {}) {
  const scratch = join(scratchRoot, `${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`);
  await rm(scratch, { recursive: true, force: true });
  await mkdir(scratch, { recursive: true });
  const log = join(scratch, 'stub.ndjson');
  const server = await createInstallerUiServer({
    token: 'lifecycle-token-with-at-least-32-bytes',
    stubInstaller: stub,
    idleMs: 60_000,
    env: { P93_INSTALLER_UI_STUB_LOG: log, ...env },
    ...options,
  });
  let closed = false;
  server.on('close', () => { closed = true; });
  const address = await server.listenAsync('127.0.0.1');
  const base = `http://127.0.0.1:${address.port}`;
  const boot = await fetch(`${base}/?token=${encodeURIComponent(server.token)}`, { redirect: 'manual' });
  const cookie = boot.headers.get('set-cookie').split(';')[0];
  const csrfToken = (await (await fetch(`${base}/api/session`, { headers: { cookie } })).json()).csrfToken;
  return {
    base, cookie, csrfToken, log, scratch, server, token: server.token,
    async fetch(path, requestOptions = {}) {
      const headers = { cookie, ...(requestOptions.headers || {}) };
      if (requestOptions.method === 'POST') headers['x-csrf-token'] ??= csrfToken;
      return fetch(`${base}${path}`, { ...requestOptions, headers });
    },
    stubCalls() {
      return existsSync(log) ? readFileSync(log, 'utf8').trim().split(/\r?\n/).filter(Boolean).map((line) => JSON.parse(line)) : [];
    },
    async close() {
      await server.cleanup();
      if (!closed) {
        server.close();
        await once(server, 'close').catch(() => {});
      }
      await rm(scratch, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
    },
  };
}

function alive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

test('read-only preflight timeout returns 504 and kills the child tree', async () => {
  const heartbeat = join(scratchRoot, `timeout-heartbeat-${process.pid}-${Date.now()}.txt`);
  await rm(heartbeat, { force: true });
  await rm(`${heartbeat}.pid`, { force: true });
  const app = await start({ P93_INSTALLER_UI_STUB_PREFLIGHT_HANG: heartbeat }, { readOnlyTimeoutMs: 500 });
  try {
    const response = await app.fetch('/api/preflight', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ answers: {} }),
    });
    const body = await response.json();
    assert.equal(response.status, 504);
    assert.match(body.error, /preflight timed out after 500 ms/);
    const pids = (await readFile(`${heartbeat}.pid`, 'utf8')).trim().split(/\r?\n/).map(Number);
    await new Promise((resolve) => setTimeout(resolve, 500));
    for (const pid of pids) assert.equal(alive(pid), false, `pid ${pid} should be gone`);
  } finally {
    await app.close();
    await rm(heartbeat, { force: true });
    await rm(`${heartbeat}.pid`, { force: true });
  }
});

test('child-spawning GET routes reject cross-site Fetch Metadata before spawning', async () => {
  const app = await start();
  try {
    for (const route of ['/api/steps', '/api/identity']) {
      const response = await app.fetch(route, { headers: { 'sec-fetch-site': 'cross-site' } });
      assert.equal(response.status, 403);
    }
    assert.equal(existsSync(app.log), false);
  } finally {
    await app.close();
  }
});

test('stop kills the installer process and its grandchild', async () => {
  const heartbeat = join(scratchRoot, `stop-heartbeat-${process.pid}-${Date.now()}.txt`);
  await rm(heartbeat, { force: true });
  await rm(`${heartbeat}.pid`, { force: true });
  const app = await start({ P93_INSTALLER_UI_STUB_GRANDCHILD_HEARTBEAT: heartbeat });
  try {
    const runPromise = runRequest(app, ['resource-group']);
    const status = await waitForStatus(app, (value) => value.id && value.currentStepId);
    const pids = (await readFile(`${heartbeat}.pid`, 'utf8')).trim().split(/\r?\n/).map(Number);
    const stopped = await (await app.fetch('/api/run/stop', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ runId: status.id }),
    })).json();
    assert.match(stopped.message, /resource-group/);
    assert.match(stopped.message, /checkpoint resumes/i);
    await (await runPromise).text();
    await new Promise((resolve) => setTimeout(resolve, 500));
    for (const pid of pids) assert.equal(alive(pid), false, `pid ${pid} should be gone`);
  } finally {
    await app.close();
    await rm(heartbeat, { force: true });
    await rm(`${heartbeat}.pid`, { force: true });
  }
});

async function waitForStatus(app, predicate, ms = 10_000) {
  const end = Date.now() + ms;
  let status;
  while (Date.now() < end) {
    status = await (await app.fetch('/api/run/status')).json();
    if (predicate(status)) return status;
    await sleep(50);
  }
  throw new Error(`run status did not reach the expected state within ${ms} ms; last status ${JSON.stringify(status)}`);
}

async function runRequest(app, steps, signal) {
  const preflight = await (await app.fetch('/api/preflight', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ answers: passingAnswers, steps }),
  })).json();
  assert.match(preflight.fingerprint, /^[0-9a-f]{64}$/);
  return app.fetch('/api/run/stream', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ answers: passingAnswers, steps, fingerprint: preflight.fingerprint }), signal });
}

function answersPathOf(app) {
  const call = app.stubCalls().find((entry) => entry.args.includes('-Yes'));
  return call.args[call.args.indexOf('-AnswersPath') + 1];
}

test('a run whose directory cannot be prepared is released and a later run is not refused as active', async () => {
  await mkdir(scratchRoot, { recursive: true });
  const tempRoot = join(scratchRoot, `run-root-${process.pid}-${Date.now()}`);
  await mkdir(tempRoot, { recursive: true });
  const app = await start({}, { tempRoot });
  try {
    const preflight = await (await app.fetch('/api/preflight', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ answers: passingAnswers, steps: ['resource-group'] }) })).json();
    assert.match(preflight.fingerprint, /^[0-9a-f]{64}$/);
    await rm(tempRoot, { recursive: true, force: true });
    await writeFile(tempRoot, 'a file where the run directory root should be');
    for (const attempt of [1, 2]) {
      const response = await app.fetch('/api/run/stream', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ answers: passingAnswers, steps: ['resource-group'], fingerprint: preflight.fingerprint }) });
      const text = await response.text();
      assert.equal(response.status, 500, `attempt ${attempt}: ${text}`);
      assert.match(JSON.parse(text).error, /could not start/);
      assert.doesNotMatch(text, /not-a-directory/, 'the error names no local path');
    }
    const status = await (await app.fetch('/api/run/status')).json();
    assert.equal(status.state, 'exited');
    assert.equal(app.stubCalls().filter((entry) => entry.args.includes('-Yes')).length, 0, 'the installer never started');
  } finally {
    await app.close();
    await rm(tempRoot, { recursive: true, force: true });
  }
});

test('idle shutdown waits for a slow preflight and then stops the server', async () => {
  const app = await start({ P93_INSTALLER_UI_STUB_PREFLIGHT_DELAY_MS: '1500' }, { idleMs: 300 });
  let stoppedAt = 0;
  app.server.on('installer-ui-stopped', () => { stoppedAt = Date.now(); });
  try {
    const preflight = app.fetch('/api/preflight', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ answers: {} }) });
    await sleep(100);
    // A request that finishes during the preflight re-arms the idle timer; the preflight must still count as work.
    assert.equal((await app.fetch('/api/run/status')).status, 200);
    const response = await preflight;
    const finishedAt = Date.now();
    assert.equal(response.status, 200, await response.text());
    assert.equal(stoppedAt, 0, 'idle shutdown did not cut the preflight');
    for (let i = 0; i < 60 && !stoppedAt; i++) await sleep(50);
    assert.ok(stoppedAt >= finishedAt, 'the server stopped after the preflight finished');
  } finally {
    await app.close();
  }
});

test('the run directory exists while the installer runs and is removed after it exits', async () => {
  const app = await start({ P93_INSTALLER_UI_STUB_DELAY_MS: '400' });
  try {
    const run = runRequest(app, ['resource-group', 'gateway-deployment']).then((response) => response.text());
    await waitForStatus(app, (status) => status.state === 'running' && status.currentStepId);
    const answers = answersPathOf(app);
    assert.equal(existsSync(answers), true, 'the answers file exists while the run is active');
    await run;
    const status = await waitForStatus(app, (value) => value.tempDirRemoved === true);
    assert.equal(status.tempDirRemoved, true);
    assert.equal(existsSync(dirname(answers)), false);
  } finally {
    await app.close();
  }
});

test('reattach after a disconnect receives the events emitted while detached, in order, then the summary', async () => {
  const app = await start({ P93_INSTALLER_UI_STUB_DELAY_MS: '300' });
  try {
    const controller = new AbortController();
    const response = await runRequest(app, ['claude-deployment', 'resource-group', 'gateway-deployment'], controller.signal);
    const first = new TextDecoder().decode((await response.body.getReader().read()).value);
    const last = Math.max(...first.trim().split(/\r?\n/).map((line) => JSON.parse(line).seq));
    controller.abort();
    await waitForStatus(app, (status) => status.state === 'exited');
    const events = (await (await app.fetch(`/api/run/attach?after=${last}`)).text()).trim().split(/\r?\n/).map((line) => JSON.parse(line));
    assert.deepEqual(events.map((event) => event.seq), Array.from({ length: events.length }, (_, i) => last + 1 + i));
    assert.ok(events.filter((event) => event.type === 'progress').length >= 4, 'events emitted while detached are replayed');
    assert.equal(events.at(-1).type, 'summary');
  } finally {
    await app.close();
  }
});

test('the shutdown helper stops a running run tree and removes its directory', async () => {
  await mkdir(scratchRoot, { recursive: true });
  const heartbeat = join(scratchRoot, `shutdown-heartbeat-${process.pid}-${Date.now()}.txt`);
  const app = await start({ P93_INSTALLER_UI_STUB_GRANDCHILD_HEARTBEAT: heartbeat });
  try {
    const run = runRequest(app, ['resource-group']).then((response) => response.text()).catch(() => '');
    await waitForStatus(app, (status) => status.state === 'running' && status.currentStepId);
    const directory = dirname(answersPathOf(app));
    const pids = (await readFile(`${heartbeat}.pid`, 'utf8')).trim().split(/\r?\n/).map(Number);
    assert.equal(existsSync(directory), true);
    await shutdownInstallerUiServer(app.server, 'test');
    await run;
    await sleep(500);
    for (const pid of pids) assert.equal(alive(pid), false, `pid ${pid} should be gone`);
    assert.equal(existsSync(directory), false, 'the run directory is removed');
  } finally {
    await app.close();
    await rm(heartbeat, { force: true });
    await rm(`${heartbeat}.pid`, { force: true });
  }
});

test('the page Stop run confirmation names the running step, and cancelling it sends no stop request', async () => {
  await mkdir(scratchRoot, { recursive: true });
  const heartbeat = join(scratchRoot, `page-stop-heartbeat-${process.pid}-${Date.now()}.txt`);
  const app = await start({ P93_INSTALLER_UI_STUB_GRANDCHILD_HEARTBEAT: heartbeat });
  const { chromium } = await import('playwright');
  const browser = await chromium.launch({ headless: true });
  try {
    const page = await browser.newPage();
    const pageErrors = [];
    page.on('pageerror', (error) => pageErrors.push(error.message));
    const stopRequests = [];
    page.on('request', (request) => { if (new URL(request.url()).pathname === '/api/run/stop') stopRequests.push(request.method()); });
    await page.context().addCookies([{ name: 'installer_token', value: app.token, domain: '127.0.0.1', path: '/', httpOnly: true, sameSite: 'Strict' }]);
    await page.goto(`${app.base}/`);
    await page.getByRole('button', { name: 'List steps' }).click();
    await page.locator('[name="SubscriptionId"]').fill(passingAnswers.SubscriptionId);
    await page.locator('#step-list input[value="resource-group"]').check();
    await page.getByRole('button', { name: 'Run preflight' }).click();
    await page.getByText(/Passing preflight/).waitFor();
    await page.getByRole('button', { name: 'Run selected steps' }).click();
    await waitForStatus(app, (status) => status.state === 'running' && status.currentStepId === 'resource-group');
    await page.evaluate(() => { globalThis.confirm = (text) => { globalThis.p93ConfirmText = text; return false; }; });
    await page.getByRole('button', { name: 'Stop run' }).click();
    await page.waitForFunction(() => Boolean(globalThis.p93ConfirmText));
    const question = await page.evaluate(() => globalThis.p93ConfirmText);
    assert.match(question, /resource-group/);
    assert.match(question, /checkpoint/);
    await sleep(300);
    assert.deepEqual(stopRequests, [], 'a cancelled confirmation sends no stop request');
    assert.equal((await (await app.fetch('/api/run/status')).json()).state, 'running');
    await page.evaluate(() => { globalThis.confirm = () => true; });
    await page.getByRole('button', { name: 'Stop run' }).click();
    const stopped = await waitForStatus(app, (status) => status.state === 'stopped');
    assert.equal(stopped.state, 'stopped');
    assert.deepEqual(stopRequests, ['POST']);
    const pids = (await readFile(`${heartbeat}.pid`, 'utf8')).trim().split(/\r?\n/).map(Number);
    await sleep(500);
    for (const pid of pids) assert.equal(alive(pid), false, `pid ${pid} should be gone`);
    assert.deepEqual(pageErrors, []);
  } finally {
    await browser.close();
    await app.close();
    await rm(heartbeat, { force: true });
    await rm(`${heartbeat}.pid`, { force: true });
  }
});
