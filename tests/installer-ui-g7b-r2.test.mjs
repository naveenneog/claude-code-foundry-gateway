import assert from 'node:assert/strict';
import { once } from 'node:events';
import { existsSync, readFileSync } from 'node:fs';
import { mkdir, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { createInstallerUiServer } from '../tools/installer-ui/server.mjs';

const stubInstaller = fileURLToPath(new URL('./installer-ui-stub.mjs', import.meta.url));

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

test('R2-7 static mode shows terminal PFX command without Yes', async () => {
  const { chromium } = await import('playwright');
  const browser = await chromium.launch({ headless: true });
  try {
    const page = await browser.newPage();
    await page.goto(new URL('../tools/installer-ui/index.html', import.meta.url).href);
    await page.waitForSelector('[name="SubscriptionId"]');
    await page.locator('[name="AddressMode"]').selectOption('custom');
    await page.locator('[name="AddressCertificateSource"]').selectOption('Pfx');
    await page.locator('[name="AddressHostname"]').fill('claude.example.test');
    await page.locator('[name="AddressPfxPath"]').fill('cert.pfx');
    const commands = await page.locator('#commands').textContent();
    assert.match(commands, /-AnswersPath/);
    assert.doesNotMatch(commands, / -Yes /);
    assert.match(commands, /PFX password/);
  } finally {
    await browser.close();
  }
});

test('lead: the account read after a run marks a passing preflight stale when the identity changed during the run', async () => {
  const original = { signedIn: true, user: 'one@example.test', tenantId: 'tenant-1', subscriptionId: '00000000-0000-4000-8000-000000000093' };
  const changed = { ...original, subscriptionId: '00000000-0000-4000-8000-000000000094' };
  const scratch = join(tmpdir(), `p93-g7b-lead-${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`);
  await mkdir(scratch, { recursive: true });
  const log = join(scratch, 'stub.ndjson');
  // Run admission reads the identity before the installer starts; once the stub has logged the run (-Yes), the account has changed.
  const runStarted = () => existsSync(log) && readFileSync(log, 'utf8').includes('"-Yes"');
  const server = await createInstallerUiServer({
    token: 'g7b-lead-token-with-at-least-32-bytes-00',
    stubInstaller,
    idleMs: 60_000,
    env: { P93_INSTALLER_UI_STUB_LOG: log },
    readIdentity: async () => (runStarted() ? changed : original),
  });
  const address = await server.listenAsync('127.0.0.1');
  const { chromium } = await import('playwright');
  const browser = await chromium.launch({ headless: true });
  try {
    const page = await browser.newPage();
    const pageErrors = [];
    page.on('pageerror', (error) => pageErrors.push(error.message));
    await page.goto(`http://127.0.0.1:${address.port}/?token=${encodeURIComponent(server.token)}`);
    await page.waitForSelector('[name="SubscriptionId"]');
    await page.locator('[name="SubscriptionId"]').fill('00000000-0000-4000-8000-000000000093');
    await page.getByRole('button', { name: 'List steps' }).click();
    await page.locator('#step-list input[value="resource-group"]').check();
    await page.getByRole('button', { name: 'Run preflight' }).click();
    await page.locator('#preflight-state').getByText(/Passing preflight [0-9a-f]{12} is current/).waitFor();
    await page.getByRole('button', { name: 'Run selected steps' }).click();
    await page.locator('#run-status').getByText('Run finished.').waitFor();
    await page.locator('#identity').getByText(/000000000094/).waitFor();
    await page.locator('#preflight-state').getByText(/Preflight is stale\. The Azure identity changed \(subscription\)/).waitFor();
    assert.equal(await page.getByRole('button', { name: 'Run selected steps' }).isDisabled(), true);
    assert.deepEqual(pageErrors, []);
  } finally {
    await browser.close();
    await server.cleanup();
    server.close();
    await once(server, 'close').catch(() => {});
    await rm(scratch, { recursive: true, force: true });
  }
});

async function startLeadPage() {
  const scratch = join(tmpdir(), `p93-g7b-lead-${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`);
  await mkdir(scratch, { recursive: true });
  const server = await createInstallerUiServer({
    token: 'g7b-lead-page-token-with-at-least-32-bytes',
    stubInstaller,
    idleMs: 60_000,
    env: { P93_INSTALLER_UI_STUB_LOG: join(scratch, 'stub.ndjson') },
    readIdentity: async () => ({ signedIn: true, user: 'one@example.test', tenantId: 'tenant-1', subscriptionId: '00000000-0000-4000-8000-000000000093' }),
  });
  const address = await server.listenAsync('127.0.0.1');
  const { chromium } = await import('playwright');
  const browser = await chromium.launch({ headless: true });
  try {
    const page = await browser.newPage();
    const pageErrors = [];
    page.on('pageerror', (error) => pageErrors.push(error.message));
    await page.goto(`http://127.0.0.1:${address.port}/?token=${encodeURIComponent(server.token)}`);
    await page.waitForSelector('[name="SubscriptionId"]');
    await page.locator('[name="SubscriptionId"]').fill('00000000-0000-4000-8000-000000000093');
    await page.getByRole('button', { name: 'List steps' }).click();
    await page.locator('#step-list input[value="resource-group"]').check();
    await page.getByRole('button', { name: 'Run preflight' }).click();
    await page.locator('#preflight-state').getByText(/Passing preflight [0-9a-f]{12} is current/).waitFor();
    return {
      page,
      pageErrors,
      async close() {
        await browser.close();
        await server.cleanup();
        server.close();
        await once(server, 'close').catch(() => {});
        await rm(scratch, { recursive: true, force: true });
      },
    };
  } catch (error) {
    await browser.close().catch(() => {});
    await server.cleanup().catch(() => {});
    server.close();
    await once(server, 'close').catch(() => {});
    await rm(scratch, { recursive: true, force: true });
    throw error;
  }
}

test('lead: a run request that fails at the network level restores the run controls', async () => {
  const app = await startLeadPage();
  try {
    const { page } = app;
    await page.route('**/api/run/stream', (route) => route.abort('failed'));
    await page.getByRole('button', { name: 'Run selected steps' }).click();
    const alert = page.locator('#run-error[role="alert"]');
    await alert.getByText(/run request failed before the server answered .*and the installer UI server has no record of that request/).waitFor();
    assert.match(await alert.textContent(), /still running in its terminal/);
    assert.equal(await page.getByRole('button', { name: 'Run selected steps' }).isEnabled(), true);
    assert.equal(await page.getByRole('button', { name: 'Stop run' }).isDisabled(), true);
    assert.equal(await page.getByRole('button', { name: 'Refresh account' }).isEnabled(), true);
    assert.deepEqual(app.pageErrors, []);
  } finally {
    await app.close();
  }
});

test('lead: a later run whose stream ends before any event reattaches from the start of that run', async () => {
  const app = await startLeadPage();
  try {
    const { page } = app;
    await page.getByRole('button', { name: 'Run selected steps' }).click();
    await page.locator('#run-status').getByText('Run finished.').waitFor();
    // The second run's stream ends before any event; the server still reports that run as running.
    const attachUrls = [];
    let requestId = '';
    await page.route('**/api/run/stream', (route) => {
      requestId = route.request().headers()['x-client-request-id'];
      return route.fulfill({ status: 200, contentType: 'application/x-ndjson', body: '' });
    });
    await page.route('**/api/run/status', (route) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ id: 'second-run', clientRequestId: requestId, state: 'running', currentStepId: 'resource-group', steps: ['resource-group'] }) }));
    await page.route('**/api/run/attach?after=*', (route) => {
      attachUrls.push(new URL(route.request().url()).search);
      return route.fulfill({ status: 200, contentType: 'application/x-ndjson', body: '{"seq":1,"type":"summary","exitCode":0,"failedStepId":"","resumeCommand":"","state":"exited","message":""}\n' });
    });
    await page.getByRole('button', { name: 'Run selected steps' }).click();
    await page.locator('#run-status').getByText('Run finished.').waitFor();
    assert.deepEqual(attachUrls, ['?after=0']);
    assert.deepEqual(app.pageErrors, []);
  } finally {
    await app.close();
  }
});

