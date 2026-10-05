import assert from 'node:assert/strict';
import { once } from 'node:events';
import { mkdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { createInstallerUiServer } from '../tools/installer-ui/server.mjs';

const stubInstaller = fileURLToPath(new URL('./installer-ui-stub.mjs', import.meta.url));

async function start(extra = {}) {
  const scratch = join(tmpdir(), `p93-g8b-${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`);
  await rm(scratch, { recursive: true, force: true });
  await mkdir(scratch, { recursive: true });
  const server = await createInstallerUiServer({
    token: 'g8b-token-with-at-least-32-bytes-0000',
    stubInstaller,
    idleMs: 60_000,
    env: extra.env || {},
    readOnlyTimeoutMs: extra.readOnlyTimeoutMs,
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

async function passPreflight(page) {
  await page.locator('[name="SubscriptionId"]').fill('00000000-0000-4000-8000-000000000093');
  await page.getByRole('button', { name: 'List steps' }).click();
  await page.locator('#step-list input[value="resource-group"]').check();
  await page.getByRole('button', { name: 'Run preflight' }).click();
  await page.locator('#preflight-state').getByText(/Passing preflight/).waitFor();
}

test('R3-1 delayed preflight answer edits show stale state without installing the fingerprint', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  try {
    await page.locator('[name="SubscriptionId"]').fill('00000000-0000-4000-8000-000000000093');
    let releasePreflight;
    const release = new Promise((resolve) => { releasePreflight = resolve; });
    const intercepted = new Promise((resolve) => {
      page.route('**/api/preflight', async (route) => {
        resolve();
        await release;
        const response = await route.fetch();
        await route.fulfill({ response });
      });
    });
    const preflight = page.getByRole('button', { name: 'Run preflight' }).click();
    await intercepted;
    await page.locator('[name="ResourceGroup"]').fill('rg-changed-during-preflight');
    const select = page.locator('select').first();
    if (await select.count()) {
      const values = await select.locator('option').evaluateAll((options) => options.map((option) => option.value).filter(Boolean));
      if (values.length) await select.selectOption(values.at(-1));
    }
    releasePreflight();
    await preflight;
    await page.locator('#preflight-state').getByText(/answers changed while the preflight ran/i).waitFor();
    await assert.equal(await page.getByRole('button', { name: 'Run selected steps' }).isDisabled(), true);
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});

test('R3-1 failed re-preflight leaves no current fingerprint on the page', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  try {
    await passPreflight(page);
    await page.route('**/api/preflight', (route) => route.fulfill({ status: 502, contentType: 'application/json', body: JSON.stringify({ error: 'malformed preflight for R3-1' }) }));
    await page.getByRole('button', { name: 'Run preflight' }).click();
    await page.locator('#preflight-output').getByText(/malformed preflight for R3-1/).waitFor();
    await page.locator('#preflight-state').getByText(/No passing preflight yet|Preflight is stale/).waitFor();
    assert.equal(await page.getByRole('button', { name: 'Run selected steps' }).isDisabled(), true);
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});

test('R3-1 preflight-required run refusal marks the page stale and re-enables preflight', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  try {
    await passPreflight(page);
    await page.route('**/api/run/stream', (route) => route.fulfill({ status: 409, contentType: 'application/json', body: JSON.stringify({ error: 'No passing preflight matched this run. Run preflight again before starting the installer.', reason: 'preflight-required' }) }));
    await page.getByRole('button', { name: 'Run selected steps' }).click();
    await page.locator('#preflight-state').getByText(/No passing preflight matched this run/).waitFor();
    assert.equal(await page.getByRole('button', { name: 'Run selected steps' }).isDisabled(), true);
    assert.equal(await page.getByRole('button', { name: 'Run preflight' }).isDisabled(), false);
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});

test('R3-2 browser sends a client request id with each run request', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  try {
    await passPreflight(page);
    let requestId = '';
    await page.route('**/api/run/stream', (route) => {
      requestId = route.request().headers()['x-client-request-id'] || '';
      return route.fulfill({ status: 200, contentType: 'application/x-ndjson', body: '{"seq":1,"type":"summary","exitCode":0,"failedStepId":"","resumeCommand":"","state":"exited","message":""}\n' });
    });
    await page.getByRole('button', { name: 'Run selected steps' }).click();
    await page.locator('#run-status').getByText(/Run finished/).waitFor();
    assert.match(requestId, /^[0-9a-f]{32}$/);
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});
