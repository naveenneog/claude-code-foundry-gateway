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
  const scratch = join(tmpdir(), `p93-g10b-${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`);
  await rm(scratch, { recursive: true, force: true });
  await mkdir(scratch, { recursive: true });
  const log = join(scratch, 'calls.log');
  const server = await createInstallerUiServer({
    token: 'g10b-token-with-at-least-32-bytes-000',
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

async function pageApiAuth(page) {
  const cookie = (await page.context().cookies()).map((item) => `${item.name}=${item.value}`).join('; ');
  const csrfToken = (await (await fetch(`${new URL(page.url()).origin}/api/session`, { headers: { cookie } })).json()).csrfToken;
  return { cookie, csrfToken };
}

// Starts a real run that waits before its installer child until release(), and returns once the page offers Stop for it.
async function followHeldRun() {
  let release;
  let entered;
  const held = new Promise((resolve) => { release = resolve; });
  const reached = new Promise((resolve) => { entered = resolve; });
  const app = await start({ beforeRunSpawn: async () => { entered(); await held; } });
  const { browser, page, pageErrors } = await openPage(app);
  try {
    const stopRequests = [];
    page.on('request', (request) => { if (new URL(request.url()).pathname === '/api/run/stop') stopRequests.push(request.method()); });
    await passPreflight(page);
    await page.getByRole('button', { name: 'Run selected steps' }).click();
    await within(reached, 30_000, 'The run reaching the point before its installer child');
    await page.waitForFunction(() => !document.querySelector('#stop-run')?.disabled);
    return { app, browser, page, pageErrors, release, stopRequests };
  } catch (error) {
    release();
    await browser.close().catch(() => {});
    await app.close().catch(() => {});
    throw error;
  }
}

// Stops the followed real run from Node with the page's session, as another tab or client would.
async function stopFromAnotherClient(app, page) {
  const auth = await pageApiAuth(page);
  const { id } = await (await fetch(`${app.base}/api/run/status`, { headers: { cookie: auth.cookie } })).json();
  const stopped = await fetch(`${app.base}/api/run/stop`, {
    method: 'POST',
    headers: { cookie: auth.cookie, 'x-csrf-token': auth.csrfToken, 'content-type': 'application/json' },
    body: JSON.stringify({ runId: id }),
  });
  assert.equal(stopped.status, 200);
}

async function focusedElement(page) {
  return page.evaluate(() => document.activeElement?.id || document.activeElement?.tagName || '');
}

test('R8-1 a stop from another client moves keyboard focus from Stop to the run status', async () => {
  const run = await followHeldRun();
  const { app, browser, page, pageErrors } = run;
  try {
    await page.getByRole('button', { name: 'Stop run' }).focus();
    await stopFromAnotherClient(app, page);
    await page.locator('#run-output').getByText(/stopped: resource-group/).waitFor();
    await page.waitForFunction(() => document.activeElement?.id !== 'stop-run');
    assert.equal(await focusedElement(page), 'run-status');
    assert.match(await page.locator('#run-status').textContent(), /Stopping at resource-group\./);
    run.release();
    await page.locator('#run-status').getByText(/Run stopped at resource-group\./).waitFor();
    assert.notEqual(await focusedElement(page), 'BODY');
    await assertClean(page, pageErrors);
  } finally {
    run.release();
    await browser.close();
    await app.close();
  }
});

test('R8-1 after a reload a stop from another client moves keyboard focus from Stop to the run status', async () => {
  const run = await followHeldRun();
  const { app, browser, page, pageErrors } = run;
  try {
    await page.reload();
    await page.waitForSelector('[name="SubscriptionId"]');
    await page.waitForFunction(() => !document.querySelector('#stop-run')?.disabled);
    await page.getByRole('button', { name: 'Stop run' }).focus();
    await stopFromAnotherClient(app, page);
    await page.locator('#run-output').getByText(/stopped: resource-group/).waitFor();
    await page.waitForFunction(() => document.activeElement?.id !== 'stop-run');
    assert.equal(await focusedElement(page), 'run-status');
    assert.match(await page.locator('#run-status').textContent(), /Stopping at resource-group\./);
    run.release();
    await page.locator('#run-status').getByText(/Run stopped at resource-group\./).waitFor();
    await assertClean(page, pageErrors);
  } finally {
    run.release();
    await browser.close();
    await app.close();
  }
});

test('R8-1 a run that ends while keyboard focus is in a field leaves the focus there', async () => {
  const run = await followHeldRun();
  const { app, browser, page, pageErrors } = run;
  try {
    await page.locator('[name="SubscriptionId"]').focus();
    run.release();
    await page.locator('#run-status').getByText(/Run finished\./).waitFor();
    assert.equal(await page.evaluate(() => document.activeElement?.getAttribute('name')), 'SubscriptionId');
    await assertClean(page, pageErrors);
  } finally {
    run.release();
    await browser.close();
    await app.close();
  }
});

test('R9-1 Tab from the run status after a stop from another client reaches the run output', async () => {
  const run = await followHeldRun();
  const { app, browser, page, pageErrors } = run;
  try {
    await page.getByRole('button', { name: 'Stop run' }).focus();
    await stopFromAnotherClient(app, page);
    await page.locator('#run-output').getByText(/stopped: resource-group/).waitFor();
    await page.waitForFunction(() => document.activeElement?.id === 'run-status');
    await page.keyboard.press('Tab');
    assert.equal(await focusedElement(page), 'run-output');
    await page.keyboard.press('Shift+Tab');
    assert.equal(await page.evaluate(() => document.activeElement?.closest('section')?.querySelector('h2')?.textContent), 'Run');
    run.release();
    await page.locator('#run-status').getByText(/Run stopped at resource-group\./).waitFor();
    await assertClean(page, pageErrors);
  } finally {
    run.release();
    await browser.close();
    await app.close();
  }
});

test('R9-1 Tab from the Stop status after the operator stops the run reaches the run output', async () => {
  const run = await followHeldRun();
  const { app, browser, page, pageErrors } = run;
  try {
    await page.evaluate(() => { globalThis.confirm = () => true; });
    await page.getByRole('button', { name: 'Stop run' }).focus();
    await page.keyboard.press('Enter');
    await page.locator('#stop-run-status').getByText(/Stop requested\./).waitFor();
    await page.waitForFunction(() => document.activeElement?.id === 'stop-run-status');
    await page.keyboard.press('Tab');
    assert.equal(await focusedElement(page), 'run-output');
    run.release();
    await page.locator('#run-status').getByText(/Run stopped at resource-group\./).waitFor();
    await assertClean(page, pageErrors);
  } finally {
    run.release();
    await browser.close();
    await app.close();
  }
});
