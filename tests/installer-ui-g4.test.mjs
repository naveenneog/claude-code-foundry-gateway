import assert from 'node:assert/strict';
import { once } from 'node:events';
import { mkdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { createInstallerUiServer } from '../tools/installer-ui/server.mjs';
import { validatePreflight } from '../tools/installer-ui/installer-contract.mjs';

const stubInstaller = fileURLToPath(new URL('./installer-ui-stub.mjs', import.meta.url));

async function start(extra = {}) {
  const scratch = join(tmpdir(), `p93-g4-${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`);
  await rm(scratch, { recursive: true, force: true });
  await mkdir(scratch, { recursive: true });
  const server = await createInstallerUiServer({
    token: 'g4-test-token-with-at-least-32-bytes-0000',
    stubInstaller,
    idleMs: 60_000,
    env: { P93_INSTALLER_UI_STUB_LOG: join(scratch, 'stub.ndjson'), ...(extra.env || {}) },
    pwsh: extra.pwsh,
  });
  const address = await server.listenAsync('127.0.0.1');
  return {
    server,
    scratch,
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

async function fillValid(page) {
  await page.locator('[name="SubscriptionId"]').fill('00000000-0000-4000-8000-000000000093');
}

const passPayload = {
  preflight: {
    schemaVersion: 1,
    installer: 'pwsh',
    answersSchemaVersion: 1,
    result: 'PASS',
    checks: [{ id: 'answers.schema', result: 'PASS', reason: null, message: 'answers file is valid', remedy: '', problems: [] }],
  },
  fingerprint: 'a'.repeat(64),
};

test('U1 action wrapper shows busy text and blocks a duplicate preflight click', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  let requests = 0;
  try {
    await fillValid(page);
    await page.route('**/api/preflight', async (route) => {
      requests += 1;
      await new Promise((resolve) => setTimeout(resolve, 1500));
      await route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(passPayload) });
    });
    await expectPollEnabled(page, 'Run preflight');
    await page.evaluate(() => {
      document.getElementById('preflight').click();
      document.getElementById('preflight').click();
    });
    await page.locator('#preflight-status').getByText(/Running preflight/).waitFor();
    assert.equal(await page.getByRole('button', { name: /Running preflight/ }).isDisabled(), true);
    await page.getByText('Preflight finished.').waitFor();
    assert.equal(requests, 1);
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});

test('U1 run refusal 409 tells the operator to run preflight again and restores controls', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  try {
    await fillValid(page);
    await page.getByRole('button', { name: 'List steps' }).click();
    await page.locator('#step-list input').first().check();
    await page.getByRole('button', { name: 'Run preflight' }).click();
    await page.getByText(/Passing preflight/).waitFor();
    await page.route('**/api/run/stream', (route) => route.fulfill({ status: 409, contentType: 'application/json', body: JSON.stringify({ error: 'preflight required', reason: 'preflight-required' }) }));
    await page.getByRole('button', { name: 'Run selected steps' }).click();
    const alert = page.locator('#run-error[role="alert"]');
    await alert.getByText(/Run the preflight again/i).waitFor();
    await expectPollEnabled(page, 'Run selected steps');
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});

test('U1 HTTP 500 renders an action alert with a recovery sentence and no page error', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  try {
    await page.route('**/api/steps', (route) => route.fulfill({ status: 500, contentType: 'application/json', body: JSON.stringify({ error: 'step list exploded', remedy: 'Try again after the terminal settles.' }) }));
    await page.getByRole('button', { name: 'List steps' }).click();
    const alert = page.locator('#steps-error[role="alert"]');
    await alert.getByText(/step list exploded/).waitFor();
    await assert.match(await alert.textContent(), /Try again/);
    await expectPollEnabled(page, 'List steps');
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});

test('U1 network failure renders an action alert, restores controls and has no unhandled rejection', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  try {
    await page.route('**/api/steps', (route) => route.abort('failed'));
    await page.getByRole('button', { name: 'List steps' }).click();
    const alert = page.locator('#steps-error[role="alert"]');
    await alert.getByText(/failed/i).waitFor();
    await assert.match(await alert.textContent(), /try again/i);
    await expectPollEnabled(page, 'List steps');
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});

async function expectPollEnabled(page, name) {
  const button = page.getByRole('button', { name });
  await assert.doesNotReject(async () => {
    for (let i = 0; i < 20; i += 1) {
      if (await button.isEnabled()) return;
      await page.waitForTimeout(50);
    }
    assert.equal(await button.isEnabled(), true);
  });
}


test('U2 file static mode shows download upload command handoff and blocks invalid download', async () => {
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
    await page.goto(new URL('../tools/installer-ui/index.html', import.meta.url).href);
    await page.waitForSelector('[name="SubscriptionId"]');
    assert.equal(await page.getByRole('button', { name: 'Run preflight' }).count(), 0);
    await page.getByText('Manage files > Upload').waitFor();
    await page.getByText('PowerShell command').waitFor();
    await page.locator('[name="FoundryAccount"]').fill('bad account');
    await expectPollDisabled(page, 'Download answers.json');
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
  }
});

