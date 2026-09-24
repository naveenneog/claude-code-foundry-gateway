// Copy the dedicated signed-in profile before running. The spec and bindings
// contain real resource IDs and belong in an ignored local evidence directory.
import { chromium } from 'playwright';
import fs from 'node:fs';
import path from 'node:path';
import { redactNetworkPage, redactNetworkText } from './lib/redact-network.mjs';

const argument = name => {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
};
const specPath = argument('--spec');
if (!specPath) throw new Error('Pass --spec with a local capture specification and redaction bindings.');
const spec = JSON.parse(fs.readFileSync(specPath, 'utf8').replace(/^\uFEFF/, ''));
const profile = path.resolve(argument('--profile') ?? '.pw-profile');
if (!profile.startsWith(process.cwd() + path.sep)) throw new Error('Use a copied profile inside this worktree, never the original.');
const output = path.resolve(argument('--out') ?? 'docs/guide');
const evidence = path.dirname(path.resolve(specPath));
const only = argument('--only')?.split(',');
fs.mkdirSync(output, { recursive: true });
const context = await chromium.launchPersistentContext(profile, {
  channel: 'msedge',
  headless: !process.argv.includes('--headed'),
  viewport: { width: 1680, height: 1100 },
  args: ['--no-first-run', '--no-default-browser-check'],
});
const results = [];
try {
  const page = context.pages()[0] ?? await context.newPage();
  for (const step of spec.steps.filter(s => !only || only.includes(s.id))) {
    const observedUtc = new Date().toISOString();
    const url = step.url ?? `https://portal.azure.com/#resource${step.resourceId}/${step.blade ?? 'overview'}`;
    if (!url.startsWith('https://portal.azure.com/')) throw new Error('Capture targets must be live Azure portal pages.');
    await page.goto(url, { waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(step.settleMs ?? 12000);
    let body = await page.locator('body').innerText();
    if (/login\.microsoftonline\.com/.test(page.url()) || /Pick an account|Enter password|Sign in to your account/.test(body)) {
      results.push({ id: step.id, observedUtc, state: 'auth-expired' });
      process.exitCode = 2;
      console.error('Portal session expired. Capture stopped; the owner must refresh the dedicated profile.');
      break;
    }
    for (const click of step.clicks ?? []) {
      if (click.role) await page.getByRole(click.role, { name: click.name, exact: click.exact ?? true }).filter({ visible: true }).first().click();
      else await page.getByText(click.text, { exact: click.exact ?? true }).filter({ visible: true }).first().click();
      await page.waitForTimeout(click.settleMs ?? 3000);
    }
    if (step.waitForText) {
      try { await page.getByText(step.waitForText, { exact: false }).filter({ visible: true }).first().waitFor({ state: 'visible', timeout: 45000 }); }
      catch {
        fs.writeFileSync(path.join(evidence, `${step.id}-miss.txt`), await page.locator('body').innerText());
        results.push({ id: step.id, observedUtc, state: 'missing-text' });
        process.exitCode = 1;
        continue;
      }
    }
    body = await page.locator('body').innerText();
    if (/Resource not found|Error loading blade|ErrorLoadingExtensionAndDefinition/.test(body)) {
      results.push({ id: step.id, observedUtc, state: 'blade-error' });
      process.exitCode = 1;
      continue;
    }
    fs.writeFileSync(path.join(evidence, `${step.id}-raw.txt`), body);
    await redactNetworkPage(page, spec.bindings);
    await page.evaluate(({ title, observedUtc }) => {
      const banner = document.createElement('div');
      banner.style.cssText = 'position:fixed;z-index:2147483647;bottom:0;left:0;right:0;background:#172b4d;color:#fff;padding:14px 24px;font:15px Segoe UI;border-top:4px solid #50e6ff';
      const heading = document.createElement('strong');
      heading.textContent = title;
      banner.append(heading, document.createElement('br'), document.createTextNode(`Live Azure portal | ${observedUtc} | Names, addresses and IDs replaced with Contoso examples`));
      document.body.append(banner);
    }, { title: step.title, observedUtc });
    const file = `${step.id}.png`;
    await page.screenshot({ path: path.join(output, file) });
    fs.writeFileSync(path.join(evidence, `${step.id}-redacted.txt`), redactNetworkText(await page.locator('body').innerText(), spec.bindings));
    results.push({ id: step.id, observedUtc, state: 'captured', file });
    console.log(`Captured ${file} (${observedUtc})`);
  }
} finally {
  await context.close();
  fs.writeFileSync(path.join(evidence, `capture-results-${Date.now()}.json`), JSON.stringify(results, null, 2));
}
