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
    await page.route('**/api/identity', (route) => route.fulfill({ status: 500, contentType: 'application/json', body: JSON.stringify({ error: 'identity refresh failed after run' }) }));
    await page.evaluate(() => { globalThis.confirm = () => true; });
    await page.getByRole('button', { name: 'Full run' }).click();
    await page.locator('#full-run-status').getByText('Full run finished.').waitFor();
    await page.locator('#identity').getByText(/identity refresh failed after run/).waitFor();
    assert.equal(await page.locator('#full-run-error').textContent(), '');
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
    await page.locator('[name="SubscriptionId"]').fill('00000000-0000-4000-8000-000000000093');
    await page.getByRole('button', { name: 'List steps' }).click();
    await page.getByRole('button', { name: 'Run preflight' }).click();
    await page.locator('#preflight-output').getByText(/answers\.schema/).waitFor();
    await page.route('**/api/run/stream', (route) => route.fulfill({ status: 200, contentType: 'application/x-ndjson', body: '{"seq":1,"type":"summary","exitCode":5,"failedStepId":"resource-group","resumeCommand":"./Install-ClaudeGateway.ps1 -Steps resource-group","state":"exited","message":""}\n' }));
    await page.evaluate(() => { globalThis.confirm = () => true; });
    await page.getByRole('button', { name: 'Full run' }).click();
    const alert = page.locator('#full-run-error[role="alert"]');
    await alert.getByText(/exit code 5/).waitFor();
    assert.match(await alert.textContent(), /resource-group/);
    assert.match(await alert.textContent(), /Install-ClaudeGateway\.ps1/);
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});

test('R2-3 failed run clears the busy status text', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  try {
    await passPreflight(page);
    await page.route('**/api/run/stream', (route) => route.fulfill({ status: 200, contentType: 'application/x-ndjson', body: '{"seq":1,"type":"summary","exitCode":9,"failedStepId":"resource-group","resumeCommand":"","state":"exited","message":""}\n' }));
    await page.getByRole('button', { name: 'Run selected steps' }).click();
    await page.locator('#run-error[role="alert"]').getByText(/exit code 9/).waitFor();
    assert.doesNotMatch(await page.locator('#run-status').textContent(), /Running selected steps/);
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});

test('R2-4 run failure alert gives run-output recovery instead of generic form advice', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  try {
    await passPreflight(page);
    await page.route('**/api/run/stream', (route) => route.fulfill({ status: 200, contentType: 'application/x-ndjson', body: '{"seq":1,"type":"summary","exitCode":9,"failedStepId":"resource-group","resumeCommand":"./Install-ClaudeGateway.ps1 -Steps resource-group","state":"exited","message":""}\n' }));
    await page.getByRole('button', { name: 'Run selected steps' }).click();
    await page.locator('#run-error[role="alert"]').getByText(/exit code 9/).waitFor();
    const text = await page.locator('#run-error[role="alert"]').textContent();
    assert.match(text, /Fix the cause shown in the run output, then use Re-run failed step or the resume command/);
    assert.doesNotMatch(text, /Check the values above and try again/);
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
    await page.locator('[name="SubscriptionId"]').fill('00000000-0000-4000-8000-000000000093');
    await page.getByRole('button', { name: 'List steps' }).click();
    await page.route('**/api/preflight', (route) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ preflight: { schemaVersion: 1, installer: 'pwsh', answersSchemaVersion: 1, result: 'PASS', checks: [{ id: 'answers.schema', result: 'PASS', reason: null, message: 'ok', remedy: '', problems: [] }] }, fingerprint: 'a'.repeat(64), identity: { signedIn: true, user: 'one@example.test', tenantId: 'tenant-1', subscriptionId: '00000000-0000-4000-8000-000000000093' }, scope: 'full' }) }));
    await page.getByRole('button', { name: 'Run preflight' }).click();
    await page.locator('#preflight-output').getByText(/answers\.schema/).waitFor();
    await page.route('**/api/run/stream', (route) => route.fulfill({ status: 200, contentType: 'application/x-ndjson', body: '{"seq":1,"type":"summary","exitCode":null,"failedStepId":"resource-group","resumeCommand":"","state":"stopped","message":""}\n' }));
    await page.evaluate(() => { globalThis.confirm = () => true; });
    await page.getByRole('button', { name: 'Full run' }).click();
    await page.locator('#full-run-status').getByText(/Run stopped at resource-group/).waitFor();
    assert.equal(await page.locator('#full-run-error').textContent(), '');
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});