test('U2 server static mode without pwsh shows the same handoff and downloads valid answers', async () => {
  const app = await start({ pwsh: 'pwsh-missing-for-u2' });
  const { browser, page, pageErrors } = await openPage(app);
  try {
    assert.equal(await page.getByRole('button', { name: 'Run preflight' }).count(), 0);
    await fillValid(page);
    await page.getByText('Manage files > Upload').waitFor();
    await page.getByText('PowerShell command').waitFor();
    const download = page.waitForEvent('download');
    await page.getByRole('button', { name: 'Download answers.json' }).click();
    assert.equal((await download).suggestedFilename(), 'answers.json');
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});

async function expectPollDisabled(page, name) {
  const button = page.getByRole('button', { name });
  for (let i = 0; i < 20; i += 1) {
    if (await button.isDisabled()) return;
    await page.waitForTimeout(50);
  }
  assert.equal(await button.isDisabled(), true);
}


test('U1 fix action settled recomputes stale run and validation-disabled preflight states', async () => {
  const app = await start({ env: { P93_INSTALLER_UI_STUB_DELAY_MS: '350' } });
  const { browser, page, pageErrors } = await openPage(app);
  try {
    await fillValid(page);
    await page.getByRole('button', { name: 'List steps' }).click();
    await page.locator('#step-list input[value="resource-group"]').check();
    await page.getByRole('button', { name: 'Run preflight' }).click();
    await page.getByText(/Passing preflight/).waitFor();
    await page.getByRole('button', { name: 'Run selected steps' }).click();
    await page.locator('[name="ResourceGroup"]').fill('rg-changed-while-running');
    await page.getByText(/summary:/).waitFor();
    await page.getByText(/Preflight is stale/).waitFor();
    assert.equal(await page.getByRole('button', { name: 'Run selected steps' }).isDisabled(), true);
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }

  const preflightApp = await start();
  const opened = await openPage(preflightApp);
  try {
    await fillValid(opened.page);
    await opened.page.route('**/api/preflight', async (route) => {
      await new Promise((resolve) => setTimeout(resolve, 500));
      await route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(passPayload) });
    });
    await expectPollEnabled(opened.page, 'Run preflight');
    await opened.page.getByRole('button', { name: 'Run preflight' }).click();
    await opened.page.locator('[name="FoundryAccount"]').fill('bad account');
    await opened.page.getByText('Preflight finished.').waitFor();
    assert.equal(await opened.page.getByRole('button', { name: 'Run preflight' }).isDisabled(), true);
    await assertClean(opened.page, opened.pageErrors);
  } finally {
    await opened.browser.close();
    await preflightApp.close();
  }
});


function failPreflight(check) {
  return {
    preflight: {
      schemaVersion: 1,
      installer: 'pwsh',
      answersSchemaVersion: 1,
      result: 'FAIL',
      checks: [check],
    },
    exitCode: 1,
  };
}

test('U3 contract accepts optional string problem paths and rejects non-string paths', () => {
  const payload = failPreflight({
    id: 'answers.schema',
    result: 'FAIL',
    reason: null,
    message: 'SubscriptionId is required',
    remedy: 'Give SubscriptionId.',
    problems: [{ path: 'SubscriptionId', message: 'SubscriptionId is required', remedy: 'Give SubscriptionId.' }],
  }).preflight;
  assert.equal(validatePreflight(payload).checks[0].problems[0].path, 'SubscriptionId');
  const bad = structuredClone(payload);
  bad.checks[0].problems[0].path = 93;
  assert.throws(() => validatePreflight(bad), /problem path is not text/);
});

test('U3 preflight problem path links to the field and focuses it', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  try {
    await fillValid(page);
    await page.route('**/api/preflight', (route) => route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify(failPreflight({
        id: 'answers.schema',
        result: 'FAIL',
        reason: null,
        message: 'SubscriptionId is required',
        remedy: 'Give SubscriptionId.',
        problems: [{ path: 'SubscriptionId', message: 'SubscriptionId is required', remedy: 'Give SubscriptionId.' }],
      })),
    }));
    await page.getByRole('button', { name: 'Run preflight' }).click();
    await page.getByRole('button', { name: 'Review SubscriptionId' }).click();
    assert.equal(await page.evaluate(() => document.activeElement?.name), 'SubscriptionId');
    assert.equal(await page.locator('[name="SubscriptionId"]').getAttribute('aria-invalid'), 'true');
    const described = await page.locator('[name="SubscriptionId"]').getAttribute('aria-describedby');
    const errorId = described.split(/\s+/)[0];
    assert.match(await page.locator('#' + errorId).textContent(), /SubscriptionId is required/);
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});

