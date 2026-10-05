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

async function abortAfterServerRunCompletes(page) {
  await page.route('**/api/run/stream', async (route) => {
    await route.fetch();
    await route.abort('failed');
  });
}

function forwardRunThenAbortBrowser(route) {
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
  return { aborted: route.abort('failed'), forwarded };
}

async function withDelayedPreflight(page, edit) {
  let releasePreflight;
  const release = new Promise((resolve) => { releasePreflight = resolve; });
  let intercepted;
  const interceptedRequest = new Promise((resolve) => { intercepted = resolve; });
  await page.route('**/api/preflight', async (route) => {
    intercepted();
    await release;
    const response = await route.fetch();
    await route.fulfill({ response });
  });
  const preflight = page.getByRole('button', { name: 'Run preflight' }).click();
  await interceptedRequest;
  await edit();
  releasePreflight();
  await preflight;
}

test('R3-1 delayed preflight text edits show stale state without installing the fingerprint', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  try {
    await page.locator('[name="SubscriptionId"]').fill('00000000-0000-4000-8000-000000000093');
    await withDelayedPreflight(page, () => page.locator('[name="ResourceGroup"]').fill('rg-changed-during-preflight'));
    await page.locator('#preflight-state').getByText(/answers changed while the preflight ran/i).waitFor();
    await assert.equal(await page.getByRole('button', { name: 'Run selected steps' }).isDisabled(), true);
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});

test('R3-1 delayed preflight Sku edits show stale state without installing the fingerprint', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  try {
    await page.locator('[name="SubscriptionId"]').fill('00000000-0000-4000-8000-000000000093');
    await withDelayedPreflight(page, () => page.locator('[name="Sku"]').selectOption('BasicV2'));
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

test('R3-2 real server recovery follows an aborted successful run to its summary', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  try {
    await passPreflight(page);
    await abortAfterServerRunCompletes(page);
    await page.getByRole('button', { name: 'Run selected steps' }).click();
    await page.locator('#run-status').getByText(/Run finished/).waitFor();
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});

test('R3-2 real server recovery reports an aborted failed run summary', async () => {
  const app = await start({ env: { P93_INSTALLER_UI_STUB_FAIL_STEP: 'resource-group' } });
  const { browser, page, pageErrors } = await openPage(app);
  try {
    await passPreflight(page);
    await abortAfterServerRunCompletes(page);
    await page.getByRole('button', { name: 'Run selected steps' }).click();
    await page.locator('#run-error').getByText(/Installer run failed with exit code 7/).waitFor();
    await page.locator('#run-error').getByText(/Failed step: resource-group/).waitFor();
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});

test('R3-2 real server recovery waits through admitting before following the started run', async () => {
  let holdAdmission = false;
  let releaseIdentity;
  let identityEntered;
  const heldIdentity = new Promise((resolve) => { releaseIdentity = resolve; });
  const identityStarted = new Promise((resolve) => { identityEntered = resolve; });
  const app = await start({
    readIdentity: async () => {
      if (holdAdmission) {
        identityEntered();
        await heldIdentity;
      }
      return { signedIn: true, user: 'one@example.test', tenantId: 'tenant-1', subscriptionId: '00000000-0000-4000-8000-000000000093' };
    },
  });
  const { browser, page, pageErrors } = await openPage(app);
  let forwardedRun;
  try {
    await passPreflight(page);
    holdAdmission = true;
    await page.route('**/api/run/stream', async (route) => {
      const forwarded = forwardRunThenAbortBrowser(route);
      forwardedRun = forwarded.forwarded;
      await forwarded.aborted;
    });
    await page.getByRole('button', { name: 'Run selected steps' }).click();
    await identityStarted;
    await page.locator('#run-status').getByText(/Running selected steps/).waitFor();
    releaseIdentity();
    const forwardedResponse = await forwardedRun;
    assert.equal(forwardedResponse.status, 200);
    await page.locator('#run-status').getByText(/Run finished/).waitFor();
    await assertClean(page, pageErrors);
  } finally {
    releaseIdentity?.();
    await forwardedRun?.catch(() => {});
    await browser.close();
    await app.close();
  }
});

test('R3-2 admission null does not attach to another running run', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  try {
    await passPreflight(page);
    let attachCount = 0;
    await page.route('**/api/run/stream', (route) => route.abort('failed'));
    await page.route('**/api/run/status?request=*', (route) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ id: 'other-run', state: 'running', currentStepId: 'resource-group', steps: ['resource-group'], admission: null }) }));
    await page.route('**/api/run/attach?after=*', (route) => {
      attachCount++;
      return route.fulfill({ status: 500, body: '' });
    });
    await page.getByRole('button', { name: 'Run selected steps' }).click();
    await page.locator('#run-error').getByText(/server has no record of that request/i).waitFor();
    assert.equal(attachCount, 0);
    assert.equal(await page.getByRole('button', { name: 'Run selected steps' }).isEnabled(), true);
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});

test('R3-2 failed status recovery says the server did not answer', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  try {
    await passPreflight(page);
    await page.route('**/api/run/stream', (route) => route.abort('failed'));
    await page.route('**/api/run/status?request=*', (route) => route.abort('failed'));
    await page.getByRole('button', { name: 'Run selected steps' }).click();
    await page.locator('#run-error').getByText(/server did not answer status requests/i).waitFor();
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});

