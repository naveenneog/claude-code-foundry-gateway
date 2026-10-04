import assert from 'node:assert/strict';
import { once } from 'node:events';
import { spawn } from 'node:child_process';
import { request } from 'node:http';
import { mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { createContext, runInContext } from 'node:vm';
import { createInstallerUiServer } from '../tools/installer-ui/server.mjs';

const stub = fileURLToPath(new URL('./installer-ui-stub.mjs', import.meta.url));
const serverCli = fileURLToPath(new URL('../tools/installer-ui/server.mjs', import.meta.url));
const repoRoot = fileURLToPath(new URL('..', import.meta.url)).replace(/[\\/]+$/, '');
const escapeRegExp = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const localPathPattern = new RegExp([homedir(), repoRoot].map(escapeRegExp).join('|') + '|[A-Za-z]:\\\\|Get-ClaudeInstallerUiPrefill\\.ps1', 'i');
const modelContext = createContext({ globalThis: {} });
runInContext(await readFile(new URL('../tools/installer-ui/ui-model.js', import.meta.url), 'utf8'), modelContext);
const { collectAnswersFromEntries, validateBusinessUnits } = modelContext.globalThis.ClaudeInstallerUiModel;

async function start(extra = {}) {
  const scratch = join(tmpdir(), `p93-ui-${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`);
  const log = join(scratch, 'stub.ndjson');
  await rm(scratch, { recursive: true, force: true });
  await mkdir(scratch, { recursive: true });
  const env = { P93_INSTALLER_UI_STUB_LOG: log, ...(extra.env || {}) };
  if (extra.az) {
    const stub = join(scratch, 'az.cmd');
    await writeFile(stub, `@echo off\r\nnode "${stub.replace(/\\/g, '\\\\')}.mjs" %*\r\n`, 'utf8');
    await writeFile(`${stub}.mjs`, `
import { appendFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
const args = process.argv.slice(2);
const joined = args.join(' ');
if (process.env.P93_AZ_LOG) appendFileSync(process.env.P93_AZ_LOG, joined + '\\n');
if (process.env.P93_AZ_ENV_LOG) appendFileSync(process.env.P93_AZ_ENV_LOG, JSON.stringify({ args: joined, NO_COLOR: process.env.NO_COLOR ?? null }) + '\\n');
if (joined.includes('path-error')) { console.error('ERROR: cannot read ' + join(homedir(), '.azure', 'config') + ' from ' + process.cwd()); process.exit(1); }
if (joined.includes('fail-secret')) { console.error('password=super-secret failed'); process.exit(9); }
if (joined.startsWith('account show')) { console.log(JSON.stringify({ id: '00000000-0000-4000-8000-000000000093', name: 'Sub One', tenantId: 'tenant-1', user: { name: 'operator@example.com' } })); process.exit(0); }
if (joined.startsWith('account list')) { console.log(JSON.stringify([{ id: '00000000-0000-4000-8000-000000000093', name: 'Sub One', tenantId: 'tenant-1' }])); process.exit(0); }
if (joined.startsWith('cognitiveservices account list')) { console.log(JSON.stringify([{ name: 'ai-p93', resourceGroup: 'rg-ai-p93', location: 'eastus2' }])); process.exit(0); }
if (joined.startsWith('cognitiveservices account deployment list')) { console.log(JSON.stringify([{ name: 'claude-sonnet-5', properties: { model: { name: 'claude', version: '5' } } }])); process.exit(0); }
console.error('unexpected az ' + joined); process.exit(2);
`, 'utf8');
    env.PATH = `${scratch};${process.env.PATH}`;
    env.P93_AZ_LOG = join(scratch, 'az.log');
    env.P93_AZ_ENV_LOG = join(scratch, 'az-env.log');
  }
  const server = await createInstallerUiServer({
    token: 'test-token-with-at-least-32-bytes-0000',
    stubInstaller: extra.stubInstaller || stub,
    idleMs: 60_000,
    env,
  });
  const address = await server.listenAsync('127.0.0.1');
  const base = `http://127.0.0.1:${address.port}`;
  const boot = await fetch(`${base}/?token=${encodeURIComponent(server.token)}`, { redirect: 'manual' });
  const cookie = boot.headers.get('set-cookie').split(';')[0];
  const session = await (await fetch(`${base}/api/session`, { headers: { cookie } })).json();
  return {
    base,
    log,
    scratch,
    token: server.token,
    cookie,
    csrfToken: session.csrfToken,
    async fetch(path, options = {}) {
      const headers = { cookie, ...(options.headers || {}) };
      if (options.method === 'POST') headers['x-csrf-token'] ??= session.csrfToken;
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

async function streamEvents(app, body, path = '/api/run/stream') {
  const response = await app.fetch(path, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  const text = await response.text();
  return { response, text, events: text.trim() ? text.trim().split(/\r?\n/).map((line) => JSON.parse(line)) : [] };
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

test('non-loopback binding requires allow-host and logs refused host diagnostics to terminal only', async () => {
  const refused = spawn(process.execPath, [serverCli, '--host', '0.0.0.0', '--idle-ms', '5000'], { cwd: new URL('..', import.meta.url), stdio: ['ignore', 'pipe', 'pipe'] });
  const refusedOutput = captureOutput(refused);
  try {
    const [code] = await once(refused, 'exit');
    assert.notEqual(code, 0);
    assert.match(refusedOutput(), /--allow-host/);
  } finally {
    if (refused.exitCode === null) refused.kill('SIGINT');
  }

  const logs = [];
  const server = await createInstallerUiServer({ token: 'allow-host-token-with-32-bytes-0000', allowedHosts: ['preview.example.test'], log: (line) => logs.push(line) });
  const address = await server.listenAsync('127.0.0.1');
  try {
    assert.equal(await rawRequest(`http://127.0.0.1:${address.port}`, '/api/schema', {
      host: 'preview.example.test',
      cookie: `installer_token=${server.token}`,
    }), 200);
    const badStatus = await rawRequest(`http://127.0.0.1:${address.port}`, '/api/schema', {
      host: 'wrong.example.test',
      cookie: `installer_token=${server.token}`,
      'x-forwarded-host': 'cloudshell.example.test',
      'x-forwarded-proto': 'https',
      'x-forwarded-prefix': '/preview',
    });
    assert.equal(badStatus, 403);
    assert.match(logs.join('\n'), /wrong\.example\.test/);
    assert.match(logs.join('\n'), /cloudshell\.example\.test/);
    assert.match(logs.join('\n'), /x-forwarded-prefix=\/preview/);
  } finally {
    await server.cleanup();
    server.close();
    await once(server, 'close').catch(() => {});
  }
});

test('token, host, fixed routes and headers protect the local server', async () => {
  const app = await start();
  try {
    assert.equal((await fetch(`${app.base}/api/schema`)).status, 401);
    assert.equal((await fetch(`${app.base}/api/commands?token=${encodeURIComponent(app.token)}`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}' })).status, 401);
    assert.equal((await fetch(`${app.base}/?token=${encodeURIComponent(app.token)}`, { redirect: 'manual' })).status, 401);
    assert.equal(await rawRequest(app.base, '/api/schema', { host: 'evil.example', cookie: app.cookie }), 403);
    const options = await app.fetch('/api/schema', { method: 'OPTIONS' });
    assert.equal(options.status, 405);
    assert.equal(options.headers.get('access-control-allow-origin'), null);
    const unknown = await app.fetch('/nope');
    assert.equal(unknown.status, 404);
    const large = await app.fetch('/api/commands', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ x: 'x'.repeat(300_000) }) });
    assert.equal(large.status, 413);
    const badContent = await app.fetch('/api/commands', { method: 'POST', headers: { 'content-type': 'text/plain' }, body: '{}' });
    assert.equal(badContent.status, 415);
    const bad = await app.fetch('/api/commands', { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{' });
    assert.equal(bad.status, 400);
    const ok = await app.fetch('/');
    assert.match(ok.headers.get('content-security-policy'), /default-src 'self'/);
    assert.doesNotMatch(ok.headers.get('content-security-policy'), /unsafe-inline/);
    const noCsrf = await fetch(`${app.base}/api/commands`, { method: 'POST', headers: { cookie: app.cookie, 'content-type': 'application/json' }, body: '{}' });
    assert.equal(noCsrf.status, 403);
    const cross = await fetch(`${app.base}/api/preflight`, { method: 'POST', headers: { cookie: app.cookie, 'content-type': 'application/json', 'x-csrf-token': app.csrfToken, origin: 'http://127.0.0.1:1' }, body: '{}' });
    assert.equal(cross.status, 403);
  } finally {
    await app.close();
  }
});

test('the form uses fixed script routes and no string-built DOM insertion sinks', async () => {
  const app = await start();
  try {
    const html = await (await app.fetch('/')).text();
    assert.match(html, /<script defer src="\.\/ui-model\.js"><\/script>\s*<script defer src="\.\/installer-ui\.js"><\/script>/);
    assert.doesNotMatch(html, /type="module"|import\s+|export\s+/);
    assert.doesNotMatch(html, /<script>\s*\(/);
    const js = await (await app.fetch('/installer-ui.js')).text();
    assert.doesNotMatch(js, /innerHTML|insertAdjacentHTML|import\s+|export\s+/);
    for (const name of ['buildPortableCommands', 'coerceAnswerValue', 'collectAnswersFromEntries', 'fieldsByCheckId', 'quoteBash', 'quotePowerShell', 'validateBusinessUnits']) {
      assert.doesNotMatch(js, new RegExp(`function\\s+${name}\\b|const\\s+${name}\\b`), `${name} must live only in ui-model.js`);
    }
    const model = await (await app.fetch('/ui-model.js')).text();
    assert.match(model, /ClaudeInstallerUiModel/);
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
  assert.doesNotMatch(staticHtml, /type="module"|import\s+|export\s+/);
  assert.match(staticHtml, /ui-model\.js/);
});

test('the static fallback renders fields in a real browser from file', async () => {
  const { chromium } = await import('playwright');
  let browser;
  try { browser = await chromium.launch({ channel: 'msedge', headless: true }); }
  catch { browser = await chromium.launch({ headless: true }); }
  try {
    const page = await browser.newPage();
    await page.goto(new URL('../tools/installer-ui/index.html', import.meta.url).href);
    await page.waitForSelector('[name="SubscriptionId"]');
    assert.equal(await page.locator('#foundation label').count(), 8);
    await expectText(page, 'PowerShell preflight');
    await page.getByRole('button', { name: 'Add unit' }).click();
    await page.locator('[data-bu-field="id"]').first().fill('finance');
    await page.locator('[data-bu-field="group"]').first().fill('claude-bu-finance');
    await page.locator('[data-bu-field="monthlyUsdBudget"]').first().fill('5000');
    await page.getByRole('button', { name: 'Add team' }).click();
    await expectText(page, 'Team under finance');
    assert.equal(await page.locator('fieldset').count(), 2);
    assert.match(await page.locator('#business-units').inputValue(), /"id": "finance"/);
    assert.match(await page.locator('#business-units').inputValue(), /"parent": "finance"/);
    assert.ok((await page.locator('#business-units').inputValue()).indexOf('"id": "finance"') < (await page.locator('#business-units').inputValue()).indexOf('"parent": "finance"'));
    await page.getByText('JSON view').click();
    await page.locator('#business-units').fill('[{"id":');
    assert.match(await page.locator('#business-unit-problems').textContent(), /JSON/i);
    assert.equal(await page.locator('fieldset').count(), 2);
    await page.locator('#business-units').fill('[{"id":"sales","group":"claude-bu-sales","monthlyUsdBudget":100,"mode":"Strict"}]');
    assert.equal(await page.locator('fieldset').count(), 1);
    assert.match(await page.locator('#business-units').inputValue(), /"id": "sales"/);
    await page.locator('[data-bu-field="id"]').first().fill('Finance');
    assert.match(await page.locator('#business-unit-problems').textContent(), /lower-case/);
  } finally {
    await browser.close();
  }
});

async function expectText(page, text) {
  await page.getByText(text).first().waitFor();
}

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
  assert.deepEqual(JSON.parse(JSON.stringify(collectAnswersFromEntries(schema, new Map([
    ['Sku', ''],
    ['AddressMode', ''],
    ['DeployProjection', ''],
    ['ResourceGroup', 'rg-p93'],
    ['StandardModels', 'claude-sonnet-5, claude-opus-5'],
  ])))), { schemaVersion: 1, ResourceGroup: 'rg-p93', StandardModels: ['claude-sonnet-5', 'claude-opus-5'] });
  assert.deepEqual(JSON.parse(JSON.stringify(validateBusinessUnits([
    { id: 'finance', group: 'claude-bu-finance', monthlyUsdBudget: 100, mode: 'Strict' },
    { id: 'finance-emea', group: 'claude-team-finance-emea', parent: 'finance', monthlyUsdBudget: 50, mode: 'Allowance', percent: 50 },
  ]))), []);
  assert.match(validateBusinessUnits([
    { id: 'Finance', group: 'bad,group', parent: 'missing', monthlyUsdBudget: -1, mode: 'Allowance' },
  ]).join(' | '), /lower-case|group name|parent|monthly budget|percent/);
  assert.match(validateBusinessUnits([
    { id: 'finance', group: 'claude-bu-finance', monthlyUsdBudget: 100, mode: 'Strict' },
    { id: 'finance', group: 'claude-bu-finance-2', monthlyUsdBudget: 100, mode: 'Strict' },
  ]).join(' | '), /duplicates/);
  assert.match(validateBusinessUnits([
    { id: 'finance', group: 'claude-bu-finance', monthlyUsdBudget: 100, mode: 'Strict' },
    { id: 'finance-emea', group: 'claude-team-finance-emea', parent: 'finance', monthlyUsdBudget: 50, mode: 'Strict' },
    { id: 'finance-emea-1', group: 'claude-team-finance-emea-1', parent: 'finance-emea', monthlyUsdBudget: 20, mode: 'Strict' },
  ]).join(' | '), /deeper than two levels/);
  assert.match(validateBusinessUnits([
    { id: 'engineering', group: 'claude-bu-engineering', monthlyUsdBudget: 100, mode: 'Allowance' },
  ]).join(' | '), /percent is required/);
});

test('identity, prefill and plan routes go through repository PowerShell seams', async () => {
  const app = await start({ az: true });
  try {
    const identity = await (await app.fetch('/api/identity')).json();
    assert.equal(identity.user, 'operator@example.com');
    assert.equal(identity.tenantId, 'tenant-1');
    assert.equal(identity.subscriptionName, 'Sub One');
    assert.equal(identity.subscriptionId, '00000000-0000-4000-8000-000000000093');
    const { chromium } = await import('playwright');
    const browser = await chromium.launch({ headless: true });
    try {
      const page = await browser.newPage();
      await page.context().addCookies([{ name: 'installer_token', value: app.token, domain: '127.0.0.1', path: '/', httpOnly: true, sameSite: 'Strict' }]);
      await page.goto(`${app.base}/`);
      await page.getByText('operator@example.com').waitFor();
      const banner = await page.locator('#identity').textContent();
      assert.match(banner, /tenant-1/);
      assert.match(banner, /Sub One/);
      assert.match(banner, /00000000-0000-4000-8000-000000000093/);
    } finally {
      await browser.close();
    }
    const prefill = await (await app.fetch('/api/prefill', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ kind: 'subscriptions' }) })).json();
    assert.equal(prefill.subscriptions[0].id, '00000000-0000-4000-8000-000000000093');
    const foundry = await (await app.fetch('/api/prefill', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ kind: 'foundryAccounts', subscriptionId: '00000000-0000-4000-8000-000000000093' }) })).json();
    assert.equal(foundry.foundryAccounts[0].name, 'ai-p93');
  } finally {
    await app.close();
  }
});

test('az errors in prefill are returned as redacted errors', async () => {
  const secretSentence = `jwt ******.eyJwOTIiOiJyZWRhY3QifQ.p92JwtSentinel Authorization: ****** https://p92.blob.core.windows.net/c?sv=2024-01-01&sig=p92SigSentinel&se=2026 signature=p92SignatureSentinel AccountName=p92;AccountKey=p92AccountKeySentinel==;EndpointSuffix=core SharedAccessKey=p92SharedAccessKeySentinel; SharedAccessSignature: p92SharedAccessSignatureSentinel client_secret=p92ClientSecretSentinel&grant_type=client_credentials {"clientSecret": "p92ClientSecretCamelSentinel"} ****** pwd: p92PwdSentinel secret=p92SecretSentinel access_token=p92AccessTokenSentinel refresh_token: 'p92RefreshTokenSentinel'`;
  const app = await start({ az: true, env: { P93_AZ_SECRET_ERROR: secretSentence } });
  try {
    const result = await (await app.fetch('/api/prefill', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ kind: 'deployments', foundryAccount: 'fail-secret', foundryResourceGroup: 'rg' }) })).json();
    assert.match(result.error, /\[redacted\]/);
    for (const sentinel of ['p92JwtSentinel', 'p92SigSentinel', 'p92SignatureSentinel', 'p92AccountKeySentinel', 'p92SharedAccessKeySentinel', 'p92SharedAccessSignatureSentinel', 'p92ClientSecretSentinel', 'p92ClientSecretCamelSentinel', 'p92PwdSentinel', 'p92SecretSentinel', 'p92AccessTokenSentinel', 'p92RefreshTokenSentinel']) {
      assert.doesNotMatch(result.error, new RegExp(sentinel));
    }
    assert.doesNotMatch(result.error, /p92[A-Za-z]+Sentinel/);
  } finally {
    await app.close();
  }
});

