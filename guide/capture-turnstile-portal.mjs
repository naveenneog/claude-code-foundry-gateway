// Read-only portal evidence using a COPY of the owner's authenticated capture profile.
// Never enters credentials, consents, starts a job, or changes a group/member.
import fs from 'node:fs';
import path from 'node:path';
import { chromium } from 'playwright';
import { az, captureMetadata, capturePage, Redactor, requireEnvironment, privateJson, utc } from './lib/turnstile-live.mjs';

requireEnvironment('TURNSTILE_APP_ID', 'TURNSTILE_SP_ID', 'REDACTIONS_FILE', 'GATEWAY_RG', 'GATEWAY_APIM');
const account = JSON.parse(az(['account', 'show', '-o', 'json']));
const app = process.env.TURNSTILE_APP_ID;
const sp = process.env.TURNSTILE_SP_ID;
const metadata = captureMetadata();
const redactor = new Redactor(JSON.parse(fs.readFileSync(process.env.REDACTIONS_FILE, 'utf8').replace(/^\uFEFF/, '')));
const registered = (blade) => `https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/${blade}/appId/${app}`;
const enterprise = (blade) => `https://portal.azure.com/#view/Microsoft_AAD_IAM/ManagedAppMenuBlade/~/${blade}/objectId/${sp}/appId/${app}`;
const resource = `/subscriptions/${account.id}/resourceGroups/${process.env.GATEWAY_RG}/providers/Microsoft.ApiManagement/service/${process.env.GATEWAY_APIM}`;
const steps = [
  ['turnstile-entra-1-overview.png', registered('Overview'), 'Application (client) ID', 'App registrations / Overview'],
  ['turnstile-entra-2-expose-api.png', registered('ProtectAnAPI'), 'Turnstile.Manage', 'App registrations / Expose an API'],
  ['turnstile-entra-3-app-roles.png', registered('AppRoles'), 'Turnstile.Admin', 'App registrations / App roles'],
  ['turnstile-t08-entra-config.png', enterprise('Properties'), 'Assignment required', 'Enterprise applications / Properties'],
  ['turnstile-t09-entra-mutation.png', enterprise('Users'), 'Turnstile administrator', 'Enterprise applications / Users and groups (read only)'],
  ['turnstile-portal-named-values.png', `https://portal.azure.com/#@${account.tenantId}/resource${resource}/namedValues`, 'tpm-standard', 'API Management / Named values (read only)'],
];
const selected = process.argv.slice(2).filter((arg) => !arg.startsWith('--'));
const context = await chromium.launchPersistentContext(path.resolve('.pw-profile'), {
  channel: 'msedge', headless: !process.argv.includes('--headed'),
  viewport: { width: 1600, height: 1000 }, args: ['--no-first-run'],
});
const result = { started_at_utc: utc(), identity_kind: 'owner_portal', pages: [] };
try {
  const page = context.pages()[0] ?? await context.newPage();
  for (const [image, url, expected, surface] of steps.filter(([image]) => !selected.length || selected.includes(image))) {
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 90_000 });
    const start = Date.now();
    let found = false;
    while (Date.now() - start < 90_000) {
      const bodies = await Promise.all(page.frames().map((frame) => frame.evaluate(() => document.body?.innerText ?? '').catch(() => '')));
      const text = bodies.join('\n');
      if (/Enter password|Pick an account|Approve sign in request|Verify your identity|Sign in to your account|Email, phone, or Skype/.test(text))
        throw new Error('Portal sign-in prompt: stop and report to the lead; do not attempt sign-in');
      if (text.includes(expected) && !/login\.microsoftonline\.com/.test(page.url())) { found = true; break; }
      await page.waitForTimeout(1000);
    }
    if (!found) throw new Error(`Portal blade did not render: ${surface}`);
    await page.waitForTimeout(2500);
    await capturePage(page, image, {
      route: redactor.redact(url), identity_kind: 'owner_portal', surface,
      state: 'existing authenticated portal session; read only; no directory mutation',
    }, redactor, metadata);
    result.pages.push({ image, surface, utc: utc(), seconds: (Date.now() - start) / 1000 });
    privateJson('portal-capture-result.json', result);
  }
  result.completed_at_utc = utc();
} finally {
  privateJson('portal-capture-result.json', result);
  await context.close();
}
