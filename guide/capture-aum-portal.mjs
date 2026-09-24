/**
 * Live read-only Azure portal evidence. Uses a LOCAL COPY of the signed-in profile.
 * No deployment defaults, no login attempts, no unredacted PNGs written to disk.
 */
import { chromium } from 'playwright';
import { annotate } from './lib/annotate.mjs';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const args = process.argv.slice(2);
const option = name => { const index = args.indexOf(name); return index < 0 ? null : args[index + 1]; };
const config = option('--config');
if (!config) throw new Error('Pass --config <discovered AUM profile>. Run aum configure first.');
const python = option('--python') ?? path.resolve('.venv-finops', 'Scripts', 'python.exe');
const result = spawnSync(python, [path.resolve('cli', 'finops', 'tools', 'portal_context.py'), '--config', config],
  { encoding: 'utf8', timeout: 180000 });
if (result.status !== 0) throw new Error('Read-only portal target discovery failed. Verify AUM configure and Azure sign-in.');
const { targets, replacements } = JSON.parse(result.stdout);
const commit = spawnSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).stdout.trim();
const folder = path.resolve('docs', 'images', 'aum-portal');
const profile = path.resolve('.pw-profile');
const portal = (id, suffix = '') => `https://portal.azure.com/#@${targets.tenant_id}/resource${id}${suffix}`;
const steps = [
  { file: 'gateway-overview', title: 'Choose the existing API Management gateway', id: targets.apim_resource_id, suffix: '/overview' },
  { file: 'gateway-named-values', title: 'Read the connection, authority and limits', id: targets.apim_resource_id, suffix: '/namedValues' },
  { file: 'gateway-apis', title: 'Find the Claude API and its diagnostics', id: targets.apim_resource_id, suffix: '/apis' },
  { file: 'insights-overview', title: 'Find the linked Log Analytics workspace', id: targets.app_insights_resource_id, suffix: '/overview' },
  { file: 'workspace-overview', title: 'Read the discovered workspace identity', id: targets.workspace_resource_id, suffix: '/overview' },
  { file: 'workspace-logs', title: 'Open the live query editor', id: targets.workspace_resource_id, suffix: '/logs' },
  { file: 'turnstile-overview', title: 'Open the connected usage service', id: targets.turnstile_resource_id, suffix: '/overview' },
].filter(step => step.id);
const selected = option('--only');
const context = await chromium.launchPersistentContext(profile, {
  channel: 'msedge', headless: !args.includes('--headed'),
  viewport: { width: 1600, height: 1000 }, args: ['--no-first-run', '--no-default-browser-check'],
});
const images = [];
let authBlocked = false;
try {
  const page = context.pages()[0] ?? await context.newPage();
  for (const step of steps.filter(step => !selected || step.file === selected)) {
    await page.goto(portal(step.id, step.suffix), { waitUntil: 'domcontentloaded', timeout: 90000 });
    await page.waitForTimeout(12000);
    let body = await page.locator('body').innerText().catch(() => '');
    if (/login\.microsoftonline\.com|login\.live\.com|login\.windows\.net/i.test(page.url()) ||
        /Pick an account|Enter password|Sign in to your account/i.test(body) ||
        await page.locator('input[name="loginfmt"],input[name="passwd"]').count()) {
      authBlocked = true;
      console.log('STOP: copied portal profile requires sign-in. No sign-in attempted.');
      break;
    }
    const required = step.file === 'gateway-named-values' ? ['bu-registry']
      : step.file === 'gateway-apis' ? ['Add API', 'Add a new API', 'All APIs']
      : step.file === 'workspace-logs' ? ['New query', 'Run', 'Queries hub']
      : ['Essentials', 'Subscription ID', 'Subscription ID:'];
    try {
      await page.waitForFunction(markers => markers.some(marker => document.body.innerText.includes(marker)),
        required, { timeout: 90000 });
      await page.waitForTimeout(2500);
    } catch {
      if (/login\.microsoftonline\.com|login\.live\.com|login\.windows\.net/i.test(page.url())) {
        authBlocked = true;
        console.log('STOP: portal session expired while loading. No sign-in attempted.');
        break;
      }
      console.log(`NOT READY ${step.file}: resource data did not render; no screenshot saved.`);
      continue;
    }
    body = await page.locator('body').innerText().catch(() => '');
    if (/Pick an account|Enter password|Sign in to your account|Sign in again/i.test(body)) {
      authBlocked = true;
      console.log('STOP: portal requires sign-in. No sign-in attempted.');
      break;
    }
    if (/AuthorizationFailed|You do not have access|Resource not found/i.test(body)) {
      console.log(`REFUSED ${step.file}: portal did not expose this resource.`);
      continue;
    }
    await page.evaluate(({ replacements }) => {
      const replace = text => {
        for (const [value, substitute] of Object.entries(replacements).sort((a, b) => b[0].length - a[0].length)) {
          if (value && value !== substitute) text = text.split(value).join(substitute);
        }
        return text
          .replace(/[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g, 'admin@contoso.com')
          .replace(/\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b/gi, '[redacted-id]')
          .replace(/\b[A-Za-z0-9.-]+\.(?:azurewebsites\.net|azure-api\.net|onmicrosoft\.com)\b/gi, 'service.contoso.com');
      };
      const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
      let node;
      while ((node = walker.nextNode())) {
        if (['SCRIPT', 'STYLE'].includes(node.parentElement?.tagName)) continue;
        node.nodeValue = replace(node.nodeValue ?? '');
      }
      for (const input of document.querySelectorAll('input:not([type="password"]),textarea')) {
        input.value = replace(input.value ?? '');
      }
      for (const image of document.querySelectorAll('.ms-Persona-image,img[src*="/photo"]')) image.style.visibility = 'hidden';
    }, { replacements });
    const text = await page.locator('body').innerText();
    const fieldText = await page.locator('input:not([type="password"]),textarea').evaluateAll(
      inputs => inputs.map(input => input.value).join('\n'));
    const visible = text + '\n' + fieldText;
    const unsafe = /\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b/i.test(visible) ||
      /\b[A-Za-z0-9.-]+\.(?:azurewebsites\.net|azure-api\.net)\b/i.test(visible) ||
      [...visible.matchAll(/[A-Za-z0-9._+-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})/g)].some(match => match[1] !== 'contoso.com');
    if (unsafe) throw new Error(`Redaction guard rejected ${step.file}; no image saved.`);
    fs.mkdirSync(folder, { recursive: true });
    const filename = `${step.file}.png`;
    const pixels = await page.screenshot();
    const after = await page.locator('body').innerText();
    if (/\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b/i.test(after) ||
        /\b[A-Za-z0-9.-]+\.(?:azurewebsites\.net|azure-api\.net)\b/i.test(after) ||
        [...after.matchAll(/[A-Za-z0-9._+-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})/g)].some(match => match[1] !== 'contoso.com')) {
      throw new Error(`Portal redrew private values during ${step.file}; no image saved.`);
    }
    await annotate(pixels, path.join(folder, filename), {
      width: 1600, identity: { account: 'admin@contoso.com', tenant: 'CONTOSO' },
      banner: { title: step.title, note: 'LIVE Azure portal - values redacted; read-only capture' },
    });
    fs.writeFileSync(path.join(folder, `${step.file}.txt`), visible, 'utf8');
    images.push({ file: filename, text_file: `${step.file}.txt`, source: 'live', backend: 'Azure portal',
      captured_at: new Date().toISOString(), redaction: true, commit, title: step.title,
      sha256: createHash('sha256').update(fs.readFileSync(path.join(folder, filename))).digest('hex') });
    console.log(`LIVE ${step.file} captured with redaction.`);
  }
} finally {
  await context.close();
}
fs.mkdirSync(folder, { recursive: true });
const previous = fs.existsSync(path.join(folder, 'manifest.json'))
  ? JSON.parse(fs.readFileSync(path.join(folder, 'manifest.json'), 'utf8')).images : [];
const manifest = { schema: 1, source: 'live', auth_blocked: authBlocked,
  images: previous.filter(old => !images.some(image => image.file === old.file)).concat(images) };
fs.writeFileSync(path.join(folder, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
if (authBlocked || images.length !== steps.filter(step => !selected || step.file === selected).length) process.exitCode = 1;
