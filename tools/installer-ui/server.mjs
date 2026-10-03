import { createServer as createHttpServer } from 'node:http';
import { spawn } from 'node:child_process';
import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { mkdtemp, readFile, rm, writeFile, chmod } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '..', '..');
const schemaPath = join(root, 'schemas', 'claude-gateway.answers.schema.json');
const redactionPath = join(root, 'scripts', 'ClaudeInstallResume.ps1');
const psInstaller = join(root, 'Install-ClaudeGateway.ps1');
const bashInstaller = join(root, 'install-claude-gateway.sh');
const defaultIdleMs = 30 * 60 * 1000;
const maxBodyBytes = 256 * 1024;

let redactionRules;

export async function loadSchema() {
  return JSON.parse(await readFile(schemaPath, 'utf8'));
}

export async function loadRedactionRules() {
  if (redactionRules) return redactionRules;
  const source = await readFile(redactionPath, 'utf8');
  const match = source.match(/^\s*\$json = '(\[[^']*\])'/m);
  if (!match) throw new Error('redaction rules not found in scripts/ClaudeInstallResume.ps1');
  redactionRules = JSON.parse(match[1]).map((rule) => ({
    name: rule.name,
    regex: new RegExp(rule.pattern, 'gi'),
  }));
  return redactionRules;
}

export async function redactText(text) {
  let output = String(text ?? '');
  for (const rule of await loadRedactionRules()) {
    output = output.replace(rule.regex, (...args) => {
      const groups = args.at(-1);
      return `${groups?.keep ?? ''}[redacted]`;
    });
  }
  return output;
}

export function buildCommands(answersPath = '.\\answers.json', schema = null) {
  const ps = `.\\Install-ClaudeGateway.ps1 -AnswersPath ${quotePowerShell(answersPath)} -Preflight -Json`;
  const runPs = `.\\Install-ClaudeGateway.ps1 -AnswersPath ${quotePowerShell(answersPath)} -Yes -ProgressPath .\\install-progress.ndjson`;
  const bashPath = answersPath.replaceAll('\\', '/');
  const bash = `./install-claude-gateway.sh --answers-file ${quoteBash(bashPath)} --preflight --json`;
  const bashRun = `./install-claude-gateway.sh --answers-file ${quoteBash(bashPath)} --yes --progress-file ./install-progress.ndjson`;
  const unsupported = [];
  if (schema?.properties) {
    for (const [name, property] of Object.entries(schema.properties)) {
      if (Array.isArray(property['x-appliedBy']) && !property['x-appliedBy'].includes('install-claude-gateway.sh')) {
        unsupported.push(name);
      }
    }
  }
  return { powershell: ps, powershellRun: runPs, bash, bashRun, bashDoesNotApply: unsupported };
}

function quotePowerShell(value) {
  return `'${String(value).replaceAll("'", "''")}'`;
}

function quoteBash(value) {
  return `'${String(value).replaceAll("'", "'\"'\"'")}'`;
}

function tokenHash(token) {
  return createHash('sha256').update(token).digest();
}

function constantTimeTokenEquals(actual, expectedHash) {
  if (!actual) return false;
  const actualHash = tokenHash(actual);
  return actualHash.length === expectedHash.length && timingSafeEqual(actualHash, expectedHash);
}

function parseCookies(header) {
  const cookies = new Map();
  for (const part of String(header || '').split(';')) {
    const index = part.indexOf('=');
    if (index > 0) cookies.set(part.slice(0, index).trim(), decodeURIComponent(part.slice(index + 1).trim()));
  }
  return cookies;
}

function contentSecurityPolicy() {
  return "default-src 'self'; base-uri 'none'; object-src 'none'; frame-ancestors 'none'; form-action 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'";
}

function send(res, status, body, headers = {}) {
  const text = typeof body === 'string' ? body : JSON.stringify(body);
  res.writeHead(status, {
    'content-type': typeof body === 'string' && body.startsWith('<!doctype') ? 'text/html; charset=utf-8' : 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(text),
    'content-security-policy': contentSecurityPolicy(),
    'x-content-type-options': 'nosniff',
    'referrer-policy': 'no-referrer',
    ...headers,
  });
  res.end(text);
}

