import assert from 'node:assert/strict';
import { EventEmitter, once } from 'node:events';
import { request } from 'node:http';
import { mkdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { createInstallerUiServer } from '../tools/installer-ui/server.mjs';
import { waitForDrain } from '../tools/installer-ui/run-transport.mjs';

const stub = fileURLToPath(new URL('./installer-ui-stub.mjs', import.meta.url));
const passingAnswers = { schemaVersion: 1, SubscriptionId: '00000000-0000-4000-8000-000000000093' };

async function start(env = {}, options = {}) {
  const scratch = join(tmpdir(), 'p93-installer-ui-stream', `${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`);
  await rm(scratch, { recursive: true, force: true });
  await mkdir(scratch, { recursive: true });
  const log = join(scratch, 'stub.ndjson');
  const server = await createInstallerUiServer({
    token: 'stream-token-with-at-least-32-bytes',
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
    base,
    log,
    cookie,
    csrfToken,
    port: address.port,
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
  const prepared = { ...body, answers: { ...passingAnswers, ...(body.answers || {}) } };
  const preflight = await (await app.fetch('/api/preflight', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(prepared.fullRun ? { answers: prepared.answers, fullRun: true } : { answers: prepared.answers, steps: prepared.steps }),
  })).json();
  assert.match(preflight.fingerprint, /^[0-9a-f]{64}$/);
  prepared.fingerprint = preflight.fingerprint;
  const response = await app.fetch('/api/run/stream', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(prepared),
  });
  const text = await response.text();
  assert.equal(response.status, 200, text);
  return text.trim().split(/\r?\n/).filter(Boolean).map((line) => JSON.parse(line));
}

// Every seq after `after` is accounted for exactly once: delivered in order, or announced by a skipped
// notice whose seq is the last event it skipped. Exactly one summary, and it is last.
function assertStreamInvariant(events, after = 0) {
  let expected = after + 1;
  for (const event of events) {
    if (event.type === 'notice' && event.skippedEvents) {
      assert.equal(event.seq, expected + event.skippedEvents - 1, `a skipped notice at ${expected} names the last skipped seq`);
      expected += event.skippedEvents;
      continue;
    }
    assert.equal(event.seq, expected, `events are contiguous apart from announced skips (${event.type})`);
    expected++;
  }
  assert.equal(events.filter((event) => event.type === 'summary').length, 1, 'exactly one summary');
  assert.equal(events.at(-1).type, 'summary', 'summary is last');
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
  const app = await start({ P93_INSTALLER_UI_STUB_PROGRESS_EVENTS: '1500' }, { runTailEvents: 1000 });
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
    for (const value of ['-1', '1.5', 'NaN', '999999']) {
      const response = await app.fetch(`/api/run/attach?after=${encodeURIComponent(value)}`);
      assert.equal(response.status, 400);
      assert.match((await response.json()).error, /after must be a non-negative integer no greater than the last event/);
    }
  } finally {
    await app.close();
  }
});

test('console cap is large enough for normal output and long lines are truncated', async () => {
  const cap = await start({ P93_INSTALLER_UI_STUB_MANY_LINES: '6000', P93_INSTALLER_UI_STUB_PAD: '1000' });
  try {
    const events = await streamRun(cap, { answers: {}, steps: ['resource-group'] });
    assert.equal(events.filter((event) => event.type === 'notice' && /output cap/.test(event.message || '')).length, 1);
    assert.equal(events.at(-1).type, 'summary');
  } finally {
    await cap.close();
  }

  const longLine = await start({ P93_INSTALLER_UI_STUB_LONG_LINE: String(1024 * 1024) });
  try {
    const events = await streamRun(longLine, { answers: {}, steps: ['resource-group'] });
    const stdout = events.filter((event) => event.type === 'stdout').map((event) => event.line);
    assert.equal(stdout.length, 2);
    assert.match(stdout[0], / \[line truncated\]$/);
    assert.ok(stdout[0].length < 70_000);
    assert.equal(stdout[1], 'next line');
  } finally {
    await longLine.close();
  }
});

