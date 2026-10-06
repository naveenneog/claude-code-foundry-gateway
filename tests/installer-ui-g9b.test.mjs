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

async function openPageWithRoutes(app, installRoutes) {
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
    await installRoutes(page);
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

function forwardRunThenAbortBrowser(route, serverReceived) {
  const request = route.request();
  const requestHeaders = request.headers();
  const headers = {};
  for (const name of ['cookie', 'x-csrf-token', 'x-client-request-id', 'content-type']) {
    if (requestHeaders[name]) headers[name] = requestHeaders[name];
  }
  const forwarded = fetch(request.url(), {
    method: request.method(),
    headers,
    body: request.postData(),
  });
  const abort = () => route.abort('failed');
  return { aborted: serverReceived.then(abort, abort), forwarded };
}

async function nodePreflight(app, auth, steps) {
  const response = await fetch(`${app.base}/api/preflight`, {
    method: 'POST',
    headers: { cookie: auth.cookie, 'x-csrf-token': auth.csrfToken, 'content-type': 'application/json' },
    body: JSON.stringify({ answers: { schemaVersion: 1, SubscriptionId: '00000000-0000-4000-8000-000000000093' }, steps }),
  });
  const body = await response.json();
  assert.equal(response.status, 200, JSON.stringify(body));
  assert.match(body.fingerprint, /^[0-9a-f]{64}$/);
  return body.fingerprint;
}

function runFromNode(app, auth, fingerprint, steps) {
  return fetch(`${app.base}/api/run/stream`, {
    method: 'POST',
    headers: {
      cookie: auth.cookie,
      'x-csrf-token': auth.csrfToken,
      'content-type': 'application/json',
      'x-client-request-id': 'node-run-b-0000000000000000000000',
    },
    body: JSON.stringify({ answers: { schemaVersion: 1, SubscriptionId: '00000000-0000-4000-8000-000000000093' }, steps, fingerprint }),
  });
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

test('L6-2 real recovery refuses a later failed run that replaces the followed record', async () => {
  const app = await start({ env: { P93_INSTALLER_UI_STUB_FAIL_STEP: 'gateway-deployment' } });
  const { browser, page, pageErrors } = await openPage(app);
  let forwardedRun;
  let forwardedText;
  let runBResponse;
  try {
    await passPreflight(page);
    const auth = await pageApiAuth(page);
    await page.route('**/api/run/stream', async (route) => {
      const request = route.request();
      const requestHeaders = request.headers();
      const headers = {};
      for (const name of ['cookie', 'x-csrf-token', 'x-client-request-id', 'content-type']) {
        if (requestHeaders[name]) headers[name] = requestHeaders[name];
      }
      forwardedRun = fetch(request.url(), {
        method: request.method(),
        headers,
        body: request.postData(),
      });
      forwardedText = forwardedRun.then((response) => response.text());
      await forwardedText;
      await route.abort('failed');
    });
    await page.route('**/api/run/attach?after=*&run=*', async (route) => {
      await page.unroute('**/api/run/stream');
      const fingerprint = await within(nodePreflight(app, auth, ['gateway-deployment']), 30_000, 'Node preflight for run B');
      runBResponse = await within(runFromNode(app, auth, fingerprint, ['gateway-deployment']), 30_000, 'Run B response headers');
      assert.equal(runBResponse.status, 200);
      assert.match(runBResponse.headers.get('x-installer-run-id') || '', /^[0-9a-f]{32}$/);
      await route.continue();
    });
    await page.getByRole('button', { name: 'Run selected steps' }).click();
    await page.locator('#run-error').getByText(/later run replaced its record/i).waitFor();
    await expectNoText(page, /Installer run failed with exit code 7/);
    await expectNoText(page, /Failed step: gateway-deployment/);
    await expectNoText(page, /Install-ClaudeGateway\.ps1 -Steps gateway-deployment/);
    assert.doesNotMatch(await page.locator('#run-output').textContent(), /gateway-deployment/);
    assert.match(await within(runBResponse.text(), 30_000, 'Run B stream ending'), /"type":"summary"/);
    await assertClean(page, pageErrors);
  } finally {
    await forwardedRun?.then((response) => response.body?.cancel()).catch(() => {});
    await runBResponse?.body?.cancel().catch(() => {});
    await browser.close();
    await app.close();
  }
});

async function expectNoText(page, pattern) {
  assert.equal(await page.getByText(pattern).count(), 0);
}

test('L6-1 page-load reattach run-replaced clears run state and controls', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPageWithRoutes(app, async (routePage) => {
    await routePage.route('**/api/run/status', (route) => route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({ id: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', state: 'running', currentStepId: 'resource-group', steps: ['resource-group'] }),
    }));
    await routePage.route('**/api/run/attach?after=*&run=*', (route) => route.fulfill({
      status: 409,
      contentType: 'application/json',
      body: JSON.stringify({ error: 'The requested run record was replaced by a later installer run.', reason: 'run-replaced' }),
    }));
  });
  try {
    await page.locator('#run-error').getByText(/later run replaced its record/i).waitFor();
    assert.equal(await page.getByRole('button', { name: 'Stop run' }).isDisabled(), true);
    assert.equal(await page.getByRole('button', { name: 'Refresh account' }).isEnabled(), true);
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});

test('L6-6 a new page-started run clears the previous run output', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  let runCount = 0;
  try {
    await passPreflight(page);
    await page.route('**/api/run/stream', (route) => {
      runCount++;
      const runId = runCount === 1 ? '11111111111111111111111111111111' : '22222222222222222222222222222222';
      const marker = runCount === 1 ? 'first-run-marker' : 'second-run-marker';
      return route.fulfill({
        status: 200,
        headers: { 'x-installer-run-id': runId },
        contentType: 'application/x-ndjson',
        body: `{"seq":1,"type":"progress","stepId":"resource-group","event":"started","message":"${marker}"}\n{"seq":2,"type":"summary","exitCode":0,"failedStepId":"","resumeCommand":"","state":"exited","message":""}\n`,
      });
    });
    await page.getByRole('button', { name: 'Run selected steps' }).click();
    await page.locator('#run-output').getByText(/first-run-marker/).waitFor();
    await page.getByRole('button', { name: 'Run selected steps' }).click();
    await page.locator('#run-output').getByText(/second-run-marker/).waitFor();
    assert.doesNotMatch(await page.locator('#run-output').textContent(), /first-run-marker/);
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

test('R5-1 a superseded preflight pass is shown as stale and does not admit a run', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  try {
    await page.locator('[name="SubscriptionId"]').fill('00000000-0000-4000-8000-000000000093');
    await page.getByRole('button', { name: 'List steps' }).click();
    await page.locator('#step-list input[value="resource-group"]').check();
    await page.route('**/api/preflight', (route) => route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({
        superseded: true,
        preflight: { schemaVersion: 1, installer: 'pwsh', answersSchemaVersion: 1, result: 'PASS', checks: [{ id: 'answers.schema', result: 'PASS', reason: null, message: 'answers file is valid', remedy: '', problems: [] }] },
      }),
    }));
    await page.getByRole('button', { name: 'Run preflight' }).click();
    await page.locator('#preflight-state').getByText(/Preflight is stale\. A later preflight for the same answers started while this one ran/).waitFor();
    assert.equal(await page.getByRole('button', { name: 'Run selected steps' }).isDisabled(), true);
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});