test('R2-1 stopped run names the step from progress and summary message', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  try {
    await passPreflight(page);
    await page.route('**/api/run/stream', (route) => route.fulfill({ status: 200, contentType: 'application/x-ndjson', body: '{"seq":1,"type":"progress","stepId":"resource-group","event":"started","message":"started"}\n{"seq":2,"type":"summary","exitCode":null,"failedStepId":"","resumeCommand":"","state":"stopped","message":"Stopped installer run at resource-group. The install checkpoint resumes when the same steps run again."}\n' }));
    await page.getByRole('button', { name: 'Run selected steps' }).click();
    await page.locator('#run-status').getByText(/Run stopped at resource-group/).waitFor();
    assert.doesNotMatch(await page.locator('#run-status').textContent(), /current step/);
    assert.equal(await page.locator('#run-error').textContent(), '');
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});

test('P1 cancelled full run and stop explain that nothing was started or stopped', async () => {
  const app = await start({ env: { P93_INSTALLER_UI_STUB_DELAY_MS: '1200' } });
  const { browser, page, pageErrors } = await openPage(app);
  try {
    await page.locator('[name="SubscriptionId"]').fill('00000000-0000-4000-8000-000000000093');
    await page.getByRole('button', { name: 'List steps' }).click();
    await page.getByRole('button', { name: 'Run preflight' }).click();
    await page.locator('#preflight-output').getByText(/answers\.schema/).waitFor();
    await page.evaluate(() => { globalThis.confirm = () => false; });
    await page.getByRole('button', { name: 'Full run' }).click();
    await page.locator('#full-run-status').getByText(/No full run was started/).waitFor();
    await page.route('**/api/run/status', (route) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ id: 'reattach-run', state: 'running', currentStepId: 'resource-group', steps: ['resource-group'] }) }));
    await page.route('**/api/run/attach?after=0', (route) => route.fulfill({ status: 200, contentType: 'application/x-ndjson', body: '{"seq":1,"type":"progress","stepId":"resource-group","event":"started","message":"running"}\n' }));
    await page.reload();
    await page.waitForSelector('[name="SubscriptionId"]');
    await page.locator('#run-output').getByText(/running/).waitFor();
    await page.evaluate(() => { globalThis.confirm = () => false; });
    await page.getByRole('button', { name: 'Stop run' }).click();
    await page.locator('#stop-run-status').getByText(/No stop was requested/).waitFor();
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});

test('G7B-4 load-time reattach errors are reported in the run alert region', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  try {
    await page.route('**/api/run/status', (route) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ id: 'run-1', state: 'running', currentStepId: 'resource-group', steps: ['resource-group'] }) }));
    await page.route('**/api/run/attach?after=0', (route) => route.fulfill({ status: 500, contentType: 'application/json', body: JSON.stringify({ error: 'attach failed for test' }) }));
    await page.reload();
    await page.waitForSelector('[name="SubscriptionId"]');
    await page.locator('#run-error[role="alert"]').getByText(/attach failed for test/).waitFor();
    assert.equal(await page.locator('#run-status[role="alert"]').count(), 0);
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});

