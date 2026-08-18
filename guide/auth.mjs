/**
 * One-time authentication for the guide capture.
 *
 * Opens a dedicated browser profile and waits for the operator to complete
 * MFA. The persistent profile keeps the session, so the capture script does
 * not need to authenticate again.
 *
 * Nothing from the operator's real browser profile is opened or read.
 */
import { chromium } from 'playwright';
import path from 'node:path';

const PROFILE = path.resolve('.pw-profile');
const DEADLINE_MS = 4 * 60 * 1000;

const ctx = await chromium.launchPersistentContext(PROFILE, {
  channel: 'msedge',
  headless: false,
  viewport: { width: 1600, height: 1000 },
  args: ['--no-first-run', '--no-default-browser-check'],
});

const page = ctx.pages()[0] ?? (await ctx.newPage());
await page.goto('https://portal.azure.com/', { waitUntil: 'domcontentloaded' });

console.log('Waiting for sign-in to complete...');
console.log('If prompted, approve the request in Microsoft Authenticator.');

const started = Date.now();
let signedIn = false;

while (Date.now() - started < DEADLINE_MS) {
  await page.waitForTimeout(5000);
  const url = page.url();

  if (/portal\.azure\.com/.test(url) && !/login\.microsoftonline/.test(url)) {
    // Portal shell has actually rendered, not just the URL.
    const shell = await page.locator('#azure-portal-shell, [id*="ShellRoot"], header')
      .first().isVisible().catch(() => false);
    if (shell) { signedIn = true; break; }
  }

  const txt = await page.locator('body').innerText().catch(() => '');
  const num = txt.match(/\n\s*(\d{2})\s*\n/);
  if (/Approve sign in request/i.test(txt)) {
    console.log(`  still waiting - Authenticator number: ${num ? num[1] : '(see screen)'}`);
  } else if (/530033|device requesting access/i.test(txt)) {
    console.log('  BLOCKED by conditional access (device compliance)');
    break;
  }
}

console.log(signedIn ? 'SIGNED IN - session saved to the profile' : 'NOT signed in');

if (signedIn) {
  await ctx.storageState({ path: path.resolve('guide/.auth.json') });
  console.log('storage state written to guide/.auth.json');
}

await ctx.close();