async function waitForStatus(app, predicate, ms = 15_000) {
  const end = Date.now() + ms;
  let status;
  while (Date.now() < end) {
    status = await (await app.fetch('/api/run/status')).json();
    if (predicate(status)) return status;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  return status;
}

// A raw request whose response the test reads only when it chooses, so the server sees TCP backpressure.
async function pausedRunRequest(app, onResponse) {
  const preflight = await (await app.fetch('/api/preflight', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ answers: passingAnswers, steps: ['resource-group'] }) })).json();
  const body = JSON.stringify({ answers: passingAnswers, steps: ['resource-group'], fingerprint: preflight.fingerprint });
  const req = request({
    host: '127.0.0.1',
    port: app.port,
    path: '/api/run/stream',
    method: 'POST',
    headers: { cookie: app.cookie, 'content-type': 'application/json', 'x-csrf-token': app.csrfToken, 'content-length': Buffer.byteLength(body) },
  }, (res) => {
    res.pause();
    onResponse(req, res);
  });
  req.on('error', () => {});
  req.end(body);
}

test('a client that stops reading and then disconnects does not hold the run', async () => {
  const app = await start({ P93_INSTALLER_UI_STUB_MANY_LINES: '30000', P93_INSTALLER_UI_STUB_PAD: '100' });
  try {
    await new Promise((resolve) => pausedRunRequest(app, (req, res) => {
      assert.equal(res.statusCode, 200);
      setTimeout(() => { req.destroy(); resolve(); }, 1500);
    }));
    const status = await waitForStatus(app, (value) => value.state === 'exited');
    assert.equal(status.state, 'exited', `the run is ${status.state} at seq ${status.nextSeq} after its client disconnected`);
    assert.equal(status.exitCode, 0);
    const preflight = await (await app.fetch('/api/preflight', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ answers: passingAnswers, steps: ['resource-group'] }) })).json();
    const next = await app.fetch('/api/run/stream', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ answers: passingAnswers, steps: ['resource-group'], fingerprint: preflight.fingerprint }) });
    assert.equal(next.status, 200, 'a new run is admitted');
    assertStreamInvariant((await next.text()).trim().split(/\r?\n/).filter(Boolean).map((line) => JSON.parse(line)));
  } finally {
    await app.close();
  }
});

test('a paused client does not hold back the run and then receives a skipped notice, the tail and the summary', async () => {
  const app = await start({ P93_INSTALLER_UI_STUB_MANY_LINES: '30000', P93_INSTALLER_UI_STUB_PAD: '100' }, { runTailEvents: 5000 });
  try {
    let statusWhilePaused;
    const text = await new Promise((resolve, reject) => pausedRunRequest(app, (req, res) => {
      waitForStatus(app, (value) => value.state === 'exited').then((status) => {
        statusWhilePaused = status;
        const chunks = [];
        res.on('data', (chunk) => chunks.push(chunk));
        res.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
        res.resume();
      }, reject);
    }));
    assert.equal(statusWhilePaused.state, 'exited', `the run is ${statusWhilePaused.state} at seq ${statusWhilePaused.nextSeq} while its client is paused`);
    const events = text.trim().split(/\r?\n/).filter(Boolean).map((line) => JSON.parse(line));
    assertStreamInvariant(events);
    assert.ok(events.some((event) => event.type === 'notice' && event.skippedEvents > 0), 'the lagging client is told how many events it missed');
  } finally {
    await app.close();
  }
});

test('waiting for drain ends when the response closes or fails, not only on drain', async () => {
  for (const name of ['drain', 'close', 'error']) {
    const res = new EventEmitter();
    res.destroyed = false;
    res.writableEnded = false;
    const waiting = waitForDrain(res).then(() => 'ended');
    res.emit(name, name === 'error' ? new Error('socket reset') : undefined);
    const outcome = await Promise.race([waiting, new Promise((resolve) => setTimeout(() => resolve('still waiting'), 200))]);
    assert.equal(outcome, 'ended', `${name} ends the wait`);
    assert.equal(res.listenerCount('drain') + res.listenerCount('close') + res.listenerCount('error'), 0, `${name} removes the listeners`);
  }
});
