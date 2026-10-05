import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { createInstallerUiServer } from '../tools/installer-ui/server.mjs';

const stubInstaller = fileURLToPath(new URL('./installer-ui-stub.mjs', import.meta.url));

async function start(extra = {}) {
  const scratch = join(tmpdir(), `p93-g7b-${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`);
  await rm(scratch, { recursive: true, force: true });
  await mkdir(scratch, { recursive: true });
  const server = await createInstallerUiServer({
    token: 'g7b-token-with-at-least-32-bytes-0000',
    stubInstaller,
    idleMs: 60_000,
    env: { P93_INSTALLER_UI_STUB_LOG: join(scratch, 'stub.ndjson'), ...(extra.env || {}) },
    readIdentity: extra.readIdentity ?? (async () => ({ signedIn: true, user: 'one@example.test', tenantId: 'tenant-1', subscriptionId: '00000000-0000-4000-8000-000000000093' })),
  });
  const address = await server.listenAsync('127.0.0.1');
  return {
    base: `http://127.0.0.1:${address.port}`,
    token: server.token,
    async close() {
      await server.cleanup();
      server.close();
      await once(server, 'close').catch(() => {});
      await rm(scratch, { recursive: true, force: true });
    },
  };
}

async function openPage(app) {
  const { chromium } = await import('playwright');
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();
  const pageErrors = [];
  page.on('pageerror', (error) => pageErrors.push(error.message));
  await page.addInitScript(() => {
    window.__p93Unhandled = [];
    window.addEventListener('unhandledrejection', (event) => {
      window.__p93Unhandled.push(String(event.reason?.message || event.reason));
    });
  });
  await page.goto(`${app.base}/?token=${encodeURIComponent(app.token)}`);
  await page.waitForSelector('[name="SubscriptionId"]');
  return { browser, page, pageErrors };
}

async function assertClean(page, pageErrors) {
  assert.deepEqual(pageErrors, []);
  assert.deepEqual(await page.evaluate(() => window.__p93Unhandled), []);
}

async function passPreflight(page, scope = ['resource-group']) {
  await page.locator('[name="SubscriptionId"]').fill('00000000-0000-4000-8000-000000000093');
  await page.getByRole('button', { name: 'List steps' }).click();
  for (const step of scope) await page.locator(`#step-list input[value="${step}"]`).check();
  await page.getByRole('button', { name: 'Run preflight' }).click();
  await page.locator('#preflight-output').getByText(/answers\.schema/).waitFor();
  await page.locator('#step-list input[value="resource-group"]').check();
}

test('P1 exit-zero run keeps the finished action text', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  try {
    await page.locator('[name="SubscriptionId"]').fill('00000000-0000-4000-8000-000000000093');
    await page.getByRole('button', { name: 'List steps' }).click();
    await page.getByRole('button', { name: 'Run preflight' }).click();
    await page.locator('#preflight-output').getByText(/answers\.schema/).waitFor();
    await page.route('**/api/run/stream', (route) => route.fulfill({ status: 200, contentType: 'application/x-ndjson', body: '{"seq":1,"type":"summary","exitCode":0,"failedStepId":"","resumeCommand":"","state":"exited","message":""}\n' }));
    await page.evaluate(() => { globalThis.confirm = () => true; });
    await page.locator('#full-run').evaluate((button) => button.disabled = false);
    await page.getByRole('button', { name: 'Full run' }).click();
    await page.locator('#full-run-status').getByText('Full run finished.').waitFor();
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});

test('P1 non-zero run reports the exit code, failed step and resume command as an alert', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  try {
    await passPreflight(page);
    await page.route('**/api/run/stream', (route) => route.fulfill({ status: 200, contentType: 'application/x-ndjson', body: '{"seq":1,"type":"summary","exitCode":5,"failedStepId":"resource-group","resumeCommand":"./Install-ClaudeGateway.ps1 -Steps resource-group","state":"exited","message":""}\n' }));
    await page.getByRole('button', { name: 'Run selected steps' }).click();
    const alert = page.locator('#run-error[role="alert"]');
    await alert.getByText(/exit code 5/).waitFor();
    assert.match(await alert.textContent(), /resource-group/);
    assert.match(await alert.textContent(), /Install-ClaudeGateway\.ps1/);
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});

