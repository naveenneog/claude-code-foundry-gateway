#!/usr/bin/env node
// Live, read-only console evidence. No Azure portal or persistent profile is opened.
import { createHash, randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { mkdir, rm, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { annotate } from './lib/annotate.mjs';
import { allowConsoleRequest, redactText, isSignInPage, publicCaptureReceipt } from './architecture-live.mjs';
import { redactVisibleDocument } from './architecture-live-dom.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const stage = join(root, '.shots-entra', 'architecture-live');
const plan = JSON.parse(readFileSync(join(stage, 'plan.json'), 'utf8').replace(/^\uFEFF/, ''));
const connection = plan.selected?.turnstile;
let endpoint;
try { endpoint = new URL(connection?.url ?? ''); }
catch { throw new Error('The private discovery plan has no valid console origin.'); }
if (endpoint.protocol !== 'https:' || endpoint.username || endpoint.password ||
    !['', '/'].includes(endpoint.pathname) || endpoint.search || endpoint.hash ||
    !/^api:\/\/[0-9a-f-]{36}\/[A-Za-z0-9._-]+$/i.test(connection?.scope ?? '')) {
  throw new Error('A discovered HTTPS console origin and Entra API scope are required.');
}
const base = endpoint.origin;
const scratch = join(stage, `console-browser-${randomUUID()}`);
await mkdir(scratch, { recursive: true });
await mkdir(join(stage, 'redacted'), { recursive: true });
const prior = { TEMP: process.env.TEMP, TMP: process.env.TMP, TMPDIR: process.env.TMPDIR };
for (const key of Object.keys(prior)) process.env[key] = scratch;
let browser;
try {
  const { chromium } = await import('playwright');
  browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ viewport: { width: 1600, height: 1050 } });
  await context.addInitScript({ content: `window.__architectureRedactText = (${redactText.toString()});` });
  let redeem = true;
  let blockedWrites = 0;
  await context.route(`${base}/api/**`, async route => {
    const request = route.request();
    if (!allowConsoleRequest(base, request.url(), request.method(), redeem)) {
      blockedWrites++;
      return route.abort();
    }
    if (request.method() === 'POST') redeem = false;
    return route.continue();
  });
  const grant = spawnSync('pwsh', [
    '-NoProfile', '-NonInteractive', '-File', join(root, 'scripts', 'Open-ClaudeTurnstile.ps1'),
    '-TurnstileUrl', base, '-Scope', connection.scope, '-NoBrowser',
  ], { cwd: root, encoding: 'utf8', timeout: 90000 });
  const link = grant.stdout?.trim();
  if (grant.status !== 0 || !link?.startsWith(`${base}/?login_code=`)) {
    throw new Error('The existing Azure CLI session did not issue a console code. No sign-in was attempted.');
  }
  const page = await context.newPage();
  await page.goto(link, { waitUntil: 'domcontentloaded', timeout: 90000 });
  await page.locator('.app-shell').waitFor({ timeout: 90000 });
  if (isSignInPage(page.url(), await page.locator('body').innerText()) || new URL(page.url()).origin !== base) {
    throw new Error('Console sign-in did not complete through the one-time code.');
  }
  const profileResponse = await context.request.get(`${base}/api/v1/auth/me`);
  if (!profileResponse.ok()) throw new Error('Console session verification failed.');
  const identity = await profileResponse.json();
  const catalogResponse = await context.request.get(`${base}/api/v1/enterprise-catalog`);
  if (!catalogResponse.ok()) throw new Error('Catalog read failed; no console evidence claimed.');
  const catalog = await catalogResponse.json();
  const tiersResponse = await context.request.get(`${base}/api/v1/gateway-tiers`);
  if (!tiersResponse.ok()) throw new Error('Tier read failed; no console evidence claimed.');
  const tiers = await tiersResponse.json();
  const pairs = [...plan.replacements];
  if (identity.name) pairs.push({ from: identity.name, to: 'Contoso administrator' });
  (tiers.items ?? []).forEach((item, index) => {
    if (item.entra_group) pairs.push({ from: item.entra_group, to: `Contoso tier group ${index + 1}` });
  });
  for (const name of ['organizations', 'departments']) {
    (catalog[name] ?? []).forEach((item, index) => {
      if (item.id === 'unassigned') return;
      for (const key of ['name', 'id', 'external_ref']) if (item[key]?.length > 2) {
        pairs.push({ from: item[key], to: `Contoso ${name.slice(0, -1)} ${index + 1}` });
      }
    });
  }
  const captures = [];
  for (const [id, route, title] of [
    ['console-governance', 'gateway-governance', 'Live Turnstile governance - consent-free Owner session'],
    ['console-budgets', 'budgets', 'Live Turnstile budgets - read-only capture'],
  ]) {
    const view = await context.newPage();
    await view.goto(`${base}/?source=apim&page=${route}`, { waitUntil: 'domcontentloaded', timeout: 90000 });
    await view.locator('.app-shell').waitFor({ timeout: 90000 });
    await view.waitForFunction(() => !document.querySelector('.finops-state .spin, .registry-loading'), { timeout: 90000 });
    await view.waitForTimeout(2000);
    if ((await view.locator('main').innerText()).trim().length < 80) throw new Error('Console content did not load.');
    await view.evaluate(redactVisibleDocument, pairs);
    await view.locator('[class*="avatar"]').evaluateAll(elements => {
      for (const element of elements) element.style.visibility = 'hidden';
    });
    await view.waitForTimeout(300);
    const image = `docs/images/architecture-live/${id}.png`;
    const target = join(stage, 'redacted', `${id}.png`);
    const capturedUtc = new Date().toISOString();
    await annotate(await view.screenshot(), target, {
      width: 1500, maskIdentity: false,
      banner: { title, note: `Live console · ${capturedUtc.slice(0, 10)} UTC · Contoso display redaction · management writes blocked` },
    });
    captures.push(publicCaptureReceipt({ id, title, status: 'captured', image, capturedUtc,
      sha256: createHash('sha256').update(readFileSync(target)).digest('hex') }));
    await view.close();
  }
  await writeFile(join(stage, 'console-captures.json'), JSON.stringify({ version: 1, captures }, null, 2) + '\n');
  await writeFile(join(stage, 'console-check.json'), JSON.stringify({
    flow: 'consent-free-browser-console', checkedUtc: new Date().toISOString(),
    role: identity.role, method: identity.method, managerScopePresent: identity.manager_scope != null,
    authenticatedBrowser: true, managementWritesAllowed: false, blockedWrites,
    capturedViews: captures.map(capture => capture.id), portalProfileOpened: false,
  }, null, 2) + '\n');
  console.log('Live console views staged for review. No portal profile, code link or bearer token was persisted.');
} catch {
  console.error('Live console capture failed; no new evidence is claimed. Check the discovered service and existing CLI session.');
  process.exitCode = 1;
} finally {
  if (browser) await browser.close();
  for (const [key, value] of Object.entries(prior)) {
    if (value === undefined) delete process.env[key]; else process.env[key] = value;
  }
  await rm(scratch, { recursive: true, force: true });
}
