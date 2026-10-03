import assert from 'node:assert/strict';
import { once } from 'node:events';
import { spawn } from 'node:child_process';
import { request } from 'node:http';
import { readFile, rm, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { createInstallerUiServer } from '../tools/installer-ui/server.mjs';
import { collectAnswersFromEntries, validateBusinessUnits } from '../tools/installer-ui/ui-model.mjs';

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

function captureOutput(child) {
  const chunks = [];
  child.stdout.on('data', (chunk) => chunks.push(chunk.toString('utf8')));
  child.stderr.on('data', (chunk) => chunks.push(chunk.toString('utf8')));
  return () => chunks.join('');
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
    assert.doesNotMatch(ok.headers.get('content-security-policy'), /unsafe-inline/);
  } finally {
    await app.close();
  }
});

test('the form uses fixed script routes and no string-built DOM insertion sinks', async () => {
  const app = await start();
  try {
    const html = await (await app.fetch('/')).text();
    assert.match(html, /<script type="module" src="\.\/installer-ui\.js"><\/script>/);
    assert.doesNotMatch(html, /<script>\s*\(/);
    const js = await (await app.fetch('/installer-ui.js')).text();
    assert.doesNotMatch(js, /innerHTML|insertAdjacentHTML/);
  } finally {
    await app.close();
  }
});

test('the static fallback carries a schema copy equal to the canonical schema', async () => {
  const staticHtml = await readFile(new URL('../tools/installer-ui/index.html', import.meta.url), 'utf8');
  const carried = staticHtml.match(/<script type="application\/json" id="schema-json">([\s\S]*?)<\/script>/);
  assert.ok(carried, 'static HTML carries schema JSON');
  const canonical = JSON.parse(await readFile(new URL('../schemas/claude-gateway.answers.schema.json', import.meta.url), 'utf8'));
  assert.deepEqual(JSON.parse(carried[1]), canonical);
});

test('the form renders from the answers schema and exposes portable commands', async () => {
  const app = await start();
  try {
    const html = await (await app.fetch('/')).text();
    assert.match(html, /id="foundation"/);
    assert.match(html, /schema-json/);
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

test('untouched controls are not collected as answers and business units enforce installer rules', async () => {
  const schema = JSON.parse(await readFile(new URL('../schemas/claude-gateway.answers.schema.json', import.meta.url), 'utf8'));
  assert.deepEqual(collectAnswersFromEntries(schema, new Map([
    ['Sku', ''],
    ['AddressMode', ''],
    ['DeployProjection', ''],
    ['ResourceGroup', 'rg-p93'],
    ['StandardModels', 'claude-sonnet-5, claude-opus-5'],
  ])), { schemaVersion: 1, ResourceGroup: 'rg-p93', StandardModels: ['claude-sonnet-5', 'claude-opus-5'] });
  assert.deepEqual(validateBusinessUnits([
    { id: 'finance', group: 'claude-bu-finance', monthlyUsdBudget: 100, mode: 'Strict' },
    { id: 'finance-emea', group: 'claude-team-finance-emea', parent: 'finance', monthlyUsdBudget: 50, mode: 'Allowance', percent: 50 },
  ]), []);
  assert.match(validateBusinessUnits([
    { id: 'Finance', group: 'bad,group', parent: 'missing', monthlyUsdBudget: -1, mode: 'Allowance' },
  ]).join(' | '), /lower-case|group name|parent|monthly budget|percent/);
});

test('identity, prefill and plan routes go through repository PowerShell seams', async () => {
  const app = await start({ env: {
    P93_INSTALLER_UI_IDENTITY_JSON: JSON.stringify({ schemaVersion: 1, signedIn: true, user: 'operator@example.com', tenantId: 'tenant-1', subscriptionName: 'Sub One', subscriptionId: 'sub-1' }),
    P93_INSTALLER_UI_PREFILL_JSON: JSON.stringify({ schemaVersion: 1, subscriptions: [{ id: 'sub-1', name: 'Sub One' }], foundryAccounts: [{ name: 'ai-p93' }], deployments: [{ name: 'claude-sonnet-5' }] }),
    P93_INSTALLER_UI_PLAN_JSON: JSON.stringify({ schemaVersion: 1, fingerprint: 'sha256:p93', text: 'plan ok' }),
  } });
  try {
    const identity = await (await app.fetch('/api/identity')).json();
    assert.equal(identity.user, 'operator@example.com');
    assert.equal(identity.subscriptionName, 'Sub One');
    const prefill = await (await app.fetch('/api/prefill?kind=subscriptions')).json();
    assert.equal(prefill.subscriptions[0].id, 'sub-1');
    const plan = await (await app.fetch('/api/plan', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ answers: { schemaVersion: 1, ResourceGroup: 'rg-p93' } }),
    })).json();
    assert.equal(plan.fingerprint, 'sha256:p93');
  } finally {
    await app.close();
  }
});

test('preflight writes answers to a temporary file, invokes the installer without a shell and returns table metadata', async () => {
  const app = await start();
  try {
    const result = await (await app.fetch('/api/preflight', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ answers: { schemaVersion: 1, SubscriptionId: '00000000-0000-4000-8000-000000000093' } }),
    })).json();
    assert.equal(result.preflight.schemaVersion, 1);
    assert.equal(result.preflight.checks[0].reason, 'not-signed-in');
    assert.ok(result.fieldsByCheckId['target.subscription'].includes('SubscriptionId'));
    const log = (await readFile(app.log, 'utf8')).trim().split(/\r?\n/).map(JSON.parse);
    assert.equal(log[0].mode, 'powershell');
    assert.deepEqual(log[0].args.slice(-2), ['-Preflight', '-Json']);
    assert.ok(log[0].args.includes('-AnswersPath'));
    await assert.rejects(readFile(log[0].args[log[0].args.indexOf('-AnswersPath') + 1], 'utf8'));
  } finally {
    await app.close();
  }
});

