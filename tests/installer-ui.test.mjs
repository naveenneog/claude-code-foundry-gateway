import assert from 'node:assert/strict';
import { once } from 'node:events';
import { spawn } from 'node:child_process';
import { request } from 'node:http';
import { readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { createInstallerUiServer } from '../tools/installer-ui/server.mjs';

const stub = fileURLToPath(new URL('./installer-ui-stub.mjs', import.meta.url));
const serverCli = fileURLToPath(new URL('../tools/installer-ui/server.mjs', import.meta.url));

async function start(extra = {}) {
  const scratch = join(tmpdir(), `p93-ui-${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`);
  const log = join(scratch, 'stub.ndjson');
  await rm(scratch, { recursive: true, force: true });
  await import('node:fs/promises').then((fs) => fs.mkdir(scratch, { recursive: true }));
  const server = await createInstallerUiServer({
    token: 'test-token-with-at-least-32-bytes-0000',
    stubInstaller: extra.stubInstaller || stub,
    idleMs: 60_000,
    env: { P93_INSTALLER_UI_STUB_LOG: log, ...(extra.env || {}) },
  });
  const address = await server.listenAsync('127.0.0.1');
  const base = `http://127.0.0.1:${address.port}`;
  return {
    base,
    log,
    scratch,
    token: server.token,
    async fetch(path, options = {}) {
      return fetch(`${base}${path}`, { ...options, headers: { 'x-installer-token': server.token, ...(options.headers || {}) } });
    },
    async close() {
      await server.cleanup();
      server.close();
      await once(server, 'close').catch(() => {});
      await rm(scratch, { recursive: true, force: true });
    },
  };
}

function rawRequest(base, path, headers = {}) {
  const url = new URL(path, base);
  return new Promise((resolve, reject) => {
    const req = request({
      hostname: '127.0.0.1',
      port: url.port,
      path: url.pathname + url.search,
      method: 'GET',
      headers,
    }, (res) => {
      res.resume();
      res.on('end', () => resolve(res.statusCode));
    });
    req.on('error', reject);
    req.end();
  });
}

async function waitForOutput(child, pattern) {
  let text = '';
  child.stdout.on('data', (chunk) => { text += chunk.toString('utf8'); });
  child.stderr.on('data', (chunk) => { text += chunk.toString('utf8'); });
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    if (pattern.test(text)) return text;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error(`timed out waiting for ${pattern}; output: ${text}`);
}

test('the documented one-command launch prints the URL and token', async () => {
  const child = spawn(process.execPath, [serverCli], { cwd: new URL('..', import.meta.url), stdio: ['ignore', 'pipe', 'pipe'] });
  try {
    const output = await waitForOutput(child, /One-time token:/);
    assert.match(output, /Claude gateway installer UI: http:\/\/127\.0\.0\.1:\d+\/\?token=/);
    assert.match(output, /Cloud Shell ends a session after 20 minutes without interactive activity/);
  } finally {
    child.kill('SIGINT');
    await once(child, 'exit').catch(() => {});
  }
});

test('token, host, fixed routes and headers protect the local server', async () => {
  const app = await start();
  try {
    assert.equal((await fetch(`${app.base}/api/schema`)).status, 401);
    assert.equal((await fetch(`${app.base}/api/schema`, { headers: { 'x-installer-token': 'wrong' } })).status, 401);
    assert.equal(await rawRequest(app.base, '/api/schema', { host: 'evil.example', 'x-installer-token': app.token }), 403);
    const options = await app.fetch('/api/schema', { method: 'OPTIONS' });
    assert.equal(options.status, 405);
    assert.equal(options.headers.get('access-control-allow-origin'), null);
    const unknown = await app.fetch('/nope');
    assert.equal(unknown.status, 404);
    const large = await app.fetch('/api/commands', { method: 'POST', body: JSON.stringify({ x: 'x'.repeat(300_000) }) });
    assert.equal(large.status, 413);
    const bad = await app.fetch('/api/commands', { method: 'POST', body: '{' });
    assert.equal(bad.status, 400);
    const ok = await app.fetch('/?token=test-token-with-at-least-32-bytes-0000');
    assert.match(ok.headers.get('set-cookie'), /HttpOnly/);
    assert.match(ok.headers.get('content-security-policy'), /default-src 'self'/);
  } finally {
    await app.close();
  }
});

test('the form renders from the answers schema and exposes portable commands', async () => {
  const app = await start();
  try {
    const html = await (await app.fetch('/')).text();
    assert.match(html, /id="foundation"/);
    assert.match(html, /api\/schema/);
    const schema = await (await app.fetch('/api/schema')).json();
    assert.equal(schema.properties.SubscriptionId.title, 'Subscription');
    const commands = await (await app.fetch('/api/commands', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ answersPath: '.\\answers.json' }),
    })).json();
    assert.match(commands.powershell, /Install-ClaudeGateway\.ps1 -AnswersPath '.\\answers\.json' -Preflight -Json/);
    assert.match(commands.bash, /install-claude-gateway\.sh --answers-file '\.\/answers\.json' --preflight --json/);
    assert.ok(commands.bashDoesNotApply.includes('BusinessUnits'));
  } finally {
    await app.close();
  }
});