function isAllowedHost(host, port, extraHosts = []) {
  const value = String(host || '').toLowerCase();
  const allowed = new Set([
    `127.0.0.1:${port}`,
    `localhost:${port}`,
    `[::1]:${port}`,
    ...extraHosts.map((h) => h.toLowerCase()),
  ]);
  return allowed.has(value);
}

async function readJsonBody(req) {
  let total = 0;
  const chunks = [];
  for await (const chunk of req) {
    total += chunk.length;
    if (total > maxBodyBytes) {
      const error = new Error('request body is too large');
      error.status = 413;
      throw error;
    }
    chunks.push(chunk);
  }
  const raw = Buffer.concat(chunks).toString('utf8');
  if (!raw) return {};
  try {
    return JSON.parse(raw);
  } catch {
    const error = new Error('request body is not valid JSON');
    error.status = 400;
    throw error;
  }
}

async function withRunDirectory(fn, tempDirs) {
  const dir = await mkdtemp(join(tmpdir(), 'claude-installer-ui-'));
  tempDirs.add(dir);
  try {
    try { await chmod(dir, 0o700); } catch { /* Windows ACLs are inherited; the directory is still per-run. */ }
    return await fn(dir);
  } finally {
    tempDirs.delete(dir);
    await rm(dir, { recursive: true, force: true });
  }
}

function spawnInstallerArgs(kind, args, options) {
  const stub = options.stubInstaller || process.env.CLAUDE_INSTALLER_UI_STUB;
  if (stub) return { file: process.execPath, args: [stub, kind, ...args] };
  if (kind === 'powershell') return { file: 'pwsh', args: ['-NoProfile', '-NonInteractive', '-File', psInstaller, ...args] };
  return { file: 'bash', args: [bashInstaller, ...args] };
}

async function runInstaller(kind, args, options) {
  const command = spawnInstallerArgs(kind, args, options);
  const child = spawn(command.file, command.args, {
    cwd: root,
    shell: false,
    windowsHide: true,
    env: { ...process.env, ...(options.env || {}) },
  });
  let stdout = '';
  let stderr = '';
  child.stdout.on('data', (chunk) => { stdout += chunk.toString('utf8'); });
  child.stderr.on('data', (chunk) => { stderr += chunk.toString('utf8'); });
  const code = await new Promise((resolveCode, reject) => {
    child.on('error', reject);
    child.on('close', resolveCode);
  });
  return { code, stdout: await redactText(stdout), stderr: await redactText(stderr) };
}

async function listSteps(options) {
  const result = await runInstaller('powershell', ['-ListSteps', '-Json'], options);
  if (result.code !== 0) throw new Error(`step list failed: ${result.stderr || result.stdout}`);
  return JSON.parse(result.stdout);
}

function flattenStepIds(stepPayload) {
  const steps = Array.isArray(stepPayload) ? stepPayload : Array.isArray(stepPayload.steps) ? stepPayload.steps : [];
  return new Set(steps.map((step) => String(step.id || step.stepId || '')).filter(Boolean));
}

async function writeAnswers(dir, answers) {
  const path = join(dir, 'answers.json');
  await writeFile(path, `${JSON.stringify(answers ?? {}, null, 2)}\n`, { encoding: 'utf8', mode: 0o600 });
  return path;
}

