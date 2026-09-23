// Captures the Microsoft Entra blades that make Turnstile admin-only, for docs/TURNSTILE.md.
//
//   node guide/auth.mjs                      # once, to complete MFA in the saved profile
//   $env:TURNSTILE_APP_ID = '<application (client) id>'
//   $env:TURNSTILE_SP_ID  = '<enterprise application object id>'
//   $env:REDACTIONS_FILE  = '<local JSON: [["real","example"], ...]>'   # never committed
//   node guide/capture-turnstile-entra.mjs
//
// Redaction happens in the page, in every frame, before each photograph. This file holds
// only generic patterns - identifiers, guest UPNs, addresses - so no real name is ever
// committed; names specific to a tenant (its display name, a person's name) come from
// REDACTIONS_FILE on the machine that runs it. After redacting, every frame is read again
// and the picture is not saved if any real value, or any identifier that is not a
// placeholder, is still visible.

import { chromium } from 'playwright';
import fs from 'node:fs';
import path from 'node:path';

const APP = process.env.TURNSTILE_APP_ID;
const SP = process.env.TURNSTILE_SP_ID;
if (!APP || !SP) {
  console.error('Set TURNSTILE_APP_ID and TURNSTILE_SP_ID.');
  process.exit(2);
}
const local = process.env.REDACTIONS_FILE
  ? JSON.parse(fs.readFileSync(process.env.REDACTIONS_FILE, 'utf8').replace(/^\uFEFF/, ''))
  : [];
const OUT = path.resolve('docs/guide');
const PUBLIC_GUIDS = ['04b07795-8ddb-461a-bbee-02f9e1bf7b46']; // Azure CLI, published by Microsoft

const registered = (blade) => `https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/${blade}/appId/${APP}`;
const enterprise = (blade) => `https://portal.azure.com/#view/Microsoft_AAD_IAM/ManagedAppMenuBlade/~/${blade}/objectId/${SP}/appId/${APP}`;
const BLADES = [
  { url: registered('Overview'), wait: 'Supported account types', file: 'turnstile-entra-1-overview.png' },
  { url: registered('ProtectAnAPI'), wait: 'Turnstile.Manage', file: 'turnstile-entra-2-expose-api.png' },
  { url: registered('AppRoles'), wait: 'Turnstile.Admin', file: 'turnstile-entra-3-app-roles.png' },
  { url: registered('Authentication'), wait: 'Single-page application', file: 'turnstile-entra-4-authentication.png' },
  { url: enterprise('Properties'), wait: 'Assignment required', file: 'turnstile-entra-5-assignment-required.png' },
  { url: enterprise('Users'), wait: 'Turnstile administrator', file: 'turnstile-entra-6-users-and-groups.png' },
];

async function redactFrame(frame, pairs) {
  return frame.evaluate(({ pairs, publicGuids }) => {
    const guid = /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi;
    const map = (window.__redactMap ||= new Map());
    const swap = (s) => {
      let t = s;
      for (const [real, fake] of pairs) t = t.split(real).join(fake);
      t = t.replace(/[A-Za-z0-9._%+-]+#EXT#@[A-Za-z0-9.-]+/g, 'amara.okafor_contoso.com#EXT#@contoso.onmicrosoft.com');
      t = t.replace(/[A-Za-z0-9._%+-]+@(microsoft|[a-z0-9-]+\.onmicrosoft)\.com/gi, 'amara.okafor@contoso.com');
      t = t.replace(guid, (g) => {
        if (publicGuids.includes(g.toLowerCase())) return g;
        if (!map.has(g.toLowerCase())) map.set(g.toLowerCase(), `00000000-0000-0000-0000-${String(map.size + 1).padStart(12, '0')}`);
        return map.get(g.toLowerCase());
      });
      return t;
    };
    if (!document.body) return 0;
    let n = 0;
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      const t = swap(node.nodeValue);
      if (t !== node.nodeValue) { node.nodeValue = t; n++; }
    }
    for (const el of document.querySelectorAll('input, textarea')) {
      const t = swap(el.value);
      if (t !== el.value) { el.value = t; n++; }
    }
    for (const el of document.querySelectorAll('[title], [aria-label]')) {
      for (const a of ['title', 'aria-label']) {
        const v = el.getAttribute(a);
        if (v && swap(v) !== v) el.setAttribute(a, swap(v));
      }
    }
    return n;
  }, { pairs, publicGuids: PUBLIC_GUIDS });
}

