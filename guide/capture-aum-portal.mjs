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
import { selectCaptureSteps } from './lib/capture-steps.mjs';

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
const groupId = option('--group-id');
if (groupId) {
  if (!/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(groupId)) throw new Error('Pass a discovered group object id.');
  const groupProbe = spawnSync(python, [path.resolve('cli', 'finops', 'tools', 'portal_group_context.py'),
    '--config', config, '--group-id', groupId], { encoding: 'utf8', timeout: 180000 });
  if (groupProbe.status !== 0) throw new Error('Only the current administrator-owned, test-only group can be captured.');
  const verified = JSON.parse(groupProbe.stdout);
  const groupName = verified.group_name;
  replacements[groupName] = 'Contoso test security group';
  replacements[verified.owner_name] = 'Contoso administrator';
  targets.signed_in_display_name = verified.owner_name;
  for (const [part, title] of [['Overview', 'Verify the security group created by AUM'],
    ['Owners', 'Verify the signed-in administrator owns the test group'], ['Members', 'Verify the temporary test member']]) {
    steps.push({ file: `group-${part.toLowerCase()}`, title,
      url: `https://portal.azure.com/#@${targets.tenant_id}/view/Microsoft_AAD_IAM/GroupDetailsMenuBlade/~/${part}/groupId/${groupId}`,
      required: part === 'Overview' ? ['Security', groupName ?? 'Object Id'] : [targets.signed_in_display_name] });
  }
}
const selected = option('--only');
const selectedSteps = selectCaptureSteps(steps, selected);
const context = await chromium.launchPersistentContext(profile, {
  channel: 'msedge', headless: !args.includes('--headed'),
  viewport: { width: 1600, height: 1000 }, args: ['--no-first-run', '--no-default-browser-check'],
});
const images = [];
let authBlocked = false;

async function visibleFrames(page) {
  const frames = [];
  for (const frame of page.frames()) {
    try {
      if (frame === page.mainFrame() || await (await frame.frameElement()).isVisible()) frames.push(frame);
    } catch { /* A portal extension can replace its frame during navigation. */ }
  }
  return frames;
}

async function visibleText(page, fields = false) {
  const texts = [];
  for (const frame of await visibleFrames(page)) {
    texts.push(await frame.locator('body').innerText({ timeout: 1000 }).catch(() => ''));
    if (fields) texts.push(await frame.locator('input:not([type="password"]),textarea').evaluateAll(
      inputs => inputs.map(input => input.value).join('\n')).catch(() => ''));
  }
  return texts.join('\n');
}