test('lead: a run request that fails after the server started the run reattaches to that run', async () => {
  const app = await startLeadPage();
  try {
    const { page } = app;
  let requestId = '';
  await page.route('**/api/run/stream', (route) => route.abort('connectionreset'));
  page.on('request', (request) => {
    if (request.url().includes('/api/run/stream')) requestId = request.headers()['x-client-request-id'];
  });
  await page.route('**/api/run/status?request=*', (route) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ id: 'started-run', clientRequestId: requestId, state: 'running', currentStepId: 'resource-group', steps: ['resource-group'], admission: { state: 'started', runId: 'started-run' } }) }));
    await page.route('**/api/run/attach?after=0', (route) => route.fulfill({ status: 200, contentType: 'application/x-ndjson', body: '{"seq":1,"type":"progress","stepId":"resource-group","event":"started","message":"reattached after the lost request"}\n{"seq":2,"type":"summary","exitCode":0,"failedStepId":"","resumeCommand":"","state":"exited","message":""}\n' }));
    await page.getByRole('button', { name: 'Run selected steps' }).click();
    await page.locator('#run-status').getByText('Run finished.').waitFor();
    assert.match(await page.locator('#run-output').textContent(), /reattached after the lost request/);
    assert.equal(await page.locator('#run-error').textContent(), '');
    assert.deepEqual(app.pageErrors, []);
  } finally {
    await app.close();
  }
});
