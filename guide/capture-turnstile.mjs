// Captures the Turnstile screenshots for docs/TURNSTILE.md from the live deployment.
//
//   $env:TURNSTILE_URL = 'https://<turnstile>.azurewebsites.net'
//   $env:TURNSTILE_OWNER_FILE = '<path>/owner.credentials.json'   # never committed
//   node guide/capture-turnstile.mjs
//
// Daily administration of Turnstile is Microsoft Entra only (docs/TURNSTILE.md). These
// captures sign in as the break-glass password Owner, because a headless browser cannot
// complete an interactive Entra sign-in with MFA. The Entra step is still captured: the
// script follows "Sign in with Microsoft" to the real Microsoft page and photographs it,
// which is what shows the tenant-specific authority.
//
// Redaction happens in the page, before each photograph, from the one table below: real
// people, internal unit and group names, and identifiers become example values. Keeping
// the table here means a reviewer can see exactly what was changed and nothing else was.

import fs from 'node:fs';
import path from 'node:path';
import { chromium } from 'playwright';

const BASE = (process.env.TURNSTILE_URL || '').replace(/\/$/, '');
const OWNER_FILE = process.env.TURNSTILE_OWNER_FILE || '';
const OUT = path.resolve('docs/guide');
if (!BASE || !OWNER_FILE) {
  console.error('Set TURNSTILE_URL and TURNSTILE_OWNER_FILE.');
  process.exit(2);
}
const owner = JSON.parse(fs.readFileSync(OWNER_FILE, 'utf8').replace(/^\uFEFF/, ''));

// Real value -> example value. Order matters: longer names first.
const REDACTIONS = [
  [/claude-team-ites-1/gi, 'claude-team-sales-emea'],
  [/claude-team-ites-2/gi, 'claude-team-sales-apac'],
  [/claude-bu-mcaps/gi, 'claude-bu-sales'],
  [/claude-bu-gbb/gi, 'claude-bu-engineering'],
  [/\bites-1\b/gi, 'sales-emea'],
  [/\bites-2\b/gi, 'sales-apac'],
  [/\bmcaps\b/gi, 'sales'],
  [/\bgbb\b/gi, 'engineering'],
  [/[A-Za-z0-9._%+-]+@microsoft\.com/gi, 'developer@contoso.com'],
  [/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi, '00000000-0000-0000-0000-000000000000'],
];

async function redact(page) {
  await page.evaluate((rules) => {
    const compiled = rules.map(([source, flags, to]) => [new RegExp(source, flags), to]);
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      let text = node.nodeValue;
      for (const [re, to] of compiled) text = text.replace(re, to);
      if (text !== node.nodeValue) node.nodeValue = text;
    }
    for (const el of document.querySelectorAll('input, textarea')) {
      let v = el.value;
      for (const [re, to] of compiled) v = v.replace(re, to);
      el.value = v;
    }
  }, REDACTIONS.map(([re, to]) => [re.source, re.flags, to]));
}

async function shot(page, name) {
  await page.waitForTimeout(1500);
  await redact(page);
  const file = path.join(OUT, name);
  await page.screenshot({ path: file, fullPage: false });
  console.log(`  captured ${name}`);
}

const browser = await chromium.launch();
const context = await browser.newContext({ viewport: { width: 1440, height: 900 }, locale: 'en-US' });
const page = await context.newPage();
fs.mkdirSync(OUT, { recursive: true });

// 1. The sign-in page: Microsoft first, the password form as break-glass.
await page.goto(BASE, { waitUntil: 'networkidle' });
await page.getByText('Sign in with Microsoft').first().waitFor({ timeout: 30000 });
await shot(page, 'turnstile-01-signin.png');

// 2. Following "Sign in with Microsoft" lands on the real Microsoft page for the tenant.
const [entraPage] = await Promise.all([
  context.waitForEvent('page', { timeout: 10000 }).catch(() => null),
  page.getByText('Sign in with Microsoft').first().click(),
]);
const target = entraPage || page;
await target.waitForURL(/login\.microsoftonline\.com/, { timeout: 30000 });
await target.waitForLoadState('networkidle');
const authority = new URL(target.url()).pathname.split('/')[1];
console.log(`  Entra authority segment: ${/^[0-9a-f-]{36}$/.test(authority) ? 'tenant id (single-tenant)' : authority}`);
await shot(target, 'turnstile-02-entra-signin.png');
if (entraPage) await entraPage.close();
else await page.goto(BASE, { waitUntil: 'networkidle' });

// 3. Break-glass Owner, for the pages behind sign-in.
await page.goto(BASE, { waitUntil: 'networkidle' });
await page.locator('input[type="email"]').first().fill(owner.email);
await page.locator('input[type="password"]').first().fill(owner.password);
await page.locator('button[type="submit"]').first().click();
await page.waitForLoadState('networkidle');
await page.waitForTimeout(3000);

for (const [query, name] of [
  ['?source=apim&page=budgets', 'turnstile-03-budgets.png'],
  ['?source=apim&page=finops-overview', 'turnstile-04-overview.png'],
  ['?source=apim&page=finops-analytics', 'turnstile-05-analytics.png'],
  ['?source=apim&page=finops-requests', 'turnstile-06-requests.png'],
  ['?source=apim&page=finops-governance', 'turnstile-07-governance.png'],
]) {
  await page.goto(`${BASE}/${query}`, { waitUntil: 'networkidle' });
  await shot(page, name);
}

await browser.close();