test('R2-2 account is reread after a failed reattached run summary', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  try {
    let identityCalls = 0;
    let releaseIdentity;
    const identityRelease = new Promise((resolve) => { releaseIdentity = resolve; });
    await page.route('**/api/identity', async (route) => {
      identityCalls += 1;
      if (identityCalls === 1) return route.fulfill({ status: 409, contentType: 'application/json', body: JSON.stringify({ error: 'Azure CLI work is already active.', reason: 'azure-busy', operation: 'run' }) });
      await identityRelease;
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ signedIn: true, user: 'after@example.test', tenantId: 'tenant-1', subscriptionName: 'Sub One', subscriptionId: '00000000-0000-4000-8000-000000000093' }) });
    });
    await page.route('**/api/run/status', (route) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ id: 'reattach-run', state: 'running', currentStepId: 'resource-group', steps: ['resource-group'] }) }));
    await page.route('**/api/run/attach?after=0', (route) => route.fulfill({ status: 200, contentType: 'application/x-ndjson', body: '{"seq":1,"type":"summary","exitCode":7,"failedStepId":"resource-group","resumeCommand":"./Install-ClaudeGateway.ps1 -Steps resource-group","state":"exited","message":""}\n' }));
    await page.reload();
    await page.waitForSelector('[name="SubscriptionId"]');
    await page.locator('#identity').getByText(/installer run is using Azure CLI/i).waitFor();
    await page.locator('#run-error[role="alert"]').getByText(/exit code 7/).waitFor();
    releaseIdentity();
    await page.locator('#identity').getByText(/after@example\.test/).waitFor();
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

test('G7B-5 pending Azure work and active runs disable every Azure-starting page control', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  try {
    let releasePrefill;
    const prefillPending = new Promise((resolve) => { releasePrefill = resolve; });
    await page.route('**/api/prefill', async (route) => {
      await prefillPending;
      await route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ subscriptions: [{ id: '00000000-0000-4000-8000-000000000093', name: 'Sub One' }] }) });
    });

    await page.getByRole('button', { name: 'Read subscriptions' }).click();
    await page.locator('[data-prefill-kind="subscriptions"]').getByText(/Reading Azure/).waitFor();
    assert.equal(await page.getByRole('button', { name: 'Run preflight' }).isDisabled(), true);
    assert.equal(await page.getByRole('button', { name: 'Refresh account' }).isDisabled(), true);
    assert.equal(await page.getByRole('button', { name: 'Read Foundry accounts' }).isDisabled(), true);
    releasePrefill();
    await page.locator('[data-prefill-kind="subscriptions"]').getByText(/Read subscriptions/).waitFor();

    await page.unroute('**/api/prefill');
    await passPreflight(page);
    await page.route('**/api/run/stream', async (route) => {
      await new Promise((resolve) => setTimeout(resolve, 800));
      await route.fulfill({ status: 200, contentType: 'application/x-ndjson', body: '{"seq":1,"type":"summary","exitCode":0,"failedStepId":"","resumeCommand":"","state":"exited","message":""}\n' });
    });
    await page.getByRole('button', { name: 'Run selected steps' }).click();
    await page.locator('#run-status').getByText(/Running selected steps/).waitFor();
    assert.equal(await page.getByRole('button', { name: 'Refresh account' }).isDisabled(), true);
    assert.equal(await page.getByRole('button', { name: 'Read subscriptions' }).isDisabled(), true);
    await page.locator('#run-status').getByText(/Run finished/).waitFor();
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});

test('G7B-5 reattached runs disable Azure controls until the summary refreshes account state', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  try {
    let releaseAttach;
    const attachPending = new Promise((resolve) => { releaseAttach = resolve; });
    await page.route('**/api/run/status', (route) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ id: 'run-reattach', state: 'running', currentStepId: 'resource-group', steps: ['resource-group'] }) }));
    await page.route('**/api/run/attach?after=0', async (route) => {
      await route.fulfill({ status: 200, contentType: 'application/x-ndjson', body: '{"seq":1,"type":"progress","stepId":"resource-group","event":"started","message":"reattached"}\n' });
    });
    await page.route('**/api/run/attach?after=1', async (route) => {
      await attachPending;
      await route.fulfill({ status: 200, contentType: 'application/x-ndjson', body: '{"seq":2,"type":"summary","exitCode":0,"failedStepId":"","resumeCommand":"","state":"exited","message":""}\n' });
    });
    await page.reload();
    await page.waitForSelector('[name="SubscriptionId"]');
    await page.locator('#run-output').getByText(/reattached/).waitFor();
    assert.equal(await page.getByRole('button', { name: 'Refresh account' }).isDisabled(), true);
    assert.equal(await page.getByRole('button', { name: 'Read subscriptions' }).isDisabled(), true);
    releaseAttach();
    await page.getByRole('button', { name: 'Refresh account' }).waitFor({ state: 'visible' });
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});