test('P1 stopped run reports stopped status rather than an error', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  try {
    await passPreflight(page);
    await page.route('**/api/run/stream', (route) => route.fulfill({ status: 200, contentType: 'application/x-ndjson', body: '{"seq":1,"type":"summary","exitCode":null,"failedStepId":"resource-group","resumeCommand":"","state":"stopped","message":""}\n' }));
    await page.getByRole('button', { name: 'Run selected steps' }).click();
    await page.locator('#run-status').getByText(/Run stopped at resource-group/).waitFor();
    assert.equal(await page.locator('#run-error').textContent(), '');
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});

test('P1 cancelled full run and stop explain that nothing was started or stopped', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  try {
    await passPreflight(page);
    await page.evaluate(() => { globalThis.confirm = () => false; });
    await page.locator('#full-run').evaluate((button) => button.disabled = false);
    await page.getByRole('button', { name: 'Full run' }).click();
    await page.locator('#full-run-status').getByText(/No full run was started/).waitFor();
    await page.locator('#stop-run').evaluate((button) => button.disabled = false);
    await page.getByRole('button', { name: 'Stop run' }).click({ force: true });
    await page.locator('#stop-run-status').getByText(/nothing was stopped/).waitFor();
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});

test('P2 azure-busy response names the operation that holds Azure CLI', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  try {
    await page.route('**/api/identity', (route) => route.fulfill({ status: 409, contentType: 'application/json', body: JSON.stringify({ error: 'Azure CLI work is already active.', reason: 'azure-busy', operation: 'run' }) }));
    await page.getByRole('button', { name: 'Refresh account' }).click();
    await page.locator('#refresh-identity-error[role="alert"]').getByText(/installer run is already using Azure CLI/i).waitFor();
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});

test('P3 PFX answers disable page runs and render a terminal command without -Yes', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  try {
    await page.locator('[name="SubscriptionId"]').fill('00000000-0000-4000-8000-000000000093');
    await page.locator('[name="AddressMode"]').selectOption('custom');
    await page.locator('[name="AddressCertificateSource"]').selectOption('Pfx');
    await page.locator('[name="AddressHostname"]').fill('claude.example.test');
    await page.locator('[name="AddressPfxPath"]').fill('cert.pfx');
    await page.getByRole('button', { name: 'List steps' }).click();
    await page.locator('#step-list input[value="resource-group"]').check();
    await page.route('**/api/preflight', (route) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ preflight: { schemaVersion: 1, installer: 'pwsh', answersSchemaVersion: 1, result: 'PASS', checks: [{ id: 'answers.schema', result: 'PASS', reason: null, message: 'ok', remedy: '', problems: [] }] }, fingerprint: 'a'.repeat(64), identity: { signedIn: true, user: 'one@example.test', tenantId: 'tenant-1', subscriptionId: '00000000-0000-4000-8000-000000000093' }, scope: ['resource-group'] }) }));
    await page.getByRole('button', { name: 'Run preflight' }).click();
    await page.locator('#preflight-output').getByText(/answers\.schema/).waitFor();
    assert.equal(await page.getByRole('button', { name: 'Run selected steps' }).isDisabled(), true);
    assert.doesNotMatch(await page.locator('#commands').textContent(), / -Yes /);
    await page.locator('#commands').getByText(/asks for the PFX password/).waitFor();
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});

test('P4 invalid business-unit JSON blocks download and keeps the draft text', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  try {
    await page.locator('summary', { hasText: 'JSON view' }).click();
    await page.locator('#business-units').fill('{}');
    assert.equal(await page.getByRole('button', { name: 'Download answers.json' }).isDisabled(), true);
    assert.equal(await page.locator('#business-units').inputValue(), '{}');
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});