async function leaks(frame, pairs) {
  return frame.evaluate(({ reals, publicGuids }) => {
    const text = (document.body?.innerText || '') + ' ' + [...document.querySelectorAll('input, textarea')].map((e) => e.value).join(' ');
    const found = reals.filter((r) => r && text.includes(r));
    const guids = (text.match(/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi) || [])
      .filter((g) => !g.startsWith('00000000-0000-0000-0000-') && !publicGuids.includes(g.toLowerCase()));
    return [...found, ...guids];
  }, { reals: pairs.map(([real]) => real), publicGuids: PUBLIC_GUIDS });
}

// The portal renders each blade in its own frame, well after the page loads. Poll every
// frame for text that only the finished blade shows; a sign-in page means the saved
// session expired, and a picture of it must not be saved in place of the blade.
async function waitForBlade(page, text, timeoutMs = 60000) {
  const deadline = Date.now() + timeoutMs;
  // Opening a blade can pass through login.microsoftonline.com for a silent single
  // sign-on redirect that returns by itself. Only a sign-in page that stays is an
  // expired session.
  let onSignInSince = null;
  while (Date.now() < deadline) {
    let prompt = /login\.microsoftonline/.test(page.url());
    for (const f of page.frames()) {
      const t = await f.evaluate(() => document.body?.innerText || '').catch(() => '');
      // A multifactor prompt has already pushed a request to someone's phone. Stop at
      // once rather than wait on it, and never retry into another push.
      if (/Approve sign in request|Verify your identity/.test(t)) return 'mfa';
      if (/Pick an account|Enter password/.test(t)) prompt = true;
      if (t.includes(text)) return 'ok';
    }
    onSignInSince = prompt ? (onSignInSince ?? Date.now()) : null;
    if (onSignInSince && Date.now() - onSignInSince > 25000) return 'auth';
    await page.waitForTimeout(1000);
  }
  return 'missing';
}

const ctx = await chromium.launchPersistentContext(path.resolve('.pw-profile'), {
  channel: 'msedge', headless: !process.argv.includes('--headed'), viewport: { width: 1600, height: 950 }, args: ['--no-first-run'],
});
const page = ctx.pages()[0] ?? (await ctx.newPage());
let saved = 0;
for (const b of BLADES) {
  await page.goto(b.url, { waitUntil: 'domcontentloaded' });
  const state = await waitForBlade(page, b.wait);
  if (state === 'mfa') { console.log(`  MFA   ${b.file}: this blade needs a fresh multifactor sign-in - run: node guide/auth.mjs, then again`); process.exitCode = 1; break; }
  if (state === 'auth') { console.log('  AUTH  the saved session has expired - run: node guide/auth.mjs'); process.exitCode = 1; break; }
  if (state !== 'ok') { console.log(`  MISS  ${b.file}: "${b.wait}" never appeared`); process.exitCode = 1; continue; }
  await page.waitForTimeout(4000);
  for (const f of page.frames()) await redactFrame(f, local).catch(() => 0);
  const left = (await Promise.all(page.frames().map((f) => leaks(f, local).catch(() => [])))).flat();
  if (left.length) { console.log(`  LEAK  ${b.file} not saved: ${left.length} real value(s) still visible`); process.exitCode = 1; continue; }
  await page.screenshot({ path: path.join(OUT, b.file) });
  console.log(`  OK    ${b.file}`);
  saved++;
}
await ctx.close();
console.log(`\n${saved} of ${BLADES.length} blade(s) captured, redacted and leak-checked.`);
