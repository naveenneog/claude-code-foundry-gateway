import assert from 'node:assert/strict';
import { once } from 'node:events';
import { mkdir, readFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { createInstallerUiServer } from '../tools/installer-ui/server.mjs';

const repoRoot = fileURLToPath(new URL('..', import.meta.url)).replace(/[\\/]+$/, '');
const stub = fileURLToPath(new URL('./installer-ui-stub.mjs', import.meta.url));

async function start(env = {}) {
  const scratch = join(repoRoot, '.p93-installer-ui-stream', `${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`);
  await rm(scratch, { recursive: true, force: true });
  await mkdir(scratch, { recursive: true });
  const log = join(scratch, 'stub.ndjson');
  const server = await createInstallerUiServer({
    token: 'stream-token-with-at-least-32-bytes',
    stubInstaller: stub,
    idleMs: 60_000,
    env: { P93_INSTALLER_UI_STUB_LOG: log, ...env },
  });
  const address = await server.listenAsync('127.0.0.1');
  const base = `http://127.0.0.1:${address.port}`;
  const boot = await fetch(`${base}/?token=${encodeURIComponent(server.token)}`, { redirect: 'manual' });
  const cookie = boot.headers.get('set-cookie').split(';')[0];
  const csrfToken = (await (await fetch(`${base}/api/session`, { headers: { cookie } })).json()).csrfToken;
  return {
    base,
    log,
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

async function streamRun(app, body) {
  const response = await app.fetch('/api/run/stream', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  const text = await response.text();
  assert.equal(response.status, 200, text);
  return text.trim().split(/\r?\n/).filter(Boolean).map((line) => JSON.parse(line));
}

function assertStreamInvariant(events) {
  const summaries = events.filter((event) => event.type === 'summary');
  assert.equal(summaries.length, 1, 'exactly one summary');
  assert.equal(events.at(-1).type, 'summary', 'summary is last');
  const seqs = events.filter((event) => Number.isInteger(event.seq)).map((event) => event.seq);
  assert.equal(new Set(seqs).size, seqs.length, 'seqs are unique');
  for (let i = 1; i < seqs.length; i++) assert.ok(seqs[i] > seqs[i - 1], `seq ${seqs[i]} follows ${seqs[i - 1]}`);
  const first = seqs[0];
  const last = seqs.at(-1);
  const skipped = events.reduce((total, event) => total + Number(event.skippedEvents || 0), 0);
  const syntheticNotices = events.filter((event) => event.type === 'notice' && event.skippedEvents && Number.isInteger(event.seq)).length;
  const runStart = skipped ? first - skipped + syntheticNotices : first;
  assert.equal(seqs.length - syntheticNotices + skipped, last - runStart + 1, 'seqs plus skipped events cover the range exactly once');
}

test('normal stream clients receive every burst line in order without a skipped marker', async () => {
  const app = await start({ P93_INSTALLER_UI_STUB_MANY_LINES: '5000' });
  try {
    const events = await streamRun(app, { answers: {}, steps: ['resource-group'] });
    assertStreamInvariant(events);
    assert.equal(events.filter((event) => event.type === 'notice' && event.skippedEvents).length, 0);
    const lines = events.filter((event) => event.type === 'stdout').map((event) => event.line);
    assert.equal(lines.length, 5000);
    assert.deepEqual(lines, Array.from({ length: 5000 }, (_, i) => `line ${String(i).padStart(4, '0')}`));
  } finally {
    await app.close();
  }
});

test('finished-run attach replays the bounded tail contiguously and once', async () => {
  const app = await start({ P93_INSTALLER_UI_STUB_PROGRESS_EVENTS: '1500' });
  try {
    const run = await streamRun(app, { answers: {}, steps: ['resource-group'] });
    assertStreamInvariant(run);
    const attachedResponse = await app.fetch('/api/run/attach?after=0');
    const attached = (await attachedResponse.text()).trim().split(/\r?\n/).filter(Boolean).map((line) => JSON.parse(line));
    assert.equal(attachedResponse.status, 200);
    assertStreamInvariant(attached);
    assert.equal(attached.filter((event) => event.type === 'notice' && event.skippedEvents).length, 1);
    assert.equal(attached.filter((event) => event.type === 'progress').length, 999);
    assert.equal(attached.at(-1).type, 'summary');
  } finally {
    await app.close();
  }
});

test('attach refuses a negative or non-integer cursor before streaming', async () => {
  const app = await start({ P93_INSTALLER_UI_STUB_MANY_LINES: '1' });
  try {
    await streamRun(app, { answers: {}, steps: ['resource-group'] });
    for (const value of ['-1', '1.5', 'NaN']) {
      const response = await app.fetch(`/api/run/attach?after=${encodeURIComponent(value)}`);
      assert.equal(response.status, 400);
      assert.match((await response.json()).error, /after must be a non-negative integer/);
    }
  } finally {
    await app.close();
  }
});