test('P4 decimal monthly budget is accepted while text and out-of-range values are refused', async () => {
  const model = globalThis.ClaudeInstallerUiModel || (await import('node:vm')).runInNewContext;
  const { readFile } = await import('node:fs/promises');
  const source = await readFile(new URL('../tools/installer-ui/ui-model.js', import.meta.url), 'utf8');
  const context = { globalThis: {} };
  (await import('node:vm')).runInNewContext(source, context);
  const validate = context.globalThis.ClaudeInstallerUiModel.validateBusinessUnits;
  assert.equal(validate([{ id: 'finance', group: 'claude-bu-finance', monthlyUsdBudget: 12.5, mode: 'Strict' }]).length, 0);
  assert.match(validate([{ id: 'finance', group: 'claude-bu-finance', monthlyUsdBudget: -1, mode: 'Strict' }]).join('\n'), /monthly budget/);
  assert.match(validate([{ id: 'finance', group: 'claude-bu-finance', monthlyUsdBudget: 100000000.01, mode: 'Strict' }]).join('\n'), /monthly budget/);
  assert.match(validate([{ id: 'finance', group: 'claude-bu-finance', monthlyUsdBudget: '12', mode: 'Strict' }]).join('\n'), /monthly budget/);
});

test('P6 one-step preflight admits selected scope but blocks full run', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  try {
    await passPreflight(page, ['resource-group']);
    assert.equal(await page.getByRole('button', { name: 'Run selected steps' }).isEnabled(), true);
    assert.equal(await page.getByRole('button', { name: 'Full run' }).isDisabled(), true);
    await page.getByText(/Full run needs a preflight with no step selected/).waitFor();
    await page.locator('#step-list input[value="gateway-deployment"]').check();
    assert.equal(await page.getByRole('button', { name: 'Run selected steps' }).isDisabled(), true);
    await page.locator('#step-list input[value="gateway-deployment"]').uncheck();
    assert.equal(await page.getByRole('button', { name: 'Run selected steps' }).isEnabled(), true);
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});

test('P7 omitted custom certificate source behaves as KeyVault without changing submitted answers', async () => {
  const source = await readFile(new URL('../tools/installer-ui/ui-model.js', import.meta.url), 'utf8');
  const context = { globalThis: {} };
  (await import('node:vm')).runInNewContext(source, context);
  const model = context.globalThis.ClaudeInstallerUiModel;
  const defaults = Object.fromEntries(model.withEffectiveAddressDefaults({ AddressMode: 'custom' }));
  assert.equal(defaults.AddressCertificateSource, 'KeyVault');
  const schema = { properties: { AddressMode: { 'x-appliedBy': ['Install-ClaudeGateway.ps1'], type: 'string' }, AddressCertificateSource: { 'x-appliedBy': ['Install-ClaudeGateway.ps1'], type: 'string' }, AddressKeyVaultCertificateId: { 'x-appliedBy': ['Install-ClaudeGateway.ps1'], type: 'string', requires: [{ answer: 'AddressCertificateSource', equals: 'KeyVault' }] } } };
  const answers = model.collectAnswersFromEntries(schema, new Map([['AddressMode', 'custom']]), '');
  assert.equal(answers.AddressCertificateSource, undefined);
});

test('G7B-1 validateAnswers stays in parity while effective custom-address defaults are page-only', async () => {
  const source = await readFile(new URL('../tools/installer-ui/ui-model.js', import.meta.url), 'utf8');
  const context = { globalThis: {} };
  (await import('node:vm')).runInNewContext(source, context);
  const model = context.globalThis.ClaudeInstallerUiModel;
  const schema = JSON.parse(await readFile(new URL('../schemas/claude-gateway.answers.schema.json', import.meta.url), 'utf8'));
  const answers = {
    schemaVersion: 1,
    SubscriptionId: '00000000-0000-4000-8000-000000000093',
    AddressMode: 'custom',
    AddressHostname: 'claude.example.test',
  };
  const scratch = join(tmpdir(), `p93-g7b-parity-${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`);
  await mkdir(scratch, { recursive: true });
  const answersPath = join(scratch, 'answers.json');
  const runner = join(scratch, 'validate.ps1');
  await writeFile(answersPath, JSON.stringify(answers, null, 2), 'utf8');
  await writeFile(runner, `
$ErrorActionPreference = 'Stop'
. '${fileURLToPath(new URL('../scripts/ClaudeInstallerAnswers.ps1', import.meta.url)).replace(/'/g, "''")}'
$problems = @(Test-ClaudeInstallerAnswersFile -Path '${answersPath.replace(/'/g, "''")}' -Consumer 'Install-ClaudeGateway.ps1')
$problems | ConvertTo-Json -Depth 10
`, 'utf8');
  try {
    const ps = spawn('pwsh', ['-NoProfile', '-File', runner], { shell: false });
    let stdout = '';
    let stderr = '';
    ps.stdout.on('data', (chunk) => { stdout += chunk; });
    ps.stderr.on('data', (chunk) => { stderr += chunk; });
    const code = await new Promise((resolve) => ps.on('close', resolve));
    assert.equal(code, 0, stderr);
    const powerShellProblems = stdout.trim() ? JSON.parse(stdout) : [];
    const jsProblems = model.validateAnswers(schema, answers, 'Install-ClaudeGateway.ps1');
    assert.equal(JSON.stringify(jsProblems.map((p) => p.path).sort()), JSON.stringify(powerShellProblems.map((p) => p.path).sort()));
    const effective = model.validateEffectiveAddressDefaults(schema, answers);
    assert.ok(effective.some((p) => p.path === 'AddressKeyVaultCertificateId' && /uses Key Vault/.test(p.message)));
  } finally {
    await rm(scratch, { recursive: true, force: true });
  }
});