try {
  const page = context.pages()[0] ?? await context.newPage();
  for (const step of selectedSteps) {
    await page.goto(step.url ?? portal(step.id), { waitUntil: 'domcontentloaded', timeout: 90000 });
    await page.waitForTimeout(12000);
    let body = await visibleText(page);
    if (/login\.microsoftonline\.com|login\.live\.com|login\.windows\.net/i.test(page.url()) ||
        /Pick an account|Enter password|Sign in to your account/i.test(body) ||
        await page.locator('input[name="loginfmt"],input[name="passwd"]').count()) {
      authBlocked = true;
      console.log('STOP: copied portal profile requires sign-in. No sign-in attempted.');
      break;
    }
    if (step.file === 'gateway-named-values' || step.file === 'gateway-apis') {
      const apis = page.getByText('APIs', { exact: true });
      const target = step.file === 'gateway-named-values'
        ? page.getByText('Named values', { exact: true }).first()
        : page.locator('[data-telemetryname="Menu-apim-apis"]');
      if (!await target.isVisible().catch(() => false)) {
        await apis.first().click({ timeout: 30000 });
        await page.waitForTimeout(1500);
      }
      await target.click({ timeout: 30000 });
    }
    if (step.file === 'workspace-logs') {
      const logs = page.getByText('Logs', { exact: true });
      if (!await logs.first().isVisible().catch(() => false)) {
        const general = page.getByText('General', { exact: true });
        if (await general.count()) await general.first().click();
      }
      await logs.first().click({ timeout: 30000 });
    }
    const required = step.required ?? (step.file === 'gateway-named-values' ? ['bu-registry']
      : step.file === 'gateway-apis' ? [targets.api_display_name ?? 'claude-foundry']
      : step.file === 'workspace-logs' ? ['New query', 'Run', 'Queries hub']
      : step.file === 'turnstile-overview' ? ['Essentials', 'Default domain', 'Operating System']
      : ['Essentials', 'Subscription ID', 'Subscription ID:', 'Workspace ID']);
    try {
      const deadline = Date.now() + 90000;
      let ready = false;
      while (Date.now() < deadline) {
        const content = await visibleText(page);
        if (step.file === 'turnstile-overview' && /Welcome to the App Service preview/i.test(content)) {
          for (const frame of await visibleFrames(page)) {
            const start = frame.getByRole('button', { name: 'Get started', exact: true }).first();
            if (await start.isVisible().catch(() => false)) await start.click();
          }
          await page.waitForTimeout(1500);
          continue;
        }
        if (step.file === 'workspace-logs') {
          for (const frame of await visibleFrames(page)) {
            const text = await frame.locator('body').innerText({ timeout: 1000 }).catch(() => '');
            if (!/New\s+Query/i.test(text)) continue;
            for (const toggle of await frame.getByRole('switch').all()) {
              const checked = await toggle.evaluate(element => element.checked === true || element.getAttribute('aria-checked') === 'true');
              if (checked) {
                await toggle.evaluate(element => element.click());
                await page.waitForTimeout(1000);
              }
            }
            const useQuery = frame.getByText('Use Query', { exact: true }).first();
            if (await useQuery.isVisible().catch(() => false)) await useQuery.click();
            const simple = frame.getByText('Simple mode', { exact: true }).first();
            if (await simple.isVisible().catch(() => false)) {
              await simple.click();
              const kql = frame.getByText('KQL mode', { exact: true }).first();
              if (await kql.isVisible().catch(() => false)) await kql.click();
            }
            if (await frame.locator('.monaco-editor').first().isVisible().catch(() => false) &&
                /\bRun\b/.test(text)) ready = true;
          }
          if (ready) break;
        }
        if (step.file === 'workspace-logs' && content.includes('Welcome to Log Analytics')) {
          for (const frame of await visibleFrames(page)) {
            const text = await frame.locator('body').innerText({ timeout: 1000 }).catch(() => '');
            if (!text.includes('Welcome to Log Analytics')) continue;
            const close = frame.locator('[aria-label*="close" i],[title*="close" i]').first();
            if (await close.isVisible().catch(() => false)) {
              await close.click();
            } else {
              await frame.getByText('Welcome to Log Analytics', { exact: true }).click();
              await page.keyboard.press('Escape');
            }
          }
          await page.waitForTimeout(1000);
          continue;
        }
        if (step.file !== 'workspace-logs' &&
            (step.required ? required.every(marker => content.toLowerCase().includes(marker.toLowerCase()))
              : required.some(marker => content.toLowerCase().includes(marker.toLowerCase())))) { ready = true; break; }
        if (/Pick an account|Enter password|Sign in to your account|Sign in again/i.test(content)) {
          authBlocked = true;
          break;
        }
        await page.waitForTimeout(1000);
      }
      if (!ready) throw new Error('Resource frame not ready');
      await page.waitForTimeout(2500);
      if (step.file === 'workspace-logs') {
        const query = 'ClaudeCost(startofmonth(now()), now())\n'
          + '| summarize tokens=sum(prompt_tokens + completion_tokens), requests=sum(requests), cache_read_tokens=sum(cache_read_tokens), estimated_usd=sum(usd), unpriced=countif(not(priced_ok)) by business_unit\n'
          + '| extend estimated_usd=iff(unpriced > 0, real(null), estimated_usd)';
        let editorFrame;
        for (const candidate of await visibleFrames(page)) {
          if (await candidate.locator('.monaco-editor textarea').first().isVisible().catch(() => false)) {
            editorFrame = candidate;
            break;
          }
        }
        if (!editorFrame) throw new Error('Visible KQL editor not found');
        await editorFrame.locator('.monaco-editor textarea').first().focus();
        await page.keyboard.press('Control+A');
        await page.keyboard.insertText(query);
        const reply = page.waitForResponse(response => response.request().method() === 'POST'
          && /loganalytics/i.test(response.url()) && /\/query(?:\?|$)/i.test(response.url()), { timeout: 90000 }).catch(() => null);
        await editorFrame.getByText('Run', { exact: true }).first().click();
        const response = await reply;
        if (!response) throw new Error('No Log Analytics query response was observed');
        const payload = await response.json();
        const rows = payload.tables?.reduce((count, table) => count + (table.rows?.length ?? 0), 0) ?? 0;
        if (!response.ok() || !rows) throw new Error('KQL returned no verified result rows');
        step.query_verified = true;
        step.query_rows = rows;
        await page.waitForTimeout(3000);
      }
    } catch {
      if (authBlocked) {
        console.log('STOP: a visible portal frame requires sign-in. No sign-in attempted.');
        break;
      }
      if (/login\.microsoftonline\.com|login\.live\.com|login\.windows\.net/i.test(page.url())) {
        authBlocked = true;
        console.log('STOP: portal session expired while loading. No sign-in attempted.');
        break;
      }
      console.log(`NOT READY ${step.file}: resource data did not render; no screenshot saved.`);
      let diagnostic = await visibleText(page);
      for (const [value, substitute] of Object.entries(replacements).sort((a, b) => b[0].length - a[0].length)) {
        if (value) diagnostic = diagnostic.split(value).join(substitute);
      }
      diagnostic = diagnostic.replace(/[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g, 'admin@contoso.com')
        .replace(/\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b/gi, '[redacted-id]')
        .replace(/https?:\/\/[^\s]+/g, 'https://service.contoso.com');
      fs.mkdirSync(path.resolve('.aum-evidence'), { recursive: true });
      fs.writeFileSync(path.resolve('.aum-evidence', `portal-not-ready-${step.file}.txt`), diagnostic);
      continue;
    }
    body = await visibleText(page);
    if (/Pick an account|Enter password|Sign in to your account|Sign in again/i.test(body)) {
      authBlocked = true;
      console.log('STOP: portal requires sign-in. No sign-in attempted.');
      break;
    }
    if (/AuthorizationFailed|You do not have access|Resource not found/i.test(body)) {
      console.log(`REFUSED ${step.file}: portal did not expose this resource.`);
      continue;
    }
    for (const frame of await visibleFrames(page)) await frame.evaluate(({ replacements, main, groupPage }) => {
      const replace = text => {
        for (const [value, substitute] of Object.entries(replacements).sort((a, b) => b[0].length - a[0].length)) {
          if (value && value !== substitute) text = text.split(value).join(substitute);
        }
        return text
          .replace(/[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g, 'admin@contoso.com')
          .replace(/\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b/gi, '[redacted-id]')
          .replace(/\b[0-9a-f]{32}\b/gi, '[redacted-id]')
          .replace(/https?:\/\/[A-Za-z0-9._-]+(?::\d+)?/gi, 'https://service.contoso.com')
          .replace(/\b[A-Za-z0-9.-]+\.(?:azurewebsites\.net|azure-api\.net|onmicrosoft\.com)\b/gi, 'service.contoso.com');
      };
      const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
      let node;
      while ((node = walker.nextNode())) {
        if (['SCRIPT', 'STYLE'].includes(node.parentElement?.tagName)) continue;
        const range = document.createRange();
        range.selectNodeContents(node);
        const box = range.getBoundingClientRect();
        node.nodeValue = main && box.top < 60 && box.left > window.innerWidth - 350
          ? ((node.nodeValue ?? '').includes('@') ? 'admin@contoso.com' : 'Contoso directory')
          : replace(node.nodeValue ?? '');
      }
      for (const input of document.querySelectorAll('input:not([type="password"]),textarea')) {
        input.value = replace(input.value ?? '');
      }
      for (const image of document.querySelectorAll('.ms-Persona-image,img[src*="/photo"]')) image.style.visibility = 'hidden';
      if (groupPage) for (const image of document.querySelectorAll('img,.ms-Persona-initials,.fui-Avatar')) image.style.visibility = 'hidden';
    }, { replacements, main: frame === page.mainFrame(), groupPage: step.file.startsWith('group-') });
    const visible = await visibleText(page, true);
    const unsafe = /\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b/i.test(visible) ||
      /\b[A-Za-z0-9.-]+\.(?:azurewebsites\.net|azure-api\.net)\b/i.test(visible) ||
      [...visible.matchAll(/[A-Za-z0-9._+-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})/g)].some(match => match[1] !== 'contoso.com');
    if (unsafe) throw new Error(`Redaction guard rejected ${step.file}; no image saved.`);
    fs.mkdirSync(folder, { recursive: true });
    const filename = `${step.file}.png`;
    const pixels = await page.screenshot();
    const after = await visibleText(page, true);
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
      ...(step.query_verified ? { query_verified: true, query_rows: step.query_rows } : {}),
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
if (authBlocked || images.length !== selectedSteps.length) process.exitCode = 1;