function renderHtml() {
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Claude gateway installer</title>
  <style>
    body { font-family: system-ui, sans-serif; margin: 2rem; max-width: 1100px; }
    header { border: 1px solid #ccd; border-radius: 0.75rem; padding: 1rem; background: #f7f9ff; }
    section { border-top: 1px solid #ddd; margin-top: 1.5rem; padding-top: 1rem; }
    label { display: grid; gap: 0.25rem; margin: 0.75rem 0; }
    input, select, textarea, button { font: inherit; padding: 0.45rem; }
    .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); gap: 0.75rem 1rem; }
    pre { background: #111827; color: #f9fafb; padding: 1rem; overflow: auto; border-radius: 0.5rem; }
    .small { color: #475569; font-size: 0.9rem; }
  </style>
</head>
<body>
  <header>
    <h1>Claude gateway installer</h1>
    <p id="identity">Signed-in account: read-only checks use the Azure CLI session in this terminal.</p>
    <p class="small">Cloud Shell ends a session after 20 minutes without interactive activity. Keep the shell active before long waits.</p>
  </header>
  <main>
    <section><h2>Prerequisites</h2><button id="preflight">Run preflight</button><pre id="preflight-output"></pre></section>
    <section><h2>Foundation</h2><div id="foundation" class="grid"></div></section>
    <section><h2>Access</h2><div id="access" class="grid"></div></section>
    <section><h2>Optional parts</h2><div id="optional" class="grid"></div></section>
    <section><h2>Business units and teams</h2><textarea id="business-units" rows="8" cols="80" placeholder='[{"id":"finance","group":"claude-bu-finance","monthlyUsdBudget":5000,"mode":"Strict"}]'></textarea></section>
    <section><h2>Review</h2><button id="download">Download answers.json</button><pre id="commands"></pre></section>
    <section><h2>Run</h2><button id="steps">List steps</button><div id="step-list"></div><button id="run">Run selected steps</button><button id="rerun">Re-run failed step</button><pre id="run-output"></pre></section>
  </main>
  <script>
    const answers = {};
    let lastFailedStep = '';
    const groups = {
      foundation: ['SubscriptionId','FoundryAccount','FoundryResourceGroup','ResourceGroup','Location','NamePrefix','PublisherEmail','Sku'],
      access: ['StandardGroup','PremiumGroup','TpmStandard','QuotaStandard','TpmPremium','QuotaPremium','QuotaOrg','CallsPerMinute','StandardModels','PremiumModels'],
      optional: ['AddressMode','AddressHostname','AddressCertificateSource','AddressKeyVaultCertificateId','AddressPfxPath','AddressDnsMode','DesktopSignInKind','DesktopEntraClientId','DeployProjection','EntitlementStore','monitoring.enabled','reports.enabled']
    };
    function valueFor(name, schema) {
      if (schema.type === 'integer' || schema.type === 'number') return Number(document.querySelector('[name="' + CSS.escape(name) + '"]')?.value || 0);
      if (schema.type === 'boolean') return Boolean(document.querySelector('[name="' + CSS.escape(name) + '"]')?.checked);
      if (schema.type === 'array') return String(document.querySelector('[name="' + CSS.escape(name) + '"]')?.value || '').split(',').map(x => x.trim()).filter(Boolean);
      return document.querySelector('[name="' + CSS.escape(name) + '"]')?.value || '';
    }
    function collect(schema) {
      const out = { schemaVersion: 1 };
      for (const [name, property] of Object.entries(schema.properties)) {
        const field = document.querySelector('[name="' + CSS.escape(name) + '"]');
        if (field && (field.type === 'checkbox' || field.value !== '')) out[name] = valueFor(name, property);
      }
      const bu = document.getElementById('business-units').value.trim();
      if (bu) out.BusinessUnits = JSON.parse(bu);
      return out;
    }
    function renderField(parent, name, property) {
      const label = document.createElement('label');
      label.textContent = property.title || name;
      const field = property.enum ? document.createElement('select') : document.createElement('input');
      field.name = name;
      if (property.enum) for (const item of property.enum) { const o = document.createElement('option'); o.value = item; o.textContent = item; field.append(o); }
      else if (property.type === 'integer' || property.type === 'number') field.type = 'number';
      else if (property.type === 'boolean') field.type = 'checkbox';
      else field.type = 'text';
      if (property.pattern) field.pattern = property.pattern;
      label.append(field);
      if (property['x-remedy']) { const s = document.createElement('span'); s.className = 'small'; s.textContent = property['x-remedy']; label.append(s); }
      parent.append(label);
    }
    async function postJson(path, body) {
      const res = await fetch(path, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
      const text = await res.text();
      let data; try { data = JSON.parse(text); } catch { data = { text }; }
      if (!res.ok) throw new Error(data.error || text);
      return data;
    }
    (async () => {
      const schema = await (await fetch('./api/schema')).json();
      for (const [section, names] of Object.entries(groups)) {
        const parent = document.getElementById(section);
        for (const name of names) if (schema.properties[name]) renderField(parent, name, schema.properties[name]);
      }
      document.getElementById('commands').textContent = JSON.stringify((await postJson('./api/commands', { answersPath: './answers.json' })), null, 2);
      document.getElementById('preflight').onclick = async () => { document.getElementById('preflight-output').textContent = JSON.stringify(await postJson('./api/preflight', { answers: collect(schema) }), null, 2); };
      document.getElementById('steps').onclick = async () => {
        const payload = await (await fetch('./api/steps')).json();
        const steps = Array.isArray(payload) ? payload : payload.steps;
        document.getElementById('step-list').innerHTML = steps.map(s => '<label><input type="checkbox" value="' + s.id + '"> ' + s.id + ' - ' + (s.title || '') + '</label>').join('');
      };
      document.getElementById('run').onclick = async () => {
        const stepIds = [...document.querySelectorAll('#step-list input:checked')].map(x => x.value);
        const result = await postJson('./api/run', { answers: collect(schema), steps: stepIds });
        lastFailedStep = result.failedStepId || '';
        document.getElementById('run-output').textContent = JSON.stringify(result, null, 2);
      };
      document.getElementById('rerun').onclick = async () => {
        const result = await postJson('./api/run', { answers: collect(schema), steps: lastFailedStep ? [lastFailedStep] : [] });
        document.getElementById('run-output').textContent = JSON.stringify(result, null, 2);
      };
      document.getElementById('download').onclick = () => {
        const blob = new Blob([JSON.stringify(collect(schema), null, 2) + '\\n'], { type: 'application/json' });
        const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = 'answers.json'; a.click(); URL.revokeObjectURL(a.href);
      };
    })().catch(err => { document.body.insertAdjacentHTML('beforeend', '<pre>' + err.message + '</pre>'); });
  </script>
</body>
</html>`;
}

export async function createInstallerUiServer(options = {}) {
  const token = options.token || randomBytes(32).toString('base64url');
  const tokenDigest = tokenHash(token);
  const tempDirs = new Set();
  let port = Number(options.port || 0);
  let activeRun = null;
  let idleTimer = null;
  const idleMs = Number(options.idleMs || defaultIdleMs);
  const extraHosts = options.allowedHosts || [];

  const server = createHttpServer(async (req, res) => {
    try {
      if (!isAllowedHost(req.headers.host, port, extraHosts)) return send(res, 403, { error: 'host header is not allowed' });
      if (req.method === 'OPTIONS') return send(res, 405, { error: 'OPTIONS is not allowed' });
      const url = new URL(req.url, `http://${req.headers.host}`);
      const queryToken = url.searchParams.get('token');
      const cookies = parseCookies(req.headers.cookie);
      const supplied = req.headers['x-installer-token'] || cookies.get('installer_token') || queryToken;
      if (!constantTimeTokenEquals(String(supplied || ''), tokenDigest)) return send(res, 401, { error: 'installer token is required' });
      const setCookie = queryToken && constantTimeTokenEquals(queryToken, tokenDigest)
        ? { 'set-cookie': `installer_token=${encodeURIComponent(queryToken)}; HttpOnly; SameSite=Strict; Path=/` }
        : {};

      if (req.method === 'GET' && (url.pathname === '/' || url.pathname === '/index.html')) return send(res, 200, renderHtml(), setCookie);
      if (req.method === 'GET' && url.pathname === '/api/schema') return send(res, 200, await loadSchema(), setCookie);
      if (req.method === 'GET' && url.pathname === '/api/steps') return send(res, 200, await listSteps(options), setCookie);
      if (req.method === 'POST' && url.pathname === '/api/commands') {
        const body = await readJsonBody(req);
        return send(res, 200, buildCommands(body.answersPath || './answers.json', await loadSchema()), setCookie);
      }
      if (req.method === 'POST' && url.pathname === '/api/preflight') {
        const body = await readJsonBody(req);
        return send(res, 200, await withRunDirectory(async (dir) => {
          const answers = await writeAnswers(dir, body.answers || {});
          const result = await runInstaller('powershell', ['-AnswersPath', answers, '-Preflight', '-Json'], options);
          let parsed;
          try { parsed = JSON.parse(result.stdout); } catch { parsed = null; }
          return { exitCode: result.code, preflight: parsed, stdout: result.stdout, stderr: result.stderr };
        }, tempDirs), setCookie);
      }
      if (req.method === 'POST' && url.pathname === '/api/run') {
        if (activeRun) return send(res, 409, { error: 'an installer run is already active' }, setCookie);
        const body = await readJsonBody(req);
        activeRun = {};
        try {
          const result = await withRunDirectory(async (dir) => {
            const steps = Array.isArray(body.steps) ? body.steps.map(String) : [];
            const allowed = flattenStepIds(await listSteps(options));
            const injected = steps.filter((step) => !allowed.has(step));
            if (injected.length) {
              const error = new Error(`unknown step id: ${injected.join(', ')}`);
              error.status = 400;
              throw error;
            }
            const answers = await writeAnswers(dir, body.answers || {});
            const progress = join(dir, 'progress.ndjson');
            const args = ['-AnswersPath', answers, '-Yes', '-ProgressPath', progress];
            if (steps.length) args.push('-Steps', steps.join(','));
            const run = await runInstaller('powershell', args, options);
            let progressText = '';
            if (existsSync(progress)) progressText = await redactText(await readFile(progress, 'utf8'));
            const events = progressText.trim() ? progressText.trim().split(/\r?\n/).map((line) => JSON.parse(line)) : [];
            const failed = events.findLast?.((event) => event.event === 'failed') || [...events].reverse().find((event) => event.event === 'failed');
            return { exitCode: run.code, stdout: run.stdout, stderr: run.stderr, events, failedStepId: failed?.stepId || '' };
          }, tempDirs);
          return send(res, 200, result, setCookie);
        } finally {
          activeRun = null;
        }
      }
      return send(res, 404, { error: 'route not found' }, setCookie);
    } catch (error) {
      return send(res, error.status || 500, { error: error.status ? error.message : 'request failed' });
    } finally {
      if (idleTimer) clearTimeout(idleTimer);
      idleTimer = setTimeout(() => { if (!activeRun) server.close(); }, idleMs).unref?.();
    }
  });

  server.cleanup = async () => {
    if (idleTimer) clearTimeout(idleTimer);
    for (const dir of [...tempDirs]) await rm(dir, { recursive: true, force: true });
  };
  server.token = token;
  server.listenAsync = (host = options.host || '127.0.0.1') => new Promise((resolveListen) => {
    server.listen(options.port || 0, host, () => {
      port = server.address().port;
      resolveListen(server.address());
    });
  });
  return server;
}

export async function main(argv = process.argv.slice(2)) {
  const hostIndex = argv.indexOf('--host');
  const portIndex = argv.indexOf('--port');
  const host = hostIndex >= 0 ? argv[hostIndex + 1] : '127.0.0.1';
  const bindWarning = host === '127.0.0.1' ? '' : ' Binding to a non-loopback address exposes this local installer server to the network.';
  const server = await createInstallerUiServer({ host, port: portIndex >= 0 ? Number(argv[portIndex + 1]) : 0 });
  const address = await server.listenAsync(host);
  const url = `http://${host}:${address.port}/?token=${encodeURIComponent(server.token)}`;
  console.log(`Claude gateway installer UI: ${url}`);
  console.log(`One-time token: ${server.token}`);
  if (bindWarning) console.log(bindWarning);
  console.log('Cloud Shell ends a session after 20 minutes without interactive activity; keep the shell active before long waits.');
  process.on('SIGINT', async () => {
    await server.cleanup();
    server.close(() => process.exit(130));
  });
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((error) => {
    console.error(error.message);
    process.exit(1);
  });
}