test('prefill validates parameters before invoking az.cmd', async () => {
  const app = await start({ az: true });
  try {
    const marker = '&echo.P93_PREFILL_MARKER&rem';
    const markerResponse = await app.fetch('/api/prefill', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ kind: 'foundryAccounts', subscriptionId: marker }) });
    assert.equal(markerResponse.status, 400, 'a refused answer is a request problem');
    const result = await markerResponse.json();
    assert.equal(result.field, 'SubscriptionId');
    assert.match(result.error, /is not valid for installer UI prefill/);
    assert.match(result.patternMessage, /GUID/);
    assert.match(result.remedy, /subscription id/i);
    assert.doesNotMatch(JSON.stringify(result), /\u001b\[[0-9;]*m|Users[\\/]|Get-ClaudeInstallerUiPrefill\.ps1/);
    const logPath = join(app.scratch, 'az.log');
    const log = existsSync(logPath) ? await readFile(logPath, 'utf8') : '';
    assert.equal(log, '', 'a refused subscription id reaches no az call');
    const missing = await (await app.fetch('/api/prefill', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ kind: 'deployments', foundryAccount: 'ai-p93' }) })).json();
    assert.equal(missing.field, 'FoundryResourceGroup');
    assert.match(missing.error, /required/);
    const logAfterMissing = existsSync(logPath) ? await readFile(logPath, 'utf8') : '';
    assert.equal(logAfterMissing, log);
    // Azure allows ( and ) in a resource group name; az.cmd expands its arguments inside an IF ( ... ) block.
    const parens = await (await app.fetch('/api/prefill', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ kind: 'deployments', foundryAccount: 'ai-p93', foundryResourceGroup: 'rg(prod)' }) })).json();
    assert.equal(parens.field, 'FoundryResourceGroup');
    assert.match(parens.error, /az\.cmd/);
    assert.match(parens.remedy, /\w/);
    assert.equal(existsSync(logPath) ? await readFile(logPath, 'utf8') : '', log, 'a resource group with parentheses reaches no az.cmd call');
    for (const body of [{ kind: 'bogus' }, { kind: ['subscriptions'] }, { kind: 'deployments', foundryAccount: ['ai-p93'], foundryResourceGroup: 'rg-p93' }]) {
      const response = await app.fetch('/api/prefill', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
      const text = await response.text();
      assert.equal(response.status, 400, text);
      const refused = JSON.parse(text);
      assert.ok(refused.field, text);
      assert.match(refused.remedy, /\w/, text);
      assert.doesNotMatch(refused.error, localPathPattern, text);
      assert.equal(existsSync(logPath) ? await readFile(logPath, 'utf8') : '', log, `${text} reaches no az call`);
    }
    const pathError = await (await app.fetch('/api/prefill', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ kind: 'deployments', foundryAccount: 'path-error', foundryResourceGroup: 'rg-p93' }) })).json();
    assert.match(pathError.error, /cannot read/);
    assert.doesNotMatch(pathError.error, localPathPattern);
    const dashed = await (await app.fetch('/api/prefill', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ kind: 'foundryAccounts', subscriptionId: '-Kind' }) })).json();
    assert.equal(dashed.field, 'SubscriptionId', 'a value that starts with - binds as the value, not as a PowerShell parameter name');
    // The identity seam does not set NO_COLOR itself, so its az call shows the environment the server gives PowerShell.
    assert.equal((await app.fetch('/api/identity')).status, 200);
    const envLog = (await readFile(join(app.scratch, 'az-env.log'), 'utf8')).trim().split(/\r?\n/).filter(Boolean).map((line) => JSON.parse(line));
    assert.ok(envLog.some((entry) => entry.args.startsWith('account show')), 'the identity seam reached az');
    for (const entry of envLog) assert.equal(entry.NO_COLOR, '1', entry.args);
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
    const injected = await app.fetch('/api/run/stream', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ answers: {}, steps: ['resource-group;Remove-Item'] }),
    });

    assert.equal(injected.status, 400);
    assert.match((await injected.json()).error, /unknown step id/);
    const empty = await app.fetch('/api/run/stream', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ answers: {}, steps: [] }),
    });
    assert.equal(empty.status, 400);
    assert.match((await empty.json()).error, /select at least one step/i);
    const streamEmpty = await app.fetch('/api/run/stream', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ answers: {}, steps: [] }),
    });
    assert.equal(streamEmpty.status, 400);
    assert.match((await streamEmpty.json()).error, /select at least one step/i);
    const streamInjected = await app.fetch('/api/run/stream', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ answers: {}, steps: ['not-a-step'] }),
    });
    assert.equal(streamInjected.status, 400);
    assert.match((await streamInjected.json()).error, /unknown step id/);

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

    const full = await app.fetch('/api/run/stream', {
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
import { appendFileSync } from 'node:fs';
if (process.env.P93_INSTALLER_UI_STUB_LOG) appendFileSync(process.env.P93_INSTALLER_UI_STUB_LOG, JSON.stringify({ mode: process.argv[2], args: process.argv.slice(3) }) + '\\n');
if (process.argv.includes('-ListSteps')) {
  console.log(JSON.stringify({ schemaVersion: 1, installer: 'pwsh', checkpoint: null, runId: null, steps: [{ id: 'resource-group', title: 'Resource group', dependencies: [], state: 'not-started' }] }));
  process.exit(0);
}
setTimeout(() => { console.log('done'); process.exit(0); }, 500);
`, 'utf8');
  const slow = await start({ stubInstaller: slowStub });
  try {
    const first = slow.fetch('/api/run/stream', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ answers: {}, steps: ['resource-group'] }),
    });
    const second = slow.fetch('/api/run/stream', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ answers: {}, steps: ['resource-group'] }),
    });
    const responses = await Promise.all([first, second]);
    assert.deepEqual(responses.map((response) => response.status).sort(), [200, 409]);
    const log = (await readFile(slow.log, 'utf8')).trim().split(/\r?\n/).filter(Boolean).map(JSON.parse);
    assert.equal(log.filter((entry) => entry.args.includes('-Yes')).length, 1);
  } finally {
    await slow.close();
    await rm(slowStub, { force: true });
  }
});

test('stream transport preserves split output, final tails, malformed progress and the output cap', async () => {
  for (const [env, expected] of [
    [{ P93_INSTALLER_UI_STUB_MULTIBYTE: '1' }, /split 😀 line/],
    [{ P93_INSTALLER_UI_STUB_SPLIT_LINE: '1' }, /split line/],
    [{ P93_INSTALLER_UI_STUB_NO_FINAL_NEWLINE: '1' }, /last line without newline/],
  ]) {
    const app = await start({ env });
    try {
      const { text, events } = await streamEvents(app, { answers: {}, steps: ['resource-group'] });
      assert.match(text, expected);
      assert.ok(events.some((event) => event.type === 'summary'));
      assert.doesNotMatch(text, /\uFFFD/);
    } finally {
      await app.close();
    }
  }

  const tail = await start({ env: { P93_INSTALLER_UI_STUB_PROGRESS_NO_NEWLINE: '1' } });
  try {
    const { events } = await streamEvents(tail, { answers: {}, steps: ['resource-group'] });
    const summary = events.find((event) => event.type === 'summary');
    assert.equal(summary.failedStepId, 'resource-group');
    assert.match(summary.resumeCommand, /-Steps resource-group/);
  } finally {
    await tail.close();
  }

  const malformed = await start({ env: { P93_INSTALLER_UI_STUB_MALFORMED_PROGRESS: '1' } });
  try {
    const { text, events } = await streamEvents(malformed, { answers: {}, steps: ['resource-group'] });
    assert.ok(events.some((event) => event.type === 'error' && /progress/i.test(event.message)));
    assert.ok(events.some((event) => event.type === 'summary'));
    assert.doesNotMatch(text, /super-secret/);
    assert.equal((await malformed.fetch('/api/session')).status, 200);
  } finally {
    await malformed.close();
  }

  const capped = await start({ env: { P93_INSTALLER_UI_STUB_MANY_LINES: '6000', P93_INSTALLER_UI_STUB_PAD: '1000' } });
  try {
    const { text, events } = await streamEvents(capped, { answers: {}, steps: ['resource-group'] });
    assert.ok(events.some((event) => event.type === 'notice' && /output cap/i.test(event.message)));
    assert.ok(events.some((event) => event.type === 'summary'));
    assert.ok(Buffer.byteLength(text) < 4_700_000, `stream was ${Buffer.byteLength(text)} bytes`);
  } finally {
    await capped.close();
  }
});

test('stream ordering, removed run route and browser DOM cap are enforced', async () => {
  const app = await start({ env: { P93_INSTALLER_UI_STUB_MANY_LINES: '500' } });
  try {
    const removed = await app.fetch('/api/run', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ answers: {}, steps: ['resource-group'] }),
    });
    assert.equal(removed.status, 404);
    const { events } = await streamEvents(app, { answers: {}, steps: ['resource-group'] });
    const lines = events.filter((event) => event.type === 'stdout').map((event) => event.line);
    assert.deepEqual(lines.slice(0, 20), Array.from({ length: 20 }, (_, i) => `line ${String(i).padStart(4, '0')}`));
  } finally {
    await app.close();
  }

  const pageApp = await start({ env: { P93_INSTALLER_UI_STUB_MANY_LINES: '2600' } });
  const { chromium } = await import('playwright');
  const browser = await chromium.launch({ headless: true });
  try {
    const page = await browser.newPage();
    await page.context().addCookies([{ name: 'installer_token', value: pageApp.token, domain: '127.0.0.1', path: '/', httpOnly: true, sameSite: 'Strict' }]);
    await page.goto(`${pageApp.base}/`);
    await page.getByRole('button', { name: 'List steps' }).click();
    await page.locator('#step-list input').first().check();
    await page.getByRole('button', { name: 'Run selected steps' }).click();
    await expectText(page, 'summary:');
    const output = await page.locator('#run-output').textContent();
    assert.match(output, /Earlier run output lines were removed \(601\)\./, '2,601 appended lines, 2,000 kept');
    const shown = output.trimEnd().split('\n');
    assert.equal(shown.length, 2001, 'the notice and the 2,000 latest lines');
    assert.match(shown[1], /line 0601$/, 'the oldest kept line follows the 601 removed ones');
  } finally {
    await browser.close();
    await pageApp.close();
  }
});

test('run lifecycle survives disconnect, reports status, supports reattach and stop', async () => {
  const app = await start({ env: { P93_INSTALLER_UI_STUB_DELAY_MS: '80' } });
  try {
    const run = await app.fetch('/api/run/stream', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ answers: {}, steps: ['resource-group', 'gateway-deployment'] }),
    });
    await run.text();
    const status = await (await app.fetch('/api/run/status')).json();
    assert.equal(status.state, 'exited');
    assert.equal(status.exitCode, 0);
    const attach = await (await app.fetch('/api/run/attach?after=0')).text();
    assert.match(attach, /"type":"summary"/);
    const log = (await readFile(app.log, 'utf8')).trim().split(/\r?\n/).filter(Boolean).map(JSON.parse);
    assert.equal(log.filter((entry) => entry.args.includes('-Yes')).length, 1);
  } finally {
    await app.close();
  }

  const stopApp = await start({ env: { P93_INSTALLER_UI_STUB_GRANDCHILD_HEARTBEAT: join(tmpdir(), `p93-heartbeat-${process.pid}.txt`) } });
  try {
    const runPromise = stopApp.fetch('/api/run/stream', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ answers: {}, steps: ['resource-group'] }),
    });
    let status;
    for (let i = 0; i < 30; i++) {
      status = await (await stopApp.fetch('/api/run/status')).json();
      if (status?.state === 'running' && status.currentStepId) break;
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    const stopped = await (await stopApp.fetch('/api/run/stop', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ runId: status.id }),
    })).json();
    assert.equal(stopped.error, undefined, JSON.stringify(stopped));
    assert.match(stopped.message, /resource-group/);
    assert.match(stopped.message, /checkpoint resumes/i);
    const runText = await (await runPromise).text();
    assert.match(runText, /stopped/);
  } finally {
    await stopApp.close();
  }
});

test('preflight malformed output, fail JSON and versioned interfaces fail closed visibly', async () => {
  const textApp = await start({ env: { P93_INSTALLER_UI_STUB_PREFLIGHT_TEXT: '1' } });
  try {
    const response = await textApp.fetch('/api/preflight', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ answers: {} }),
    });
    const body = await response.json();
    assert.equal(response.status, 502);
    assert.match(body.error, /preflight output was not JSON/);
    assert.match(body.detail, /\[redacted\]/);
    const { chromium } = await import('playwright');
    const browser = await chromium.launch({ headless: true });
    try {
      const page = await browser.newPage();
      await page.context().addCookies([{ name: 'installer_token', value: textApp.token, domain: '127.0.0.1', path: '/', httpOnly: true, sameSite: 'Strict' }]);
      await page.goto(`${textApp.base}/`);
      await page.getByRole('button', { name: 'Run preflight' }).click();
      await page.getByText(/preflight output was not JSON/).waitFor();
    } finally {
      await browser.close();
    }
  } finally {
    await textApp.close();
  }

  const failApp = await start({ env: { P93_INSTALLER_UI_STUB_PREFLIGHT_FAIL: '1' } });
  try {
    const response = await failApp.fetch('/api/preflight', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ answers: { SubscriptionId: '00000000-0000-4000-8000-000000000093' } }),
    });
    const body = await response.json();
    assert.equal(response.status, 200);
    assert.equal(body.exitCode, 1);
    assert.equal(body.preflight.result, 'FAIL');
  } finally {
    await failApp.close();
  }

  for (const [env, path, pattern] of [
    [{ P93_INSTALLER_UI_STUB_BAD_LIST: 'version' }, '/api/steps', /step list is schemaVersion 2/],
    [{ P93_INSTALLER_UI_STUB_BAD_LIST: 'missing' }, '/api/steps', /step list field steps/],
    [{ P93_INSTALLER_UI_STUB_BAD_LIST: 'type' }, '/api/steps', /step list field id|step list step 0/],
    [{ P93_INSTALLER_UI_STUB_BAD_PREFLIGHT: 'version' }, '/api/preflight', /preflight result is schemaVersion 2/],
    [{ P93_INSTALLER_UI_STUB_BAD_PREFLIGHT: 'missing' }, '/api/preflight', /preflight result field result/],
    [{ P93_INSTALLER_UI_STUB_BAD_PREFLIGHT: 'type' }, '/api/preflight', /preflight result field result|preflight result check 0 field result/],
  ]) {
    const app = await start({ env });
    try {
      const response = path === '/api/steps'
        ? await app.fetch(path)
        : await app.fetch(path, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ answers: {} }) });
      assert.equal(response.status, 502);
      assert.match((await response.json()).error, pattern);
    } finally {
      await app.close();
    }
  }

  for (const mode of ['version', 'missing', 'type']) {
    const app = await start({ env: { P93_INSTALLER_UI_STUB_BAD_PROGRESS: mode } });
    try {
      const { events } = await streamEvents(app, { answers: {}, steps: ['resource-group'] });
      assert.ok(events.some((event) => event.type === 'error' && /progress event/.test(event.message)));
      const summary = events.find((event) => event.type === 'summary');
      assert.equal(summary.failedStepId, '');
      assert.equal(summary.resumeCommand, '');
    } finally {
      await app.close();
    }
  }
});


test('full run requires browser confirmation before invoking the installer', async () => {
  const app = await start();
  const { chromium } = await import('playwright');
  const browser = await chromium.launch({ headless: true });
  try {
    const page = await browser.newPage();
    await page.context().addCookies([{ name: 'installer_token', value: app.token, domain: '127.0.0.1', path: '/', httpOnly: true, sameSite: 'Strict' }]);
    await page.goto(`${app.base}/`);
    await page.waitForSelector('[name="ResourceGroup"]');
    await page.locator('[name="ResourceGroup"]').fill('rg-p93');
    await page.evaluate(() => { globalThis.confirm = () => false; });
    await page.getByRole('button', { name: 'Full run' }).click();
    await new Promise((resolve) => setTimeout(resolve, 250));
    assert.equal(existsSync(app.log), false);
  } finally {
    await browser.close();
    await app.close();
  }
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