test('U3 preflight problem without a path falls back to x-checkId mapped fields', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  try {
    await fillValid(page);
    await page.route('**/api/preflight', (route) => route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify(failPreflight({
        id: 'foundry.account',
        result: 'FAIL',
        reason: null,
        message: 'The Foundry account was not found',
        remedy: 'Choose a readable account.',
        problems: [{ message: 'The Foundry account was not found', remedy: 'Choose a readable account.' }],
      })),
    }));
    await page.getByRole('button', { name: 'Run preflight' }).click();
    await page.getByRole('button', { name: 'Review FoundryAccount' }).click();
    assert.equal(await page.evaluate(() => document.activeElement?.name), 'FoundryAccount');
    assert.equal(await page.locator('[name="FoundryAccount"]').getAttribute('aria-invalid'), 'true');
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});

test('U3 blank SubscriptionId is marked by browser validation and focusable from the problem', async () => {
  const app = await start();
  const { browser, page, pageErrors } = await openPage(app);
  try {
    await page.locator('[name="SubscriptionId"]').fill('00000000-0000-4000-8000-000000000093');
    await page.locator('[name="SubscriptionId"]').fill('');
    await page.getByRole('button', { name: 'Review SubscriptionId' }).click();
    assert.equal(await page.evaluate(() => document.activeElement?.name), 'SubscriptionId');
    assert.equal(await page.locator('[name="SubscriptionId"]').getAttribute('aria-invalid'), 'true');
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});


test('U4 keyboard and accessibility journey has names, live regions, focus moves and labelled output', async () => {
  const app = await start({ env: { P93_INSTALLER_UI_STUB_FAIL_STEP: 'gateway-deployment' } });
  const { browser, page, pageErrors } = await openPage(app);
  try {
    const unnamed = await page.locator('button:visible, input:visible, select:visible, textarea:visible').evaluateAll((nodes) => nodes.filter((node) => {
      const id = node.id;
      const aria = node.getAttribute('aria-label') || node.getAttribute('aria-labelledby');
      const label = id ? document.querySelector(`label[for="${CSS.escape(id)}"]`) : null;
      const wrapped = node.closest('label');
      const text = node.textContent || node.getAttribute('placeholder') || '';
      return !(aria || label?.textContent?.trim() || wrapped?.textContent?.trim() || text.trim());
    }).map((node) => node.outerHTML));
    assert.deepEqual(unnamed, []);
    assert.equal(await page.locator('#preflight-state').getAttribute('role'), 'status');
    assert.equal(await page.locator('#errors').getAttribute('role'), 'alert');
    assert.equal(await page.locator('#run-output').getAttribute('aria-label'), 'Run output');

    await page.getByRole('button', { name: 'Add unit' }).focus();
    await page.keyboard.press('Enter');
    assert.equal(await page.evaluate(() => document.activeElement?.dataset.buField), 'id');
    await page.keyboard.type('finance');
    await page.keyboard.press('Tab');
    await page.keyboard.type('claude-bu-finance');
    await page.keyboard.press('Tab');
    await page.keyboard.type('100');
    await page.getByRole('button', { name: 'Add team' }).focus();
    await page.keyboard.press('Enter');
    assert.equal(await page.evaluate(() => document.activeElement?.dataset.buField), 'id');
    await page.keyboard.type('finance-apps');
    await page.locator('[data-bu-index="1"] button').focus();
    await page.keyboard.press('Enter');
    assert.equal(await page.evaluate(() => document.activeElement?.dataset.buField), 'id');

    await fillValid(page);
    await page.getByRole('button', { name: 'List steps' }).click();
    await page.locator('#step-list input[value="gateway-deployment"]').check();
    await page.getByRole('button', { name: 'Run preflight' }).click();
    await page.getByText(/Passing preflight/).waitFor();
    await page.getByRole('button', { name: 'Run selected steps' }).click();
    await page.getByText(/summary:/).waitFor();
    assert.equal(await page.getByRole('button', { name: 'Re-run failed step' }).isEnabled(), true);
    await page.getByRole('button', { name: 'Re-run failed step' }).click();
    await page.getByText(/Re-run finished/).waitFor();
    await assertClean(page, pageErrors);
  } finally {
    await browser.close();
    await app.close();
  }
});