test('selected runs stream progress, refuse empty selections, support explicit full runs and expose failed-step reruns', async () => {
  const app = await start({ env: { P93_INSTALLER_UI_STUB_FAIL_STEP: 'gateway-deployment' } });
  try {
    const injected = await app.fetch('/api/run', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ answers: {}, steps: ['resource-group;Remove-Item'] }),
    });
    assert.equal(injected.status, 400);
    assert.match((await injected.json()).error, /unknown step id/);
    const empty = await app.fetch('/api/run', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ answers: {}, steps: [] }),
    });
    assert.equal(empty.status, 400);
    assert.match((await empty.json()).error, /select at least one step/i);

    const run = await (await app.fetch('/api/run/stream', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ answers: {}, steps: ['gateway-deployment'] }),
    })).text();
    const events = run.trim().split(/\r?\n/).map((line) => JSON.parse(line));
    assert.ok(events.some((event) => event.type === 'progress' && event.stepId === 'gateway-deployment' && event.event === 'failed'));
    assert.ok(events.some((event) => event.type === 'summary' && event.failedStepId === 'gateway-deployment' && /-Steps gateway-deployment/.test(event.resumeCommand)));
    assert.doesNotMatch(run, /super-secret|abc\.def\.ghi/);
    assert.match(run, /\[redacted\]/);

    const full = await app.fetch('/api/run', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ answers: { ResourceGroup: 'rg-p93' }, steps: [], fullRun: true, confirmFullRun: true, account: { user: 'operator@example.com' } }),
    });
    assert.equal(full.status, 200);
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

    test('idle shutdown exits the CLI process, closes connections and says why', async () => {
      const child = spawn(process.execPath, [serverCli, '--idle-ms', '100'], { cwd: new URL('..', import.meta.url), stdio: ['ignore', 'pipe', 'pipe'] });
      const outputOf = captureOutput(child);
      try {
        const output = await waitForOutput(child, /One-time token:/);
        assert.match(output, /Claude gateway installer UI:/);
        const [code] = await once(child, 'exit');
        assert.equal(code, 0);
        assert.match(outputOf(), /Installer UI stopped: idle timeout/);
      } finally {
        if (!child.killed && child.exitCode === null) child.kill('SIGINT');
      }
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