test('R2-6 prefill selects are disabled during a deployments read', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  try {
    let releaseDeployments;
    const deploymentsPending = new Promise((resolve) => { releaseDeployments = resolve; });
    await page.route('**/api/prefill', async (route) => {
      const body = route.request().postDataJSON();
      if (body.kind === 'foundryAccounts') return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ foundryAccounts: [{ name: 'one', resourceGroup: 'rg-one' }, { name: 'two', resourceGroup: 'rg-two' }] }) });
      if (body.kind === 'deployments') {
        await deploymentsPending;
        return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ deployments: [{ name: 'account-one' }] }) });
      }
      return route.fulfill({ status: 200, contentType: 'application/json', body: '{}' });
    });
    await page.locator('[name="SubscriptionId"]').fill('00000000-0000-4000-8000-000000000093');
    await page.getByRole('button', { name: 'Read Foundry accounts' }).click();
    await page.locator('[data-prefill-select="FoundryAccount"]').selectOption('one');
    await page.locator('[data-prefill-kind="foundryAccounts"]').getByText(/Reading Azure/).waitFor();
    assert.equal(await page.locator('[data-prefill-select="FoundryAccount"]').isDisabled(), true);
    releaseDeployments();
    await page.locator('[data-model-select="StandardModels"] option', { hasText: 'account-one' }).waitFor();
    assert.equal(await page.locator('[data-prefill-select="FoundryAccount"]').isEnabled(), true);
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

test('G7B-6 PFX command metadata distinguishes terminal PFX from KeyVault and static mode', async () => {
  const source = await readFile(new URL('../tools/installer-ui/ui-model.js', import.meta.url), 'utf8');
  const context = { globalThis: {} };
  (await import('node:vm')).runInNewContext(source, context);
  const model = context.globalThis.ClaudeInstallerUiModel;
  const schema = JSON.parse(await readFile(new URL('../schemas/claude-gateway.answers.schema.json', import.meta.url), 'utf8'));
  const pfx = model.buildPortableCommands(schema, './answers.json', { answers: { AddressMode: 'custom', AddressCertificateSource: 'Pfx' }, presentAnswers: ['AddressMode', 'AddressCertificateSource'] });
  assert.equal(pfx.terminalPfx, true);
  assert.match(pfx.powershellRun, /-AnswersPath/);
  assert.doesNotMatch(pfx.powershellRun, / -Yes /);
  const keyVault = model.buildPortableCommands(schema, './answers.json', { answers: { AddressMode: 'custom', AddressCertificateSource: 'KeyVault' }, presentAnswers: ['AddressMode', 'AddressCertificateSource'] });
  assert.equal(keyVault.terminalPfx, false);
  assert.match(keyVault.powershellRun, / -Yes /);
});

test('G7B-6 pfx-needs-terminal server refusal is shown with its sentence', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  try {
    await passPreflight(page);
    await page.route('**/api/run/stream', (route) => route.fulfill({ status: 409, contentType: 'application/json', body: JSON.stringify({ error: 'A PFX certificate is installed from a terminal because the installer asks for the PFX password only when it runs without -Yes.', reason: 'pfx-needs-terminal' }) }));
    await page.getByRole('button', { name: 'Run selected steps' }).click();
    await page.locator('#run-error[role="alert"]').getByText(/PFX certificate is installed from a terminal/).waitFor();
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});

test('R2-5 PFX path is reported once because defaults create no PFX requirement', async () => {
  const source = await readFile(new URL('../tools/installer-ui/ui-model.js', import.meta.url), 'utf8');
  const context = { globalThis: {} };
  (await import('node:vm')).runInNewContext(source, context);
  const model = context.globalThis.ClaudeInstallerUiModel;
  const schema = JSON.parse(await readFile(new URL('../schemas/claude-gateway.answers.schema.json', import.meta.url), 'utf8'));
  const answers = { schemaVersion: 1, AddressMode: 'custom', AddressCertificateSource: 'Pfx' };
  const problems = [...model.validateAnswers(schema, answers, 'Install-ClaudeGateway.ps1'), ...model.validateEffectiveAddressDefaults(schema, answers)];
  assert.equal(problems.filter((p) => p.path === 'AddressPfxPath').length, 1);
});

