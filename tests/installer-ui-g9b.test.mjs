import assert from 'node:assert/strict';
import { once } from 'node:events';
import { mkdir, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { createInstallerUiServer } from '../tools/installer-ui/server.mjs';

const stubInstaller = fileURLToPath(new URL('./installer-ui-stub.mjs', import.meta.url));

async function start(extra = {}) {
  const scratch = join(tmpdir(), `p93-g9b-${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`);
  await rm(scratch, { recursive: true, force: true });
  await mkdir(scratch, { recursive: true });
  const log = join(scratch, 'calls.log');
  const server = await createInstallerUiServer({
    token: 'g9b-token-with-at-least-32-bytes-0000',
    stubInstaller,
    idleMs: 60_000,
    env: { P93_INSTALLER_UI_STUB_LOG: log, ...(extra.env || {}) },
    readIdentity: extra.readIdentity ?? (async () => ({ signedIn: true, user: 'one@example.test', tenantId: 'tenant-1', subscriptionId: '00000000-0000-4000-8000-000000000093' })),
    beforeRunSpawn: extra.beforeRunSpawn,
  });
  const address = await server.listenAsync('127.0.0.1');
  return {
    base: `http://127.0.0.1:${address.port}`,
    token: server.token,
    log,
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
  try {
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
  } catch (error) {
    await browser.close().catch(() => {});
    await app.close?.().catch(() => {});
    throw error;
  }
}

async function assertClean(page, pageErrors) {
  assert.deepEqual(pageErrors, []);
  assert.deepEqual(await page.evaluate(() => window.__p93Unhandled), []);
}

async function passPreflight(page) {
  await page.locator('[name="SubscriptionId"]').fill('00000000-0000-4000-8000-000000000093');
  await page.getByRole('button', { name: 'List steps' }).click();
  await page.locator('#step-list input[value="resource-group"]').check();
  await page.getByRole('button', { name: 'Run preflight' }).click();
  await page.locator('#preflight-state').getByText(/Passing preflight/).waitFor();
}

function within(promise, ms, what) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${what} did not happen within ${ms} ms`)), ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

test('R4-2 broken stream reports a replaced run record and does not attach', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  try {
    await passPreflight(page);
    let attachCount = 0;
    await page.route('**/api/run/stream', (route) => route.fulfill({
      status: 200,
      headers: { 'x-installer-run-id': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' },
      contentType: 'application/x-ndjson',
      body: '{"seq":1,"type":"progress","stepId":"resource-group","event":"started","message":"started"}\nnot-json\n',
    }));
    await page.route('**/api/run/status?request=*', (route) => route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({ id: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', state: 'running', currentStepId: 'gateway-deployment', steps: ['gateway-deployment'], admission: { state: 'started', runId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' } }),
    }));
    await page.route('**/api/run/attach?after=*&run=*', (route) => {
      attachCount++;
      return route.fulfill({ status: 200, contentType: 'application/x-ndjson', body: '' });
    });
    await page.getByRole('button', { name: 'Run selected steps' }).click();
    await page.locator('#run-error').getByText(/later run replaced its record/i).waitFor();
    assert.equal(attachCount, 0);
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});

test('R4-3 Stop is disabled during admission and while an accepted stop is pending summary', async () => {
  let holdAdmission = false;
  let releaseIdentity;
  let identityEntered;
  let releaseRun;
  let runEntered;
  const heldIdentity = new Promise((resolve) => { releaseIdentity = resolve; });
  const identityStarted = new Promise((resolve) => { identityEntered = resolve; });
  const heldRun = new Promise((resolve) => { releaseRun = resolve; });
  const runStarted = new Promise((resolve) => { runEntered = resolve; });
  const app = await start({
    readIdentity: async () => {
      if (holdAdmission) {
        identityEntered();
        await heldIdentity;
      }
      return { signedIn: true, user: 'one@example.test', tenantId: 'tenant-1', subscriptionId: '00000000-0000-4000-8000-000000000093' };
    },
    beforeRunSpawn: async () => {
      runEntered();
      await heldRun;
    },
  });
  const { browser, page, pageErrors } = await openPage(app);
  try {
    await passPreflight(page);
    holdAdmission = true;
    await page.getByRole('button', { name: 'Run selected steps' }).click();
    await within(identityStarted, 30_000, 'The run admission identity read');
    assert.equal(await page.getByRole('button', { name: 'Stop run' }).isDisabled(), true);
    releaseIdentity();
    await within(runStarted, 30_000, 'The run reaching beforeRunSpawn');
    await page.getByRole('button', { name: 'Stop run' }).waitFor({ state: 'visible' });
    await page.waitForFunction(() => !document.querySelector('#stop-run')?.disabled);
    await page.evaluate(() => { globalThis.confirm = () => true; });
    await page.getByRole('button', { name: 'Stop run' }).click();
    await page.locator('#run-status').getByText(/Stopping at resource-group\./).waitFor();
    assert.equal(await page.getByRole('button', { name: 'Stop run' }).isDisabled(), true);
    releaseRun();
    await page.locator('#run-status').getByText(/Run stopped at resource-group\./).waitFor();
    assert.equal(await page.getByRole('button', { name: 'Stop run' }).isDisabled(), true);
    let calls = [];
    try {
      calls = (await readFile(app.log, 'utf8')).split('\n').filter(Boolean).map((line) => JSON.parse(line));
    } catch {}
    assert.equal(calls.some((call) => call.args?.includes('-Yes')), false);
    await assertClean(page, pageErrors);
  } finally {
    releaseIdentity?.();
    releaseRun?.();
    await browser.close();
    await app.close();
  }
});