test('preflight writes answers to a temporary file and invokes the installer without a shell', async () => {
  const app = await start();
  try {
    const result = await (await app.fetch('/api/preflight', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ answers: { schemaVersion: 1, SubscriptionId: '00000000-0000-4000-8000-000000000093' } }),
    })).json();
    assert.equal(result.preflight.schemaVersion, 1);
    assert.equal(result.preflight.checks[0].reason, 'not-signed-in');
    const log = (await readFile(app.log, 'utf8')).trim().split(/\r?\n/).map(JSON.parse);
    assert.equal(log[0].mode, 'powershell');
    assert.deepEqual(log[0].args.slice(-2), ['-Preflight', '-Json']);
    assert.ok(log[0].args.includes('-AnswersPath'));
    await assert.rejects(readFile(log[0].args[log[0].args.indexOf('-AnswersPath') + 1], 'utf8'));
  } finally {
    await app.close();
  }
});

test('selected runs, failed-step reruns, step injection, redaction and single-run locking work through the stub', async () => {
  const app = await start({ env: { P93_INSTALLER_UI_STUB_FAIL_STEP: 'gateway-deployment' } });
  try {
    const injected = await app.fetch('/api/run', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ answers: {}, steps: ['resource-group;Remove-Item'] }),
    });
    assert.equal(injected.status, 400);
    assert.match((await injected.json()).error, /unknown step id/);

    const run = await (await app.fetch('/api/run', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ answers: {}, steps: ['gateway-deployment'] }),
    })).json();
    assert.equal(run.exitCode, 7);
    assert.equal(run.failedStepId, 'gateway-deployment');
    assert.doesNotMatch(JSON.stringify(run), /super-secret|abc\.def\.ghi/);
    assert.match(JSON.stringify(run), /\[redacted\]/);
  } finally {
    await app.close();
  }

  const slowStub = join(tmpdir(), `p93-slow-stub-${process.pid}.mjs`);
  await writeFile(slowStub, `
if (process.argv.includes('-ListSteps')) {
  console.log(JSON.stringify({ schemaVersion: 1, steps: [{ id: 'resource-group', title: 'Resource group' }] }));
  process.exit(0);
}
setTimeout(() => { console.log('done'); process.exit(0); }, 500);
`, 'utf8');
  const slow = await start({ stubInstaller: slowStub });
  try {
    const first = slow.fetch('/api/run', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ answers: {}, steps: ['resource-group'] }),
    });
    await new Promise((resolve) => setTimeout(resolve, 50));
    const second = await slow.fetch('/api/run', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ answers: {}, steps: ['resource-group'] }),
    });
    assert.equal(second.status, 409);
    assert.equal((await first).status, 200);
  } finally {
    await slow.close();
    await rm(slowStub, { force: true });
  }
});