test('R3-2 refused admission found by recovery marks the preflight stale', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  try {
    await passPreflight(page);
    await page.route('**/api/run/stream', (route) => route.abort('failed'));
    await page.route('**/api/run/status?request=*', (route) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ admission: { state: 'refused', error: 'Run preflight again before starting the installer.', reason: 'preflight-required' } }) }));
    await page.getByRole('button', { name: 'Run selected steps' }).click();
    await page.locator('#preflight-state').getByText(/Run preflight again before starting the installer/).waitFor();
    assert.equal(await page.getByRole('button', { name: 'Run selected steps' }).isDisabled(), true);
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});

test('R3-2 malformed stream line reattaches to the same run and finishes', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  try {
    await passPreflight(page);
    let requestId = '';
    await page.route('**/api/run/stream', (route) => {
      requestId = route.request().headers()['x-client-request-id'];
      return route.fulfill({ status: 200, contentType: 'application/x-ndjson', body: '{"seq":1,"type":"progress","stepId":"resource-group","event":"started","message":"started"}\nnot-json\n' });
    });
    await page.route('**/api/run/status?request=*', (route) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ id: 'same-run', clientRequestId: requestId, state: 'running', currentStepId: 'resource-group', steps: ['resource-group'], admission: { state: 'started', runId: 'same-run' } }) }));
    await page.route('**/api/run/attach?after=1', (route) => route.fulfill({ status: 200, contentType: 'application/x-ndjson', body: '{"seq":2,"type":"summary","exitCode":0,"failedStepId":"","resumeCommand":"","state":"exited","message":""}\n' }));
    await page.getByRole('button', { name: 'Run selected steps' }).click();
    await page.locator('#run-status').getByText(/Run finished/).waitFor();
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});

test('R3-2 broken stream recovery says a running server run can be reattached after reload', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  try {
    await passPreflight(page);
    let requestId = '';
    await page.route('**/api/run/stream', (route) => {
      requestId = route.request().headers()['x-client-request-id'];
      return route.fulfill({ status: 200, contentType: 'application/x-ndjson', body: '{"seq":1,"type":"progress","stepId":"resource-group","event":"started","message":"started"}\nnot-json\n' });
    });
    await page.route('**/api/run/status?request=*', (route) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ id: 'same-run', clientRequestId: requestId, state: 'running', currentStepId: 'resource-group', steps: ['resource-group'], admission: { state: 'started', runId: 'same-run' } }) }));
    await page.route('**/api/run/status', (route) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ id: 'same-run', state: 'running', currentStepId: 'resource-group', steps: ['resource-group'] }) }));
    await page.route('**/api/run/attach?after=*', (route) => route.fulfill({ status: 200, contentType: 'application/x-ndjson', body: '' }));
    await page.getByRole('button', { name: 'Run selected steps' }).click();
    await page.locator('#run-error').getByText(/run continues on the server/i).waitFor();
    await page.locator('#run-error').getByText(/reloading the page reattaches/i).waitFor();
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});

test('R3-2 lost request does not attach a later run that replaced the admitted record', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  try {
    await passPreflight(page);
    let attachCount = 0;
    await page.route('**/api/run/stream', (route) => route.abort('failed'));
    await page.route('**/api/run/status?request=*', (route) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ id: 'later-run', state: 'running', currentStepId: 'gateway-deployment', steps: ['gateway-deployment'], admission: { state: 'started', runId: 'original-run' } }) }));
    await page.route('**/api/run/attach?after=*', (route) => {
      attachCount++;
      return route.fulfill({ status: 200, contentType: 'application/x-ndjson', body: '{"seq":1,"type":"summary","exitCode":0,"failedStepId":"","resumeCommand":"","state":"exited","message":""}\n' });
    });
    await page.getByRole('button', { name: 'Run selected steps' }).click();
    await page.locator('#run-error').getByText(/finished, and a later run replaced its record/i).waitFor();
    assert.equal(attachCount, 0);
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});

test('R3-9 page load attaches to a stopping run with controls disabled until summary', async () => {
  const app = await start();
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
  let releaseAttach;
  const attachReleased = new Promise((resolve) => { releaseAttach = resolve; });
  try {
    await page.route('**/api/run/status', (route) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ id: 'stopping-run', state: 'stopping', currentStepId: 'resource-group', steps: ['resource-group'] }) }));
    await page.route('**/api/run/attach?after=*', async (route) => {
      await attachReleased;
      return route.fulfill({ status: 200, contentType: 'application/x-ndjson', body: '{"seq":1,"type":"summary","exitCode":null,"failedStepId":"","resumeCommand":"","state":"stopped","stepId":"resource-group","message":"Stopped installer run at resource-group."}\n' });
    });
    await page.goto(`${app.base}/?token=${encodeURIComponent(app.token)}`);
    await page.waitForSelector('[name="SubscriptionId"]');
    await page.locator('#run-status').getByText('Stopping at resource-group.').waitFor();
    assert.equal(await page.getByRole('button', { name: 'Refresh account' }).isDisabled(), true);
    assert.equal(await page.getByRole('button', { name: 'Run preflight' }).isDisabled(), true);
    assert.equal(await page.getByRole('button', { name: 'Stop run' }).isDisabled(), true);
    releaseAttach();
    await page.locator('#run-status').getByText('Run stopped at resource-group.').waitFor();
    await assertClean(page, pageErrors);
  } finally {
    releaseAttach?.();
    await browser.close();
    await app.close();
  }
});
