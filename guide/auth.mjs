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

// Which directory to sign in to. Without this the portal opens whichever
// tenant the account defaults to, which is rarely the one holding the gateway:
// an account in both a corporate tenant and a sandbox lands in the corporate
// one, where the subscription is not, and every capture then shows an empty
// blade. Set AZURE_TENANT to the tenant the gateway lives in.
const TENANT = process.env.AZURE_TENANT ?? '';
const url = TENANT
  ? `https://portal.azure.com/#@${TENANT}/`
  : 'https://portal.azure.com/';

const ctx = await chromium.launchPersistentContext(PROFILE, {
  channel: 'msedge',
  headless: false,
  viewport: { width: 1600, height: 1000 },
  args: ['--no-first-run', '--no-default-browser-check'],
});

const page = ctx.pages()[0] ?? (await ctx.newPage());
if (TENANT) console.log(`Signing in to directory ${TENANT}`);
else console.log('No AZURE_TENANT set - signing in to the account default directory.');
await page.goto(url, { waitUntil: 'domcontentloaded' });

console.log('Waiting for sign-in to complete...');
console.log('If prompted, approve the request in Microsoft Authenticator.');

const started = Date.now();
let signedIn = false;

while (Date.now() - started < DEADLINE_MS) {
  await page.waitForTimeout(5000);
  const url = page.url();

  if (/portal\.azure\.com/.test(url) && !/login\.microsoftonline/.test(url)) {
    // Portal shell has actually rendered, not just the URL.
    //
    // The element check used to be the only test and it was too narrow: a
    // signed-in session reported NOT signed in because none of those three
    // selectors matched the current portal build, and the operator was sent to
    // authenticate again on a profile that was already good. The brand text is
    // checked too, so a renamed shell element no longer reads as a failure.
    const shell = await page.locator('#azure-portal-shell, [id*="ShellRoot"], header')
      .first().isVisible().catch(() => false);
    const branded = await page.locator('text=Microsoft Azure').first()
      .isVisible().catch(() => false);
    if (shell || branded) { signedIn = true; break; }
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
