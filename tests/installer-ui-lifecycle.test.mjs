import assert from 'node:assert/strict';
import { once } from 'node:events';
import { existsSync } from 'node:fs';
import { mkdir, readFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { createInstallerUiServer } from '../tools/installer-ui/server.mjs';

const repoRoot = fileURLToPath(new URL('..', import.meta.url)).replace(/[\\/]+$/, '');
const stub = fileURLToPath(new URL('./installer-ui-stub.mjs', import.meta.url));

async function start(env = {}, options = {}) {
  const scratch = join(repoRoot, '.p93-installer-ui-lifecycle', `${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`);
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
  const address = await server.listenAsync('127.0.0.1');
  const base = `http://127.0.0.1:${address.port}`;
  const boot = await fetch(`${base}/?token=${encodeURIComponent(server.token)}`, { redirect: 'manual' });
  const cookie = boot.headers.get('set-cookie').split(';')[0];
  const csrfToken = (await (await fetch(`${base}/api/session`, { headers: { cookie } })).json()).csrfToken;
  return {
    base, cookie, csrfToken, log, scratch,
    async fetch(path, requestOptions = {}) {
      const headers = { cookie, ...(requestOptions.headers || {}) };
      if (requestOptions.method === 'POST') headers['x-csrf-token'] ??= csrfToken;
      return fetch(`${base}${path}`, { ...requestOptions, headers });
    },
    async close() {
      await server.cleanup();
      server.close();
      await once(server, 'close').catch(() => {});
      await rm(scratch, { recursive: true, force: true });
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
  const heartbeat = join(repoRoot, '.p93-timeout-heartbeat.txt');
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
  const heartbeat = join(repoRoot, '.p93-stop-heartbeat.txt');
  await rm(heartbeat, { force: true });
  await rm(`${heartbeat}.pid`, { force: true });
  const app = await start({ P93_INSTALLER_UI_STUB_GRANDCHILD_HEARTBEAT: heartbeat });
  try {
    const runPromise = app.fetch('/api/run/stream', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ answers: {}, steps: ['resource-group'] }),
    });
    let status;
    for (let i = 0; i < 40; i++) {
      status = await (await app.fetch('/api/run/status')).json();
      if (status.id && status.currentStepId) break;
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
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
