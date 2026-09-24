// Proves a save in Turnstile reaches the Claude gateway, and photographs it, for docs/TURNSTILE.md.
//
//   $env:TURNSTILE_URL = 'https://<turnstile>.azurewebsites.net'
//   $env:TURNSTILE_OWNER_FILE = '<path>/owner.credentials.json'   # never committed
//   $env:GATEWAY_RG = '<gateway resource group>'; $env:GATEWAY_APIM = '<api management name>'
//   node guide/capture-turnstile-governance.mjs
//
// Signs in as the break-glass password Owner (a headless browser cannot complete an Entra
// sign-in with MFA), opens Gateway governance, raises the Standard tier's tokens per minute by
// one, saves, and times how long the gateway's tpm-standard named value takes to show it. Then
// puts it back the same way. Every value it reports is read from Azure, not from the page.
//
// Nothing about the deployment is written here. The redactions are built at run time from what
// the gateway holds: each business unit, team and group becomes an example name, addresses at
// the signed-in account's domain become an example address, and identifiers become zeros.

import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { chromium } from 'playwright';

const BASE = (process.env.TURNSTILE_URL || '').replace(/\/$/, '');
const OWNER_FILE = process.env.TURNSTILE_OWNER_FILE || '';
const RG = process.env.GATEWAY_RG || '';
const APIM = process.env.GATEWAY_APIM || '';
const OUT = path.resolve('docs/guide');
if (!BASE || !OWNER_FILE || !RG || !APIM) {
  console.error('Set TURNSTILE_URL, TURNSTILE_OWNER_FILE, GATEWAY_RG and GATEWAY_APIM.');
  process.exit(2);
}
const owner = JSON.parse(fs.readFileSync(OWNER_FILE, 'utf8').replace(/^\uFEFF/, ''));

const az = (args) => execFileSync('az', args, { encoding: 'utf8', shell: process.platform === 'win32' }).trim();
const namedValue = (id) => az(['apim', 'nv', 'show', '-g', RG, '--service-name', APIM, '--named-value-id', id, '--query', 'value', '-o', 'tsv']);
const escape = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

function redactions() {
  const units = namedValue('bu-registry').split(',').filter(Boolean).map((entry) => {
    const [id, rest] = [entry.slice(0, entry.indexOf('=')), entry.slice(entry.indexOf('=') + 1)];
    return { id, group: rest.slice(0, rest.lastIndexOf(':')) };
  });
  const parents = Object.fromEntries(namedValue('bu-parents').split(',').filter(Boolean).map((e) => e.split('=')));
  const names = ['sales', 'engineering', 'finance', 'marketing', 'support', 'research'];
  const regions = ['emea', 'apac', 'amer', 'anz'];
  const example = {};
  units.filter((u) => !parents[u.id]).forEach((u, i) => { example[u.id] = names[i % names.length]; });
  const teams = {};
  for (const u of units.filter((x) => parents[x.id])) {
    const n = (teams[parents[u.id]] = (teams[parents[u.id]] ?? 0) + 1);
    example[u.id] = `${example[parents[u.id]] ?? 'team'}-${regions[(n - 1) % regions.length]}`;
  }
  const pairs = [];
  for (const u of units) pairs.push([u.group, `claude-${parents[u.id] ? 'team' : 'bu'}-${example[u.id]}`], [u.id, example[u.id]]);
  const job = az(['containerapp', 'job', 'list', '-g', RG, '--query', "[?starts_with(name, 'job-turnstile-apply-')].name | [0]", '-o', 'tsv']);
  if (job) pairs.push([job.slice('job-turnstile-apply-'.length), 'contoso']);
  // Longest first, so a group is replaced before the unit id inside it.
  pairs.sort((a, b) => b[0].length - a[0].length);
  const rules = pairs.filter(([from]) => from).map(([from, to]) => [`(?<![\\w])${escape(from)}(?![\\w])`, 'gi', to]);
  const domain = az(['account', 'show', '--query', 'user.name', '-o', 'tsv']).split('@')[1];
  if (domain) rules.push([`[A-Za-z0-9._%+-]+@${escape(domain)}`, 'gi', 'developer@contoso.com']);
  rules.push(['\\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\b', 'gi', '00000000-0000-0000-0000-000000000000']);
  return rules;
}
const RULES = redactions();

async function shot(page, name) {
  await page.waitForTimeout(1500);
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
  }, RULES);
  await page.screenshot({ path: path.join(OUT, name), fullPage: false });
  console.log(`  captured ${name}`);
}

async function editStandardPerMinute(page, value) {
  await page.getByRole('button', { name: 'Edit Standard' }).click();
  await page.getByLabel('Tokens per minute').fill(String(value));
}

async function saveAndWait(page, expected) {
  const saved = Date.now();
  await page.getByRole('button', { name: 'Save and apply' }).click();
  await page.getByRole('dialog').waitFor({ state: 'hidden', timeout: 30000 });
  while (Date.now() - saved < 600000) {
    if (namedValue('tpm-standard') === String(expected)) return Math.round((Date.now() - saved) / 1000);
    await new Promise((r) => setTimeout(r, 5000));
  }
  return null;
}

const browser = await chromium.launch();
const context = await browser.newContext({ viewport: { width: 1440, height: 900 }, locale: 'en-US' });
const page = await context.newPage();
try {
  await page.goto(BASE, { waitUntil: 'networkidle' });
  await page.locator('input[type="email"]').first().fill(owner.email);
  await page.locator('input[type="password"]').first().fill(owner.password);
  await page.locator('button[type="submit"]').first().click();
  await page.waitForLoadState('networkidle');
  await page.goto(`${BASE}/?source=apim&page=gateway-governance`, { waitUntil: 'networkidle' });
  await page.getByRole('heading', { name: 'Tiers' }).waitFor({ timeout: 60000 });
  await shot(page, 'turnstile-10-governance.png');

  const before = Number(namedValue('tpm-standard'));
  const changed = before + 1;
  await editStandardPerMinute(page, changed);
  await shot(page, 'turnstile-11-tier-editor.png');
  const toApply = await saveAndWait(page, changed);
  console.log(`  tpm-standard ${before} -> ${changed}: read on the gateway ${toApply} s after Save and apply`);
  await page.reload({ waitUntil: 'networkidle' });
  await page.getByText('Succeeded').first().waitFor({ timeout: 180000 }).catch(() => {});
  await shot(page, 'turnstile-12-applied.png');

  await editStandardPerMinute(page, before);
  const toRestore = await saveAndWait(page, before);
  console.log(`  tpm-standard ${changed} -> ${before}: read on the gateway ${toRestore} s after Save and apply`);
  console.log(JSON.stringify({ before, changed, secondsToApply: toApply, secondsToRestore: toRestore }));
} finally {
  await browser.close();
}
