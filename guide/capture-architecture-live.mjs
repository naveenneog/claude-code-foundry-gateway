#!/usr/bin/env node
import { createHash, randomUUID } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { mkdir, open, rm, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { annotate } from './lib/annotate.mjs';
import { makePortalUrl, redactText, isSignInPage, isBladeReady, validateCapturePlan, publicCaptureReceipt } from './architecture-live.mjs';
import { redactVisibleDocument } from './architecture-live-dom.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const selected = args.filter(arg => !arg.startsWith('--'));
const planPath = join(root, '.shots-entra', 'architecture-live', 'plan.json');
if (!existsSync(planPath)) throw new Error('Run guide/Get-ArchitectureCapturePlan.ps1 first. No deployment defaults are embedded.');
const plan = JSON.parse(readFileSync(planPath, 'utf8').replace(/^\uFEFF/, ''));
validateCapturePlan(plan);
const profile = join(root, '.pw-profile');
if (!existsSync(profile)) throw new Error('Copy the owner-authorized capture profile to this worktree. This script never signs in.');
const privateRoot = join(root, '.shots-entra', 'architecture-live');
const output = join(privateRoot, 'redacted');
const scratch = join(privateRoot, `browser-${randomUUID()}`);
await mkdir(scratch, { recursive: true });
await mkdir(output, { recursive: true });
const lockPath = join(privateRoot, 'capture.lock');
const lock = await open(lockPath, 'wx').catch(() => { throw new Error('Another architecture capture owns this worktree profile. Do not open a second browser.'); });
const old = { TEMP: process.env.TEMP, TMP: process.env.TMP, TMPDIR: process.env.TMPDIR };
for (const key of Object.keys(old)) process.env[key] = scratch;
let context;
const results = [];
async function visibleFrames(page) {
  const frames = [];
  for (const frame of page.frames()) {
    if (frame !== page.mainFrame()) {
      const element = await frame.frameElement();
      const bounds = await element.boundingBox();
      if (!bounds || bounds.width < 10 || bounds.height < 10 || !await element.isVisible()) continue;
    }
    frames.push({ frame, text: await frame.locator('body').innerText().catch(() => '') });
  }
  if (frames.some(item => isSignInPage(item.frame.url(), item.text))) {
    const error = new Error('A visible portal frame requires sign-in');
    error.name = 'PortalSignInRequired';
    throw error;
  }
  return frames;
}

async function waitForContent(page, expected) {
  const until = Date.now() + 90000;
  while (Date.now() < until) {
    const frames = await visibleFrames(page);
    if (frames.some(item => item.text.includes(expected))) return frames;
    await page.waitForTimeout(1000);
  }
  throw new Error('Expected visible blade content did not load');
}

try {
  const { chromium } = await import('playwright');
  context = await chromium.launchPersistentContext(profile, {
    channel: 'msedge', headless: !args.includes('--headed'),
    viewport: { width: 1600, height: 1050 }, deviceScaleFactor: 1,
    args: ['--no-first-run', '--no-default-browser-check'],
  });
  await context.addInitScript({ content: `window.__architectureRedactText = (${redactText.toString()});` });
  for (const restored of context.pages()) await restored.close();
  const pages = plan.pages.filter(item => !selected.length || selected.includes(item.id));
  if (!pages.length) throw new Error('No discovered capture matches the requested ids.');
  for (const item of pages) {
    const page = await context.newPage();
    let stage = 'navigate';
    const capturedUtc = new Date().toISOString();
    const result = { id: item.id, title: item.title, capturedUtc, status: 'not-captured' };
    try {
      const url = item.kind === 'entra-app'
        ? `https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/AppRoles/appId/${item.appId}/isMSAApp~/false`
        : makePortalUrl(plan.tenantId, item.resourceId, item.blade);
      await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 90000 });
      await page.waitForTimeout(12000);
      stage = 'resource-header';
      let body = await page.locator('body').innerText();
      if (isSignInPage(page.url(), body)) {
        result.status = 'sign-in-required';
        results.push(result);
        console.error('STOP: portal sign-in is required. No screenshot captured and no sign-in attempted.');
        process.exitCode = 2;
        break;
      }
      await page.waitForFunction(name => document.body?.innerText.toLowerCase().includes(name.toLowerCase()),
        item.resourceName, { timeout: 45000 });
      if (item.menu) {
        stage = 'menu';
        const filter = page.getByPlaceholder('Search', { exact: true });
        if (await filter.count()) await filter.first().fill(item.menu);
        await page.getByText(item.menu, { exact: true }).last().click({ timeout: 15000 });
        await page.waitForTimeout(8000);
      }
      stage = 'blade-content';
      const visible = await waitForContent(page, item.ready ?? 'Essentials');
      body = visible.map(item => item.text).join('\n');
      if (isSignInPage(page.url(), body)) {
        result.status = 'sign-in-required'; results.push(result); process.exitCode = 2;
        console.error('STOP: portal authentication boundary reached. No sign-in attempted.');
        break;
      }
      if (!isBladeReady(body, item.expect, item.ready ?? 'Essentials')) {
        throw new Error('The expected live blade was not available.');
      }
      // Scrub before pixels exist. The observer also catches late portal updates
      // between the initial scrub and the screenshot. No raw PNG is written.
      stage = 'redact';
      for (const { frame } of visible) {
        await frame.evaluate(redactVisibleDocument, plan.replacements);
      }
      await page.waitForTimeout(500);
      const safeText = (await Promise.all(visible.map(item => item.frame.locator('body').innerText()))).join('\n');
      const remaining = plan.replacements.some(({ from }) => from.length > 5 && safeText.includes(from));
      if (remaining) throw new Error('A discovered identity or resource name survived redaction.');
      await writeFile(join(privateRoot, `${item.id}.txt`), safeText);
      const buffer = await page.screenshot({ animations: 'disabled' });
      const image = `docs/images/architecture-live/${item.id}.png`;
      await annotate(buffer, join(output, `${item.id}.png`), {
        width: 1500,
        banner: { title: item.title, note: `Live Azure portal · ${capturedUtc.slice(0, 10)} UTC · identifiers replaced with Contoso placeholders` },
        maskIdentity: true, identity: { account: 'administrator@contoso.com', tenant: 'CONTOSO' },
      });
      result.status = 'captured';
      result.image = image;
      result.sha256 = createHash('sha256').update(readFileSync(join(output, `${item.id}.png`))).digest('hex');
      console.log(`${item.id}: staged for visual review, not published`);
    } catch (error) {
      const body = await page.locator('body').innerText().catch(() => '');
      if (error.name === 'PortalSignInRequired' || isSignInPage(page.url(), body)) {
        result.status = 'sign-in-required'; results.push(result); process.exitCode = 2;
        console.error('STOP: portal redirected to sign-in while loading. No sign-in attempted.');
        break;
      }
      // Portal exceptions can include real URLs. Keep public diagnostics generic.
      const frameTexts = await Promise.all(page.frames().map(frame => frame.locator('body').innerText().catch(() => '')));
      await writeFile(join(privateRoot, `${item.id}-diagnostic.txt`),
        `Stage: ${stage}\n${redactText(error.message, plan.replacements)}\n${redactText(frameTexts.join('\n'), plan.replacements)}`);
      result.status = 'blade-unavailable';
      console.error(`${item.id}: ${stage} unavailable; no evidence claimed`);
      process.exitCode = 1;
    } finally {
      await page.close();
    }
    results.push(result);
  }
  const receiptPath = join(privateRoot, 'captures.json');
  const previous = existsSync(receiptPath) ? JSON.parse(readFileSync(receiptPath, 'utf8')).captures : [];
  const byId = new Map(previous.map(item => [item.id, item]));
  for (const result of results) byId.set(result.id, publicCaptureReceipt(result));
  await writeFile(receiptPath, JSON.stringify({ version: 1, captures: [...byId.values()].sort((a, b) => a.id.localeCompare(b.id)) }, null, 2) + '\n');
} finally {
  if (context) await context.close();
  await lock.close();
  await rm(lockPath, { force: true });
  await rm(scratch, { recursive: true, force: true });
  for (const [key, value] of Object.entries(old)) {
    if (value === undefined) delete process.env[key]; else process.env[key] = value;
  }
}
