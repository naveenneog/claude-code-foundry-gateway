import assert from 'node:assert/strict';
import { once } from 'node:events';
import { mkdir, readFile, readdir, rm } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { createInstallerUiServer } from '../tools/installer-ui/server.mjs';

const stubInstaller = fileURLToPath(new URL('./installer-ui-stub.mjs', import.meta.url));

async function start(extra = {}) {
  const scratch = join(tmpdir(), `p93-g5-${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`);
  await rm(scratch, { recursive: true, force: true });
  await mkdir(scratch, { recursive: true });
  const log = join(scratch, 'stub.ndjson');
  const server = await createInstallerUiServer({
    token: 'g5-test-token-with-at-least-32-bytes-0000',
    stubInstaller,
    idleMs: 60_000,
    env: { P93_INSTALLER_UI_STUB_LOG: log, ...(extra.env || {}) },
  });
  const address = await server.listenAsync('127.0.0.1');
  return {
    server,
    scratch,
    log,
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
  const consoleErrors = [];
  page.on('pageerror', (error) => pageErrors.push(error.message));
  page.on('console', (message) => {
    if (message.type() === 'error') consoleErrors.push(message.text());
  });
  await page.addInitScript(() => {
    window.__p93Unhandled = [];
    window.addEventListener('unhandledrejection', (event) => {
      window.__p93Unhandled.push(String(event.reason?.message || event.reason));
    });
  });
  await page.goto(`${app.base}/?token=${encodeURIComponent(app.token)}`);
  await page.waitForSelector('[name="SubscriptionId"]');
  return { browser, page, pageErrors, consoleErrors };
}

async function readStubLog(app) {
  if (!existsSync(app.log)) return [];
  return (await readFile(app.log, 'utf8')).trim().split(/\r?\n/).filter(Boolean).map((line) => JSON.parse(line));
}

async function waitForInstallerRuns(app, count) {
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    const runs = (await readStubLog(app)).filter((entry) => entry.args.includes('-Yes'));
    if (runs.length >= count) return runs;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(`timed out waiting for ${count} installer runs`);
}

test('T1 operator journey runs selected steps, shows failed rerun and records exact installer scopes', { timeout: 60_000 }, async () => {
  const app = await start({ env: { P93_INSTALLER_UI_STUB_FAIL_STEP_ONCE: 'gateway-deployment' } });
  const { browser, page, pageErrors, consoleErrors } = await openPage(app);
  try {
    await page.locator('[name="SubscriptionId"]').fill('00000000-0000-4000-8000-000000000093');
    await page.getByRole('button', { name: 'List steps' }).click();
    await page.locator('#step-list input[value="resource-group"]').check();
    await page.locator('#step-list input[value="gateway-deployment"]').check();
    await page.getByRole('button', { name: 'Run preflight' }).click();
    await page.getByText(/Passing preflight [0-9a-f]{12}/).waitFor();
    await page.getByRole('button', { name: 'Run selected steps' }).click();
    await page.getByText(/Gateway deployment failed|gateway-deployment failed|\[redacted\] failed/).waitFor();
    await page.getByText(/Install-ClaudeGateway\.ps1 -Steps gateway-deployment/).waitFor();
    await page.getByRole('button', { name: 'Re-run failed step' }).click();
    await page.locator('#rerun-status').getByText(/Re-run finished/).waitFor();
    const runs = await waitForInstallerRuns(app, 2);
    assert.equal(runs.length, 2);
    assert.deepEqual(runs.map((entry) => entry.args.slice(entry.args.indexOf('-Steps'), entry.args.indexOf('-Steps') + 2)), [
      ['-Steps', 'resource-group,gateway-deployment'],
      ['-Steps', 'gateway-deployment'],
    ]);
    assert.deepEqual(pageErrors, []);
    assert.deepEqual(consoleErrors, []);
    assert.deepEqual(await page.evaluate(() => window.__p93Unhandled), []);
  } finally {
    await browser.close();
    await app.close();
  }
});

test('T4 child exit waits are registered immediately after spawn', async () => {
  const testsDir = fileURLToPath(new URL('.', import.meta.url));
  const files = (await readdir(testsDir)).filter((name) => /^installer-ui.*\.test\.mjs$/.test(name)).sort();
  const offenders = [];
  let checked = 0;
  for (const file of files) {
    const lines = (await readFile(new URL(file, import.meta.url), 'utf8')).split(/\r?\n/);
    for (let index = 0; index < lines.length; index++) {
      const match = lines[index].match(/\bconst\s+(\w+)\s*=\s*spawn\(/);
      if (!match) continue;
      const child = match[1];
      const exitListener = new RegExp(`(?:once\\(${child},\\s*|${child}\\.(?:on|once)\\()['"](?:exit|close)['"]`);
      if (!lines.some((line) => exitListener.test(line))) continue;
      checked++;
      let end = index;
      while (end < lines.length && !/\);\s*$/.test(lines[end])) end++;
      // A child can exit while the test awaits something else, so its exit or close listener must exist before the first await.
      for (let next = end + 1; next < lines.length; next++) {
        if (exitListener.test(lines[next])) break;
        if (/\bawait\b/.test(lines[next])) {
          offenders.push(`${file}:${next + 1} awaits before ${child} has an exit listener`);
          break;
        }
      }
    }
  }
  assert.ok(checked >= 4, `the detector checked ${checked} spawned children`);
  assert.deepEqual(offenders, []);
});