test('G7B-2 choosing accounts keeps the account list and replaces deployment choices', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  try {
    await page.locator('[name="SubscriptionId"]').fill('00000000-0000-4000-8000-000000000093');
    await page.route('**/api/prefill', async (route) => {
      const body = route.request().postDataJSON();
      if (body.kind === 'deployments') return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ deployments: [{ name: body.foundryAccount === 'two' ? 'account-two' : 'account-one' }] }) });
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ foundryAccounts: [{ name: 'one', resourceGroup: 'rg-one' }, { name: 'two', resourceGroup: 'rg-two' }] }) });
    });
    await page.getByRole('button', { name: 'Read Foundry accounts' }).click();
    await page.locator('[data-prefill-select="FoundryAccount"]').selectOption('one');
    await page.locator('[data-model-select="StandardModels"] option', { hasText: 'account-one' }).waitFor();
    assert.deepEqual(await page.locator('[data-prefill-select="FoundryAccount"] option').evaluateAll((options) => options.map((option) => option.textContent)), ['choose...', 'one / rg-one', 'two / rg-two']);
    assert.deepEqual(await page.locator('[data-model-select="StandardModels"] option').evaluateAll((options) => options.map((option) => option.textContent)), ['account-one']);
    await page.locator('[name="StandardModels"]').fill('account-one, manual-one');
    await page.locator('[data-model-select="StandardModels"]').selectOption(['account-one']);
    assert.equal(await page.locator('[name="StandardModels"]').inputValue(), 'account-one, manual-one');
    await page.locator('[data-prefill-select="FoundryAccount"]').selectOption('two');
    await page.locator('[data-model-select="StandardModels"] option', { hasText: 'account-two' }).waitFor();
    assert.deepEqual(await page.locator('[data-model-select="StandardModels"] option').evaluateAll((options) => options.map((option) => option.textContent)), ['account-two']);
    assert.equal(await page.locator('[name="StandardModels"]').inputValue(), 'account-one, manual-one');
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});

test('P9 nested problem paths focus the exact nested and business-unit controls', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  try {
    await page.locator('[name="SubscriptionId"]').fill('00000000-0000-4000-8000-000000000093');
    await page.locator('#pending-deployment-enabled').check();
    await page.route('**/api/preflight', (route) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ preflight: { schemaVersion: 1, installer: 'pwsh', answersSchemaVersion: 1, result: 'FAIL', checks: [{ id: 'answers.schema', result: 'FAIL', reason: null, message: 'capacity bad', remedy: 'fix it', problems: [{ path: 'PendingClaudeDeployment.capacity', message: 'capacity bad', remedy: 'fix it' }] }] }, exitCode: 1 }) }));
    await page.getByRole('button', { name: 'Run preflight' }).click();
    await page.getByRole('button', { name: 'Review PendingClaudeDeployment.capacity' }).click();
    assert.equal(await page.evaluate(() => document.activeElement?.name), 'PendingClaudeDeployment.capacity');
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});
