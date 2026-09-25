import fs from 'node:fs';
import path from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';

export const evidenceDir = path.resolve('.finops-evidence/p53');
export const outputDir = path.resolve('docs/guide');
export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
export const utc = () => new Date().toISOString();
const publicGuid = '04b07795-8ddb-461a-bbee-02f9e1bf7b46';
const guid = /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi;
const escape = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

export function requireEnvironment(...names) {
  for (const name of names) if (!process.env[name]?.trim()) throw new Error(`Set ${name}`);
}

export function ps(script, extraEnv = {}, expectedFailure = null) {
  const result = spawnSync('pwsh', ['-NoProfile', '-NonInteractive', '-Command',
    `$ErrorActionPreference='Stop'; $global:LASTEXITCODE=0; ${script}; if ($LASTEXITCODE) { exit $LASTEXITCODE }`], {
    encoding: 'utf8', env: { ...process.env, ...extraEnv },
    maxBuffer: 16 * 1024 * 1024, timeout: 15 * 60_000,
  });
  const stdout = (result.stdout ?? '').replace(/\x1b\[[0-9;]*m/g, '');
  const stderr = (result.stderr ?? '').replace(/\x1b\[[0-9;]*m/g, '');
  if (expectedFailure && result.status === 1 && expectedFailure.test(stderr))
    return `Exit code: 1 (expected safety refusal)\n${stdout}\n${stderr}`.trim();
  if (expectedFailure && result.status === 0) throw new Error('Expected safety refusal was not observed');
  if (result.status !== 0) {
    privateJson(`command-error-${Date.now()}.json`, {
      exit_code: result.status,
      error: stderr.replace(/eyJ[\w.-]+|Bearer\s+\S+|login_code=[\w-]+/g, '[credential omitted]'),
    });
    throw new Error(`PowerShell command failed (${result.status}); inspect the private command log`);
  }
  return stdout.trim();
}

export function az(args) {
  return ps('$ErrorActionPreference="Stop"; $a=@(ConvertFrom-Json $env:P53_AZ_ARGS); & az @a; if ($LASTEXITCODE) { exit $LASTEXITCODE }',
    { P53_AZ_ARGS: JSON.stringify(args) });
}

export function privateJson(name, value) {
  fs.mkdirSync(evidenceDir, { recursive: true });
  fs.writeFileSync(path.join(evidenceDir, name), JSON.stringify(value, null, 2));
}

// A distinctive private value - long, or a short random-looking suffix of letters and digits -
// also appears inside names derived from it (a storage account built from a deployment
// suffix), so it is matched anywhere. A short plain word keeps word boundaries, so a product
// word such as AUM is not rewritten inside another word.
function valuePattern(real) {
  const distinctive = real.length >= 8 || (real.length >= 6 && /\d/.test(real) && /[a-z]/i.test(real) && !/\s/.test(real));
  return distinctive ? escape(real) : `(?<![\\w])${escape(real)}(?![\\w])`;
}

export class Redactor {
  constructor(pairs = []) {
    this.pairs = pairs.filter(([real, fake]) => real && real !== fake)
      .sort((a, b) => b[0].length - a[0].length);
    // A replacement can happen to contain another private value (a replacement
    // "contoso-projection" contains a real "contoso-project"). Its own text is not a leak;
    // only these replacements are set aside before the check, so a common one cannot hide
    // a real value.
    this.shadowing = [...new Set(this.pairs.map(([, fake]) => fake))]
      .filter((fake) => fake && this.pairs.some(([real]) => new RegExp(valuePattern(real), 'i').test(fake)))
      .sort((a, b) => b.length - a.length);
  }

  rules() {
    return [
      ...this.pairs.map(([real, fake]) => [valuePattern(real), 'gi', fake]),
      ['[A-Za-z0-9._%+-]+#EXT#@[A-Za-z0-9.-]+', 'gi', 'developer_contoso.com#EXT#@contoso.onmicrosoft.com'],
      ['[A-Za-z0-9._%+-]+@(?!(?:contoso|example)\\.(?:com|onmicrosoft\\.com)\\b)[A-Za-z0-9.-]+\\.[A-Za-z]{2,}', 'gi', 'developer@contoso.com'],
      ['(?<=login_code=)[A-Za-z0-9_-]+', 'g', '[single-use-code-removed]'],
      ['C:\\\\Users\\\\[^\\\\\\s]+', 'gi', 'C:\\Users\\example'],
      ['\\b[a-z0-9-]+\\.(?:azurewebsites\\.net|azure-api\\.net|servicebus\\.windows\\.net|services\\.ai\\.azure\\.com|cognitiveservices\\.azure\\.com|vault\\.azure\\.net)\\b', 'gi', 'service.contoso.example'],
      ['(?<=/resourceGroups/)[^/\\s"]+', 'gi', 'rg-contoso'],
      ['\\b(?!contoso\\.)[a-z0-9-]+\\.onmicrosoft\\.com\\b', 'gi', 'contoso.onmicrosoft.com'],
    ];
  }

  redact(text) {
    let result = String(text);
    for (const [source, flags, replacement] of this.rules()) result = result.replace(new RegExp(source, flags), replacement);
    result = result.replace(guid, (value) => value.toLowerCase() === publicGuid ? value : '00000000-0000-0000-0000-000000000000');
    return result;
  }

  leaks(text) {
    const problems = [];
    const visible = this.shadowing.reduce((value, fake) => value.split(fake).join(' '), String(text));
    for (const [real] of this.pairs) if (new RegExp(valuePattern(real), 'i').test(visible)) problems.push('known identifier');
    if ([...text.matchAll(guid)].some(([g]) => g.toLowerCase() !== publicGuid && !g.startsWith('00000000-0000-0000-0000-'))) problems.push('object id');
    if (/[A-Za-z0-9._%+-]+@(?!(?:contoso|example)\.(?:com|onmicrosoft\.com)\b)[A-Za-z0-9.-]+\.[A-Za-z]{2,}/i.test(text)) problems.push('email');
    if (/eyJ[\w-]{12,}\.[\w-]+\.[\w-]+|login_code=[A-Za-z0-9_-]{20,}/.test(text)) problems.push('credential');
    if (/\b[a-z0-9-]+\.(?:azurewebsites\.net|azure-api\.net|servicebus\.windows\.net|services\.ai\.azure\.com|cognitiveservices\.azure\.com|vault\.azure\.net)\b/i.test(text))
      problems.push('deployment resource');
    return problems;
  }
}

export function catalogWrite(catalog) {
  return {
    organizations: catalog.organizations.map(({ id, name, external_ref, attributes }) => ({ id, name, external_ref, attributes })),
    departments: catalog.departments.map(({ id, name, parent_id, external_ref, attributes }) => ({ id, name, parent_id, external_ref, attributes })),
    default_department_id: catalog.default_department_id,
  };
}

export async function api(context, base, route, options = {}) {
  const response = await context.request.fetch(base + route, { timeout: 90_000, ...options });
  if (!response.ok()) throw new Error(`API ${route.split('?')[0]} returned ${response.status()}`);
  return response.status() === 204 ? null : response.json();
}

export async function cliSignIn(context, page, base, scope) {
  const started = Date.now();
  console.log('sign-in: requesting one-time CLI code');
  const link = ps('& ./scripts/Open-ClaudeTurnstile.ps1 -NoBrowser -TurnstileUrl $env:TURNSTILE_URL -Scope $env:TURNSTILE_SCOPE',
    { TURNSTILE_URL: base, TURNSTILE_SCOPE: scope }).split(/\r?\n/).find((line) => line.startsWith(base + '/?login_code='));
  if (!link) throw new Error('CLI helper returned no sign-in link');
  console.log('sign-in: redeeming code in browser (code not logged)');
  const code = new URL(link).searchParams.get('login_code');
  await page.goto(link, { waitUntil: 'domcontentloaded', timeout: 90_000 });
  await page.locator('.app-shell').waitFor({ timeout: 90_000 });
  if (page.url().includes('login_code')) throw new Error('Sign-in code was not removed from address');
  const profile = await api(context, base, '/api/v1/auth/me');
  console.log('sign-in: profile read from server');
  const replay = await context.request.post(base + '/api/v1/auth/code', { data: { code } });
  if (replay.status() !== 401) throw new Error('Used sign-in code was accepted twice');
  return { profile, seconds: (Date.now() - started) / 1000, replay_status: replay.status(), code_removed: true };
}

export function captureMetadata() {
  requireEnvironment('TURNSTILE_FORK_COMMIT');
  if (!/^[a-f0-9]{40}$/.test(process.env.TURNSTILE_FORK_COMMIT)) throw new Error('Fork commit must be a full verified SHA');
  return {
    accel_commit: execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(),
    fork_commit: process.env.TURNSTILE_FORK_COMMIT,
    tool: `Playwright ${JSON.parse(fs.readFileSync('node_modules/playwright/package.json')).version}`,
  };
}

export function recordCapture(image, pixels, source, redactor, metadata) {
  if (!source.route && !source.command) throw new Error('Capture needs a route or command');
  fs.mkdirSync(outputDir, { recursive: true });
  const manifestPath = path.join(outputDir, 'turnstile-captures.json');
  const manifest = fs.existsSync(manifestPath) ? JSON.parse(fs.readFileSync(manifestPath)) : { schema_version: 1, captures: [] };
  const entry = {
    image, live: true, captured_at_utc: utc(), ...metadata, ...source,
    redaction: { applied: true, leak_check_passed: true, rules: 'runtime identity/catalog/resource replacements; private emails and UUIDs; token/link rejection; photo avatars hidden' },
    sha256: createHash('sha256').update(pixels).digest('hex'),
  };
  // Metadata is public too. Refuse raw identities in a command/route or caption.
  if (redactor.leaks(JSON.stringify(entry)).length) throw new Error('Capture metadata contains a real identifier');
  fs.writeFileSync(path.join(outputDir, image), pixels);
  manifest.captures = [...manifest.captures.filter((item) => item.image !== image), entry]
    .sort((a, b) => a.image.localeCompare(b.image));
  fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + '\n');
  console.log(`captured ${image}`);
}

export function snapshotText(snapshot) {
  const result = [];
  const strings = snapshot.strings;
  for (const { nodes, layout } of snapshot.documents) {
    const rendered = new Set(layout.nodeIndex.filter((_, i) =>
      !layout.styles[i].some((style) => ['hidden', 'none'].includes(strings[style]))));
    const children = Array.from({ length: nodes.nodeType.length }, () => []);
    nodes.parentIndex.forEach((parent, i) => { if (parent >= 0) children[parent].push(i); });
    const combined = (i) => nodes.nodeType[i] === 3 ? strings[nodes.nodeValue[i]] : children[i].map(combined).join('');
    for (const i of rendered) {
      if (nodes.nodeType[i] === 3) result.push(strings[nodes.nodeValue[i]]);
      if (strings[nodes.nodeName[i]]?.toLowerCase() === 'text') result.push(combined(i));
      const attrs = nodes.attributes[i] ?? [];
      for (let a = 0; a < attrs.length; a += 2)
        if (['title', 'aria-label', 'placeholder'].includes(strings[attrs[a]])) result.push(strings[attrs[a + 1]]);
    }
    nodes.inputValue.index.forEach((node, i) => {
      if (rendered.has(node)) result.push(strings[nodes.inputValue.value[i]]);
    });
  }
  return result.join('\n');
}

export async function capturePixels(page, name, redactor, locator = null, recordDiagnostic = true) {
  for (const frame of page.frames()) await frame.evaluate(({ rules, publicGuid }) => {
    if (!document.body) return;
    const replace = (value) => {
      for (const [source, flags, to] of rules) value = value.replace(new RegExp(source, flags), to);
      return value.replace(/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi,
        (g) => g.toLowerCase() === publicGuid ? g : '00000000-0000-0000-0000-000000000000');
    };
      const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
      for (let node = walker.nextNode(); node; node = walker.nextNode()) {
        const value = replace(node.nodeValue);
        if (value !== node.nodeValue) node.nodeValue = value;
      }
      // Charts split an address across tspans; inspect the combined SVG label too.
      for (const label of document.querySelectorAll('svg text')) {
        const redacted = replace(label.textContent);
        if (redacted !== label.textContent) {
          const fragments = document.createTreeWalker(label, NodeFilter.SHOW_TEXT);
          let first = true;
          for (let node = fragments.nextNode(); node; node = fragments.nextNode()) {
            node.nodeValue = first ? redacted : '';
            first = false;
          }
        }
      }
      for (const input of document.querySelectorAll('input, textarea')) input.value = input.type === 'password' ? '' : replace(input.value);
      for (const element of document.querySelectorAll('[title], [aria-label], [placeholder]')) {
        for (const attribute of ['title', 'aria-label', 'placeholder']) {
          const value = element.getAttribute(attribute);
          if (value && value !== replace(value)) element.setAttribute(attribute, replace(value));
        }
      }
      for (const image of document.querySelectorAll('img')) image.style.visibility = 'hidden';
  }, { rules: redactor.rules(), publicGuid });
  const clip = locator ? await locator.boundingBox() : null;
  const cdp = await page.context().newCDPSession(page);
  const sessions = [cdp];
  for (const frame of page.frames().filter((frame) => frame !== page.mainFrame())) {
    try { sessions.push(await page.context().newCDPSession(frame)); }
    catch (error) {
      if (!String(error).includes('does not have a separate CDP session')) throw error;
    }
  }
  try {
    // Pause page scripts, not the backend. Check the rendered DOM after the pause and
    // rasterize that same state through CDP: a React refresh cannot restore identifiers
    // between the leak check and the photograph. Resume before any further interaction.
    for (const session of sessions) await session.send('Emulation.setScriptExecutionDisabled', { value: true });
    const text = (await Promise.all(sessions.map(async (session) =>
      snapshotText(await session.send('DOMSnapshot.captureSnapshot', { computedStyles: ['display', 'visibility'] }))))).join('\n');
    const findings = redactor.leaks(text);
    if (text.trim().length < 80) throw new Error(`Refusing ${name}: empty or incomplete page`);
    if (findings.length) {
      if (recordDiagnostic) privateJson('redaction-diagnostic.json', { image: name, findings });
      throw new Error(`Refusing ${name}: rendered DOM still contains a real value (${findings.join(', ')})`);
    }
    const screenshot = await cdp.send('Page.captureScreenshot', {
      format: 'png', fromSurface: true, captureBeyondViewport: !!clip,
      ...(clip ? { clip: { ...clip, scale: 1 } } : {}),
    });
    return Buffer.from(screenshot.data, 'base64');
  } finally {
    for (const session of sessions) {
      await session.send('Emulation.setScriptExecutionDisabled', { value: false });
      await session.detach();
    }
  }
}

export async function capturePage(page, name, source, redactor, metadata, locator = null) {
  const pixels = await capturePixels(page, name, redactor, locator);
  recordCapture(name, pixels, source, redactor, metadata);
}

export async function renderTranscript(page, name, title, body, source, redactor, metadata) {
  const safe = redactor.redact(body);
  if (redactor.leaks(safe).length) throw new Error(`Refusing ${name}: transcript redaction failed`);
  const htmlEscape = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  await page.setContent(`<html><head><style>
    body{margin:0;background:#11131a;color:#d6dae4;font:15px/1.6 Consolas,monospace}
    header{padding:14px 22px;background:#21242e;color:#b4c4e0}
    pre{padding:20px 24px;margin:0;white-space:pre-wrap;overflow-wrap:anywhere}
    main{width:1200px}
    </style></head><body><main><header>${htmlEscape(redactor.redact(title))}</header><pre>${htmlEscape(safe)}</pre></main></body></html>`);
  await capturePage(page, name, source, redactor, metadata, page.locator('main'));
}
