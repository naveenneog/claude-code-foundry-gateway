/**
 * Captures the Entra group blades that back the chargeback hierarchy.
 *
 * Reuses the persistent profile created by guide/auth.mjs. If that session has
 * expired the script says so and exits non-zero rather than saving a picture of
 * a sign-in page, because a screenshot of a login form looks enough like a
 * screenshot of a group to get published by mistake.
 *
 *   node guide/capture-entra.mjs
 *   node guide/capture-entra.mjs --headed     # watch it, or complete MFA
 */
import { chromium } from 'playwright';
import path from 'node:path';
import fs from 'node:fs';

const PROFILE = path.resolve('.pw-profile');
const OUT = path.resolve('docs/guide');
const HEADED = process.argv.includes('--headed');

const GROUPS = [
  { id: 'df529b3b-df37-40ab-9593-f19b9219f855', name: 'claude-bu-mcaps',     file: 'entra-1-bu-mcaps.png',  blade: 'Members' },
  { id: 'cbe8263d-55fc-4080-b147-d1fc6fc36aed', name: 'claude-team-ites-1',  file: 'entra-2-ites-1.png',    blade: 'Members' },
  { id: 'a2a9bda1-06dd-4774-a50a-63e89e45ad32', name: 'claude-team-ites-2',  file: 'entra-3-ites-2.png',    blade: 'Members' },
  { id: '058d5d1d-1823-4b43-b884-0938694e462a', name: 'claude-bu-gbb',       file: 'entra-4-bu-gbb.png',    blade: 'Members' },
  { id: 'bac8d3f3-a87e-493b-b607-cca92d013d18', name: 'claude-code-standard', file: 'entra-5-tier-standard.png', blade: 'Members' },
  { id: '78e38759-d8a3-4436-b0dd-699a5e0c31be', name: 'claude-code-premium',  file: 'entra-6-tier-premium.png',  blade: 'Members' },
];

fs.mkdirSync(OUT, { recursive: true });

const ctx = await chromium.launchPersistentContext(PROFILE, {
  channel: 'msedge',
  headless: !HEADED,
  viewport: { width: 1600, height: 950 },
  args: ['--no-first-run', '--no-default-browser-check'],
});

const page = ctx.pages()[0] ?? (await ctx.newPage());
const results = [];

for (const g of GROUPS) {
  const url = `https://portal.azure.com/#view/Microsoft_AAD_IAM/GroupDetailsMenuBlade/~/${g.blade}/groupId/${g.id}`;
  await page.goto(url, { waitUntil: 'domcontentloaded' });

  // The portal renders the blade well after domcontentloaded, and the member
  // grid later still. Wait for the group name to appear rather than a fixed
  // sleep, then settle.
  let ok = false;
  try {
    await page.waitForFunction(
      (n) => document.body && document.body.innerText.includes(n),
      g.name,
      { timeout: 60000 },
    );
    await page.waitForTimeout(4000);
    ok = true;
  } catch {
    ok = false;
  }

  const text = await page.locator('body').innerText().catch(() => '');
  if (/Sign in|Pick an account|Enter password|login\.microsoftonline/i.test(text) || /login\.microsoftonline/.test(page.url())) {
    console.log(`  AUTH  session expired - run: node guide/auth.mjs`);
    results.push({ ...g, state: 'auth' });
    break;
  }
  if (!ok) {
    console.log(`  MISS  ${g.name} - blade did not render`);
    results.push({ ...g, state: 'miss' });
    continue;
  }

  const dest = path.join(OUT, g.file);
  await page.screenshot({ path: dest });
  console.log(`  OK    ${g.name} -> docs/guide/${g.file}`);
  results.push({ ...g, state: 'ok' });
}

await ctx.close();

const ok = results.filter((r) => r.state === 'ok').length;
console.log(`\n${ok} of ${GROUPS.length} captured.`);
if (ok < GROUPS.length) process.exit(1);