test('G7B-7 refreshed identity changes make the preflight stale and same identity keeps it current', async () => {
  let identity = { signedIn: true, user: 'one@example.test', tenantId: 'tenant-1', subscriptionId: '00000000-0000-4000-8000-000000000093' };
  const app = await start({ readIdentity: async () => identity });
  const { browser, page, pageErrors } = await openPage(app);
  try {
    await passPreflight(page);
    assert.equal(await page.getByRole('button', { name: 'Run selected steps' }).isEnabled(), true);
    await page.getByRole('button', { name: 'Refresh account' }).click();
    await page.locator('#refresh-identity-status').getByText(/Account refreshed/).waitFor();
    await page.getByText(/Passing preflight/).waitFor();
    assert.equal(await page.getByRole('button', { name: 'Run selected steps' }).isEnabled(), true);
    identity = { ...identity, subscriptionId: '00000000-0000-4000-8000-000000000094' };
    await page.getByRole('button', { name: 'Refresh account' }).click();
    await page.locator('#preflight-state').getByText(/subscription/).waitFor();
    assert.equal(await page.getByRole('button', { name: 'Run selected steps' }).isDisabled(), true);
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});

test('G7B-7 identity-changed run refusal makes preflight stale with the server sentence', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  try {
    await passPreflight(page);
    await page.route('**/api/run/stream', (route) => route.fulfill({ status: 409, contentType: 'application/json', body: JSON.stringify({ error: 'The Azure identity subscription changed since preflight. Run preflight again.', reason: 'identity-changed' }) }));
    await page.getByRole('button', { name: 'Run selected steps' }).click();
    await page.locator('#run-error[role="alert"]').getByText(/identity subscription changed/).waitFor();
    await page.getByText(/Preflight is stale/).waitFor();
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

test('G7B-3 invalid business-unit JSON blocks tree actions without page errors and recovers to submitted JSON', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  try {
    await page.locator('[name="SubscriptionId"]').fill('00000000-0000-4000-8000-000000000093');
    await page.locator('summary', { hasText: 'JSON view' }).click();
    await page.locator('#business-units').fill('{');
    await page.getByRole('button', { name: 'Add unit' }).click();
    await page.locator('#business-unit-problems').getByText(/JSON parse error/).waitFor();
    assert.equal(await page.locator('#business-units').inputValue(), '{');
    assert.equal(await page.getByRole('button', { name: 'Run preflight' }).isDisabled(), true);
    assert.match(await page.locator('#commands').textContent(), /Commands are unavailable/);
    assert.deepEqual(pageErrors, []);
    const units = [{ id: 'finance', group: 'claude-bu-finance', monthlyUsdBudget: 12.5, mode: 'Strict' }];
    await page.locator('#business-units').fill(JSON.stringify(units, null, 2));
    let submitted;
    await page.route('**/api/preflight', (route) => {
      submitted = route.request().postDataJSON();
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ preflight: { schemaVersion: 1, installer: 'pwsh', answersSchemaVersion: 1, result: 'PASS', checks: [{ id: 'answers.schema', result: 'PASS', reason: null, message: 'ok', remedy: '', problems: [] }] }, fingerprint: 'a'.repeat(64), identity: { signedIn: true, user: 'one@example.test', tenantId: 'tenant-1', subscriptionId: '00000000-0000-4000-8000-000000000093' }, scope: 'full' }) });
    });
    await page.getByRole('button', { name: 'Run preflight' }).click();
    await page.locator('#preflight-output').getByText(/answers\.schema/).waitFor();
    assert.deepEqual(submitted.answers.BusinessUnits, units);
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
  const scratch = join(tmpdir(), `p93-g7b-decimal-${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`);
  await mkdir(scratch, { recursive: true });
  try {
    const answersPath = join(scratch, 'answers.json');
    const runner = join(scratch, 'validate.ps1');
    await writeFile(answersPath, JSON.stringify({ schemaVersion: 1, BusinessUnits: [{ id: 'finance', group: 'claude-bu-finance', monthlyUsdBudget: 12.5, mode: 'Strict' }] }), 'utf8');
    await writeFile(runner, `
$ErrorActionPreference = 'Stop'
. '${fileURLToPath(new URL('../scripts/ClaudeInstallerAnswers.ps1', import.meta.url)).replace(/'/g, "''")}'
@(Test-ClaudeInstallerAnswersFile -Path '${answersPath.replace(/'/g, "''")}' -Consumer 'Install-ClaudeGateway.ps1') | ConvertTo-Json -Depth 10
`, 'utf8');
    const ps = spawn('pwsh', ['-NoProfile', '-File', runner], { shell: false });
    let stdout = '';
    let stderr = '';
    ps.stdout.on('data', (chunk) => { stdout += chunk; });
    ps.stderr.on('data', (chunk) => { stderr += chunk; });
    const code = await new Promise((resolve) => ps.on('close', resolve));
    assert.equal(code, 0, stderr);
    assert.equal(stdout.trim(), '');
  } finally {
    await rm(scratch, { recursive: true, force: true });
  }
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

test('G7B-8 full-scope preflight enables Full run and out-of-scope failed steps cannot rerun', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  try {
    await page.locator('[name="SubscriptionId"]').fill('00000000-0000-4000-8000-000000000093');
    await page.getByRole('button', { name: 'List steps' }).click();
    await page.getByRole('button', { name: 'Run preflight' }).click();
    await page.locator('#preflight-output').getByText(/answers\.schema/).waitFor();
    assert.equal(await page.getByRole('button', { name: 'Full run' }).isEnabled(), true);
    await page.locator('#step-list input[value="resource-group"]').check();
    await page.getByRole('button', { name: 'Run preflight' }).click();
    await page.locator('#preflight-state').getByText(/Full run needs a preflight with no step selected/).waitFor();
    await page.route('**/api/run/stream', (route) => route.fulfill({ status: 200, contentType: 'application/x-ndjson', body: '{"seq":1,"type":"summary","exitCode":1,"failedStepId":"gateway-deployment","resumeCommand":"./Install-ClaudeGateway.ps1 -Steps gateway-deployment","state":"exited","message":""}\n' }));
    await page.getByRole('button', { name: 'Run selected steps' }).click();
    await page.locator('#run-error[role="alert"]').getByText(/gateway-deployment/).waitFor();
    assert.equal(await page.getByRole('button', { name: 'Re-run failed step' }).isDisabled(), true);
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
    assert.equal(await page.locator('[name="PendingClaudeDeployment.capacity"]').getAttribute('aria-invalid'), 'true');
    assert.notEqual(await page.locator('[name="PendingClaudeDeployment.name"]').getAttribute('aria-invalid'), 'true');
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});

test('G7B-9 business-unit indexed problem paths mark and describe the row control', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  try {
    await page.locator('[name="SubscriptionId"]').fill('00000000-0000-4000-8000-000000000093');
    await page.locator('summary', { hasText: 'JSON view' }).click();
    await page.locator('#business-units').fill(JSON.stringify([
      { id: 'finance', group: 'claude-bu-finance', monthlyUsdBudget: 10, mode: 'Strict' },
      { id: 'sales', group: 'claude-bu-sales', monthlyUsdBudget: 10, mode: 'Strict' },
    ], null, 2));
    await page.route('**/api/preflight', (route) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ preflight: { schemaVersion: 1, installer: 'pwsh', answersSchemaVersion: 1, result: 'FAIL', checks: [{ id: 'answers.schema', result: 'FAIL', reason: null, message: 'row group bad', remedy: 'fix row group', problems: [{ path: 'BusinessUnits[1].group', message: 'row group bad', remedy: 'fix row group' }] }] }, exitCode: 1 }) }));
    await page.getByRole('button', { name: 'Run preflight' }).click();
    await page.getByRole('button', { name: 'Review BusinessUnits[1].group' }).click();
    const active = await page.evaluate(() => [document.activeElement?.closest('[data-bu-index]')?.dataset.buIndex, document.activeElement?.dataset.buField]);
    assert.deepEqual(active, ['1', 'group']);
    const field = page.locator('[data-bu-index="1"] [data-bu-field="group"]');
    assert.equal(await field.getAttribute('aria-invalid'), 'true');
    const described = await field.getAttribute('aria-describedby');
    assert.match(await page.locator('#' + described.split(/\s+/)[0]).textContent(), /row group bad/);
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});
