// Live Azure portal capture. Uses only this worktree's copied profile.
// Redacts identities before saving, and never persists a login page or a token.
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { chromium } from 'playwright';

const root = process.cwd();
const recordPath = process.env.AUM_CAPTURE_RECORD ?? path.join(root, 'onboarding', 'aum-service.json');
const record = JSON.parse(fs.readFileSync(recordPath, 'utf8').replace(/^\uFEFF/, ''));
const entra = JSON.parse(fs.readFileSync(path.join(root, '.aum-local', 'entra-app.json'), 'utf8').replace(/^\uFEFF/, ''));
const only = process.argv.slice(2).filter(x => !x.startsWith('-'));
const out = path.join(root, 'docs', 'guide');
const evidence = path.join(root, '.aum-local', 'portal');
fs.mkdirSync(out, { recursive: true });
fs.mkdirSync(evidence, { recursive: true });
const az = args => JSON.parse(execFileSync('az.cmd', [...args, '-o', 'json', '--only-show-errors'], {
  encoding: 'utf8', shell: true, windowsHide: true,
}));
const account = az(['account', 'show']);
const me = az(['ad', 'signed-in-user', 'show']);
const group = `/subscriptions/${record.subscriptionId}/resourceGroups/${record.resourceGroup}`;
const site = `${group}/providers/Microsoft.Web/sites/${record.functionName}`;
const storage = `${group}/providers/Microsoft.Storage/storageAccounts/${record.storageName}`;
const replacements = [
  [record.functionName, 'func-aum-contoso'], [record.storageName, 'staumcontoso'],
  [record.planName, 'plan-aum-contoso'], [record.resourceGroup, 'rg-aum-contoso'],
  [record.endpoint?.replace('https://', ''), 'func-aum-contoso.azurewebsites.net'],
  [record.gatewayResourceId?.split('/').at(-1), 'apim-contoso'],
  [record.gatewayResourceId?.split('/')[4], 'rg-gateway-contoso'],
  [record.workspaceResourceId?.split('/').at(-1), 'log-contoso'],
  [account.name, 'Contoso subscription'], [account.user?.name, 'admin@contoso.com'],
  [me.displayName, 'Contoso Administrator'], [me.userPrincipalName, 'admin@contoso.com'],
  [me.mail, 'admin@contoso.com'],
].filter(([a]) => a).sort((a, b) => b[0].length - a[0].length);
const steps = [
  ['aum-01-overview', `https://portal.azure.com/#resource${site}/overview`, 'Function overview', 'Running'],
  ['aum-02-identity', `https://portal.azure.com/#resource${site}/identity`, 'System-assigned managed identity', 'System assigned'],
  ['aum-03-scale', `https://portal.azure.com/#resource${site}/scaleAndConcurrency`, 'Flex capacity and cold-start choice', 'Always ready'],
  ['aum-04-storage', `https://portal.azure.com/#resource${storage}/configuration`, 'Storage: shared-key access disabled', 'Allow storage account key access'],
  ['aum-05-functions', `https://portal.azure.com/#resource${site}/functions`, 'HTTP API and expiry/warning timers', 'expire_boosts'],
  ['aum-06-app-roles', `https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/AppRoles/appId/${record.clientId}/isMSAApp~/false`, 'AUM Entra app roles', 'AUM.Admin'],
  ['aum-07-api-scope', `https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/ProtectAnAPI/appId/${record.clientId}/isMSAApp~/false`, 'Azure CLI pre-authorized for AUM.Access', 'AUM.Access'],
  ['aum-08-assignment', `https://portal.azure.com/#view/Microsoft_AAD_IAM/ManagedAppMenuBlade/~/Users/objectId/${entra.ServicePrincipalId}/appId/${record.clientId}`, 'Enterprise application assignments', 'AUM.Admin'],
];
const context = await chromium.launchPersistentContext(path.join(root, '.pw-profile'), {
  channel: 'msedge', headless: !process.argv.includes('--headed'),
  viewport: { width: 1600, height: 1060 },
  args: ['--no-first-run', '--no-default-browser-check'],
});
const page = context.pages()[0] ?? await context.newPage();
const receipts = [];
try {
  for (const [name, url, title, ready] of steps.filter(s => !only.length || only.includes(s[0]))) {
    const started = new Date().toISOString();
    await page.goto('about:blank');
    await page.goto(url, { waitUntil: 'domcontentloaded' });
    let matched = false;
    try {
      await page.waitForFunction(value => document.body?.innerText.includes(value), ready, { timeout: 75000 });
      await page.waitForTimeout(3500);
      matched = true;
    } catch {}
    const text = await page.locator('body').innerText();
    if (/login\.microsoftonline\.com/.test(page.url()) ||
        /Pick an account|Enter password|Approve sign in request|Sign in to your account|More information required/.test(text)) {
      throw new Error('SIGN-IN REQUIRED. Stopped without capturing. Tell the lead; never open the original profile.');
    }
    fs.writeFileSync(path.join(evidence, `${name}.txt`), text);
    if (!matched || /ErrorLoadingExtensionAndDefinition|Blade not found|We could not find/.test(text)) {
      receipts.push({ name, state: 'blade-unavailable', utc: started });
      console.log(`UNAVAILABLE ${name}: inspect private capture text before claiming a screenshot.`);
      continue;
    }
    await page.evaluate(({ replacements, title, timestamp }) => {
      const sanitize = value => {
        let result = value;
        for (const [from, to] of replacements) result = result.split(from).join(to);
        result = result.replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi,
          '00000000-0000-0000-0000-000000000000');
        result = result.replace(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi, 'admin@contoso.com');
        result = result.replace(/MICROSOFT NON-PRODUCTION[^()\n]*/gi, 'CONTOSO');
          result = result.replace(/[a-z0-9.-]+\.onmicrosoft\.com/gi, 'contoso.onmicrosoft.com');
        return result;
      };
      const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
      let node;
      while ((node = walker.nextNode())) {
        if (!['SCRIPT', 'STYLE'].includes(node.parentElement?.tagName)) node.textContent = sanitize(node.textContent);
      }
      for (const input of document.querySelectorAll('input,textarea')) input.value = sanitize(input.value);
      for (const element of document.querySelectorAll('[title],[aria-label]')) {
        for (const attr of ['title', 'aria-label']) if (element.hasAttribute(attr)) element.setAttribute(attr, sanitize(element.getAttribute(attr)));
      }
      // Account/tenant chip may use an image or initials rather than text.
      const mask = document.createElement('div');
      Object.assign(mask.style, { position: 'fixed', top: '0', right: '0', width: '330px', height: '52px',
        background: '#0078d4', color: '#fff', zIndex: '2147483647', padding: '10px', font: '14px Segoe UI' });
      mask.textContent = 'Contoso Administrator | CONTOSO';
      document.body.append(mask);
      const banner = document.createElement('div');
      Object.assign(banner.style, { position: 'fixed', bottom: '0', left: '0', right: '0', padding: '10px 24px',
        background: '#102a43', color: '#fff', zIndex: '2147483647', font: '16px Segoe UI' });
      banner.textContent = `${title} | Live portal ${timestamp} | Identities replaced with Contoso placeholders`;
      document.body.append(banner);
      // Detach React's original nodes so a late response cannot reintroduce
      // identifiers between the text audit and the pixel capture.
      document.body.replaceWith(document.body.cloneNode(true));
    }, { replacements, title, timestamp: started });
    const scrubbed = await page.locator('body').innerText();
    for (const [actual] of replacements) {
      if (actual.length > 3 && !actual.includes('contoso') && scrubbed.includes(actual)) {
        throw new Error(`Redaction incomplete in ${name}; no image saved.`);
      }
    }
    await page.screenshot({ path: path.join(out, `${name}.png`) });
    receipts.push({ name, state: 'captured-redacted', utc: started, file: `docs/guide/${name}.png` });
    console.log(`CAPTURED ${name}`);
  }
} finally {
  await context.close();
  fs.writeFileSync(path.join(evidence, 'receipts.json'), JSON.stringify(receipts, null, 2));
}
if (receipts.some(r => r.state !== 'captured-redacted')) process.exitCode = 2;
