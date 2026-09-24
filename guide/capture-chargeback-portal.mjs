// Read-only portal capture. Copy the approved profile first; never sign in here.
import { chromium } from 'playwright';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { resolve, dirname } from 'node:path';
import { reportRedactions, redactReportText, redactPortalPage, saveRedactedScreenshot, validateCaptureProfile } from './lib/chargeback-redaction.mjs';

const args = process.argv.slice(2);
const value = name => { const index = args.indexOf(name); return index < 0 ? undefined : args[index + 1]; };
const root = resolve(import.meta.dirname, '..');
const inventoryPath = value('--inventory');
if (!inventoryPath) throw new Error('Pass --inventory with the private JSON output of Get-ClaudeChargebackTarget.ps1 -Inventory -AsJson.');
const inventory = JSON.parse((await readFile(resolve(inventoryPath), 'utf8')).replace(/^\uFEFF/, ''));
if (!inventory.TenantId || !inventory.Resources?.length) throw new Error('The discovered inventory is incomplete.');
const profile = validateCaptureProfile(root, resolve(value('--profile') ?? resolve(root, '.pw-profile')));
const output = resolve(root, 'docs', 'images', 'chargeback-reports');
const evidence = resolve(root, '.chargeback-live', 'portal-captures.json');
const pairs = reportRedactions(inventory);
const resource = (type, match = () => true) => {
  const found = inventory.Resources.filter(item => item.type.toLowerCase() === type.toLowerCase() && match(item));
  if (found.length !== 1) throw new Error(`Expected one discovered ${type} resource, not ${found.length}. Refine the inventory.`);
  return found[0];
};
const storage = resource('Microsoft.Storage/storageAccounts');
const generator = resource('Microsoft.App/jobs', item => !/admin|mail/.test(item.name));
const dispatcher = resource('Microsoft.App/jobs', item => /mail/.test(item.name));
const admin = resource('Microsoft.App/jobs', item => /admin/.test(item.name));
const environment = resource('Microsoft.App/managedEnvironments');
const communication = resource('Microsoft.Communication/communicationServices');
const email = resource('Microsoft.Communication/emailServices');
const identity = resource('Microsoft.ManagedIdentity/userAssignedIdentities', item => !item.name.includes('admin'));
const network = resource('Microsoft.Network/virtualNetworks');
const endpoint = resource('Microsoft.Network/privateEndpoints');
const dns = resource('Microsoft.Network/privateDnsZones');
const steps = [
  { id: 'portal-storage', item: storage, expected: 'Storage account' },
  { id: 'portal-storage-network', item: storage, group: 'Security + networking', nav: 'Networking', expected: 'Network' },
  { id: 'portal-storage-protection', item: storage, group: 'Data management', nav: 'Data protection', expected: 'Data protection' },
  { id: 'portal-storage-retention', item: storage, group: 'Data management', nav: 'Lifecycle management', expected: 'Lifecycle' },
  { id: 'portal-storage-containers', item: storage, group: 'Data storage', nav: 'Containers', expected: 'Containers' },
  { id: 'portal-storage-settings-blob', item: storage, group: 'Data storage', nav: 'Containers', then: 'configuration', expected: 'configuration' },
  { id: 'portal-storage-archive', item: storage, group: 'Data storage', nav: 'Containers', then: 'reports', expected: 'reports' },
  { id: 'portal-generator', item: generator, expected: 'Job' },
  { id: 'portal-generator-schedule', item: generator, group: 'Settings', nav: 'Configuration', expected: 'Configuration' },
  { id: 'portal-generator-history', item: generator, nav: 'View', expected: 'Execution' },
  { id: 'portal-dispatcher', item: dispatcher, expected: 'Job' },
  { id: 'portal-dispatcher-rules', item: dispatcher, group: 'Settings', nav: 'Configuration', expected: 'Configuration' },
  { id: 'portal-event-scaling', item: dispatcher, group: 'Settings', nav: 'Event-driven scaling', expected: 'scaling' },
  { id: 'portal-admin', item: admin, expected: 'Job' },
  { id: 'portal-admin-containers', item: admin, group: 'Settings', nav: 'Containers', expected: 'Containers' },
  { id: 'portal-admin-environment', item: admin, group: 'Settings', nav: 'Containers', then: ['reports', 'Environment variables'], expected: 'Environment' },
  { id: 'portal-job-identity', item: generator, group: 'Settings', nav: 'Identity', expected: 'Identity' },
  { id: 'portal-environment', item: environment, expected: 'Container Apps Environment' },
  { id: 'portal-identity', item: identity, expected: 'Managed Identity' },
  { id: 'portal-identity-roles', item: identity, nav: 'Azure role assignments', expected: 'role' },
  { id: 'portal-network-subnets', item: network, group: 'Settings', nav: 'Subnets', expected: 'Subnets' },
  { id: 'portal-private-endpoint', item: endpoint, expected: 'Private endpoint' },
  { id: 'portal-dns-links', item: dns, group: 'DNS Management', nav: 'Virtual Network Links', expected: 'links' },
  { id: 'portal-email-service', item: email, expected: 'Email Communication' },
  { id: 'portal-email-domains', item: email, group: 'Settings', nav: 'Provision domains', expected: 'Domain' },
  { id: 'portal-communication', item: communication, expected: 'Communication Service' },
  { id: 'portal-connected-domain', item: communication, group: 'Email', nav: 'Domains', expected: 'Domain' },
];
const only = value('--only')?.split(',');
await mkdir(output, { recursive: true });
await mkdir(dirname(evidence), { recursive: true });
const context = await chromium.launchPersistentContext(profile, {
  channel: 'msedge', headless: !args.includes('--headed'), viewport: { width: 1600, height: 1000 },
  args: ['--no-first-run', '--no-default-browser-check'],
});
const results = [];
async function findControl(page, text) {
  for (let attempt = 0; attempt < 30; attempt++) {
    for (const frame of page.frames()) {
      const found = frame.getByText(text, { exact: true }).filter({ visible: true }).first();
      if (await found.count().catch(() => 0)) return found;
    }
    await page.waitForTimeout(500);
  }
  return null;
}
async function visibleText(page) {
  const chunks = [];
  for (const frame of page.frames()) {
    if (frame !== page.mainFrame()) {
      const box = await (await frame.frameElement()).boundingBox().catch(() => null);
      if (!box || box.width === 0 || box.height === 0) continue;
    }
    chunks.push(await frame.locator('body').innerText().catch(() => ''));
  }
  return chunks.join('\n');
}
try {
  const page = context.pages()[0] ?? await context.newPage();
  for (const step of steps.filter(item => !only || only.includes(item.id))) {
    const url = `https://portal.azure.com/#@${inventory.TenantId}/resource${step.item.id}`;
    await page.goto('about:blank');
    await page.goto(url, { waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(14000);
    const checkAuth = async () => {
      const text = await visibleText(page);
      if (/login\.microsoftonline|login\.live\.com/.test(page.url()) || /Sign in to your account|Pick an account|Enter password|Approve sign in request|Need admin approval/i.test(text)) {
        throw new Error('AUTH_REQUIRED: portal capture stopped; no sign-in attempted. Tell the lead.');
      }
      return text;
    };
    let text = await checkAuth();
    for (let attempt = 0; attempt < 20; attempt++) {
      const ready = await visibleText(page);
      if (ready.includes(step.item.name) && ready.includes('Subscription ID')) break;
      await page.waitForTimeout(500);
    }
    await page.waitForTimeout(1800);
    text = await checkAuth();
    if (step.nav) {
      if (step.group && await page.getByText(step.nav, { exact: true }).filter({ visible: true }).count() === 0) {
        const group = page.getByText(step.group, { exact: true }).filter({ visible: true }).first();
        if (await group.count()) { await group.click(); await page.waitForTimeout(600); }
      }
      const link = await findControl(page, step.nav);
      if (!link) {
        results.push({ id: step.id, state: 'missing-navigation', navigation: step.nav, utc: new Date().toISOString(), text: redactReportText(await page.locator('body').innerText(), pairs) });
        console.log(`MISS ${step.id}: navigation '${step.nav}' not found`);
        continue;
      }
      await link.click();
      await page.waitForTimeout(6500);
      text = await checkAuth();
      if (step.then) {
        for (const label of Array.isArray(step.then) ? step.then : [step.then]) {
          const control = await findControl(page, label);
          if (!control) throw new Error(`Missing live control: ${label}`);
          await control.click();
          await page.waitForTimeout(6500);
          text = await checkAuth();
        }
      }
    }
    if (!text.toLowerCase().includes(step.expected.toLowerCase()) || !text.includes(step.item.name) || /Resource not found|You do not have access/i.test(text)) {
      results.push({ id: step.id, state: 'unverified-blade', utc: new Date().toISOString(), text: redactReportText(text, pairs) });
      console.log(`MISS ${step.id}: expected blade not verified`);
      continue;
    }
    const runtimeUrl = page.url();
    await redactPortalPage(page, pairs);
    await saveRedactedScreenshot(page, resolve(output, `${step.id}.png`));
    results.push({ id: step.id, state: 'captured', utc: new Date().toISOString(), url: runtimeUrl, navigation: step.nav ?? 'Overview' });
    console.log(`OK ${step.id}`);
  }
} catch (error) {
  const page = context.pages()[0];
  const text = page ? redactReportText(await page.locator('body').innerText().catch(() => ''), pairs) : '';
  results.push({ state: 'stopped', reason: error.message, utc: new Date().toISOString(), text });
  process.exitCode = 1;
  console.error(error.message);
} finally {
  const previous = JSON.parse(await readFile(evidence, 'utf8').catch(() => '[]'));
  const replaced = new Set(results.map(item => item.id).filter(Boolean));
  await writeFile(evidence, JSON.stringify([...previous.filter(item => item.id && !replaced.has(item.id)), ...results], null, 2));
  await context.close();
}
if (results.some(item => item.state !== 'captured')) process.exitCode = 1;
