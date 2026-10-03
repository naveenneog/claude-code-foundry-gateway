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
const identityScript = join(root, 'scripts', 'Get-ClaudeInstallerUiIdentity.ps1');
const prefillScript = join(root, 'scripts', 'Get-ClaudeInstallerUiPrefill.ps1');
const planScript = join(root, 'scripts', 'Get-ClaudeInstallerUiPlan.ps1');
const uiScript = join(here, 'installer-ui.js');
const uiCss = join(here, 'installer-ui.css');
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
  return "default-src 'self'; base-uri 'none'; object-src 'none'; frame-ancestors 'none'; form-action 'none'; script-src 'self'; style-src 'self'";
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

function sendText(res, status, text, contentType, headers = {}) {
  res.writeHead(status, {
    'content-type': contentType,
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

async function runPowerShell(script, args, options) {
  const child = spawn('pwsh', ['-NoProfile', '-NonInteractive', '-File', script, ...args], {
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

function writeNdjson(res, payload) {
  res.write(`${JSON.stringify(payload)}\n`);
}

async function runInstallerStreaming(kind, args, options, onEvent, progressPath) {
  const command = spawnInstallerArgs(kind, args, options);
  const child = spawn(command.file, command.args, {
    cwd: root,
    shell: false,
    windowsHide: true,
    env: { ...process.env, ...(options.env || {}) },
  });
  let progressOffset = 0;
  let progressCarry = '';
  const emitLines = async (type, chunk) => {
    for (const line of String(chunk).split(/\r?\n/)) {
      if (line) await onEvent({ type, line: await redactText(line) });
    }
  };
  child.stdout.on('data', (chunk) => { void emitLines('stdout', chunk.toString('utf8')); });
  child.stderr.on('data', (chunk) => { void emitLines('stderr', chunk.toString('utf8')); });
  const readProgress = async () => {
    if (!progressPath || !existsSync(progressPath)) return;
    const text = await readFile(progressPath, 'utf8');
    if (text.length <= progressOffset) return;
    progressCarry += text.slice(progressOffset);
    progressOffset = text.length;
    const lines = progressCarry.split(/\r?\n/);
    progressCarry = lines.pop() || '';
    for (const line of lines) {
      if (!line) continue;
      const event = JSON.parse(line);
      if (event.message) event.message = await redactText(event.message);
      if (event.resumeCommand) event.resumeCommand = await redactText(event.resumeCommand);
      await onEvent({ type: 'progress', ...event });
    }
  };
  const timer = setInterval(() => { void readProgress(); }, 100);
  const code = await new Promise((resolveCode, reject) => {
    child.on('error', reject);
    child.on('close', resolveCode);
  });
  clearInterval(timer);
  await readProgress();
  return code;
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

function fieldsByCheckId(schema) {
  const map = {};
  for (const [name, property] of Object.entries(schema.properties || {})) {
    const id = property['x-checkId'];
    if (!id) continue;
    map[id] ??= [];
    map[id].push(name);
  }
  const unit = schema?.$defs?.BusinessUnit;
  for (const [name, property] of Object.entries(unit?.properties || {})) {
    const id = property['x-checkId'];
    if (!id) continue;
    map[id] ??= [];
    map[id].push(`BusinessUnits.${name}`);
  }
  return map;
}

async function validateRunRequest(body, options) {
  const steps = Array.isArray(body.steps) ? body.steps.map(String).filter(Boolean) : [];
  if (!steps.length && !(body.fullRun && body.confirmFullRun)) {
    const error = new Error('Select at least one step, or confirm a full run.');
    error.status = 400;
    throw error;
  }
  const allowed = flattenStepIds(await listSteps(options));
  const injected = steps.filter((step) => !allowed.has(step));
  if (injected.length) {
    const error = new Error(`unknown step id: ${injected.join(', ')}`);
    error.status = 400;
    throw error;
  }
  return steps;
}

async function writeAnswers(dir, answers) {
  const path = join(dir, 'answers.json');
  await writeFile(path, `${JSON.stringify(answers ?? {}, null, 2)}\n`, { encoding: 'utf8', mode: 0o600 });
  return path;
}

async function renderHtml() {
  const schema = JSON.stringify(await loadSchema());
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Claude gateway installer</title>
  <link rel="stylesheet" href="./installer-ui.css">
  <script type="application/json" id="schema-json">${schema.replaceAll('<', '\\u003c')}</script>
  <script defer src="./installer-ui.js"></script>
</head>
<body>
  <header>
    <h1>Claude gateway installer</h1>
    <p id="identity">Signed-in account: read-only checks use the Azure CLI session in this terminal.</p>
    <button id="refresh-identity" type="button">Refresh account</button>
    <button id="signin" type="button">Show sign-in command</button>
    <pre id="signin-command"></pre>
    <p class="small">Cloud Shell ends a session after 20 minutes without interactive activity. Keep the shell active before long waits.</p>
  </header>
  <main>
    <section><h2>Prerequisites</h2><button id="preflight" type="button">Run preflight</button><div id="preflight-output"></div></section>
    <section><h2>Foundation</h2><div id="foundation" class="grid"></div></section>
    <section><h2>Access</h2><div id="access" class="grid"></div></section>
    <section><h2>Optional parts</h2><div id="optional" class="grid"></div></section>
    <section><h2>Business units and teams</h2><div id="business-unit-tree"></div><button id="add-unit" type="button">Add unit</button><label>Add team under <select id="team-parent"></select></label><button id="add-team" type="button">Add team</button><details><summary>JSON view</summary><textarea id="business-units" rows="8" cols="80"></textarea></details><pre id="business-unit-problems"></pre></section>
    <section><h2>Review</h2><button id="download" type="button">Download answers.json</button><button id="plan" type="button">Plan fingerprint</button><pre id="commands"></pre><pre id="plan-output"></pre></section>
    <section><h2>Run</h2><button id="steps" type="button">List steps</button><div id="step-list"></div><button id="run" type="button">Run selected steps</button><button id="full-run" type="button">Full run</button><button id="rerun" type="button" disabled>Re-run failed step</button><pre id="run-output"></pre></section>
    <pre id="errors"></pre>
  </main>
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
  let stopping = false;
  const idleMs = Number(options.idleMs || defaultIdleMs);
  const extraHosts = options.allowedHosts || [];
  const log = options.log || (() => {});

  const cleanup = async () => {
    if (idleTimer) clearTimeout(idleTimer);
    server.closeAllConnections?.();
    for (const dir of [...tempDirs]) await rm(dir, { recursive: true, force: true });
  };

  const stopServer = async (reason) => {
    if (activeRun || stopping) return;
    stopping = true;
    await cleanup();
    log(`Installer UI stopped: ${reason}`);
    server.closeAllConnections?.();
    server.close(() => {
      server.emit('installer-ui-stopped', reason);
      if (options.exitOnStop) process.exit(0);
    });
  };

  const armIdle = () => {
    if (idleTimer) clearTimeout(idleTimer);
    idleTimer = setTimeout(() => { void stopServer('idle timeout'); }, idleMs);
    idleTimer.unref?.();
  };

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

      if (req.method === 'GET' && (url.pathname === '/' || url.pathname === '/index.html')) return send(res, 200, await renderHtml(), setCookie);
      if (req.method === 'GET' && url.pathname === '/installer-ui.js') return sendText(res, 200, await readFile(uiScript, 'utf8'), 'text/javascript; charset=utf-8', setCookie);
      if (req.method === 'GET' && url.pathname === '/ui-model.mjs') return sendText(res, 200, await readFile(join(here, 'ui-model.mjs'), 'utf8'), 'text/javascript; charset=utf-8', setCookie);
      if (req.method === 'GET' && url.pathname === '/installer-ui.css') return sendText(res, 200, await readFile(uiCss, 'utf8'), 'text/css; charset=utf-8', setCookie);
      if (req.method === 'GET' && url.pathname === '/api/schema') return send(res, 200, await loadSchema(), setCookie);
      if (req.method === 'GET' && url.pathname === '/api/steps') return send(res, 200, await listSteps(options), setCookie);
      if (req.method === 'GET' && url.pathname === '/api/identity') {
        const result = await runPowerShell(identityScript, [], options);
        return send(res, 200, JSON.parse(result.stdout), setCookie);
      }
      if (req.method === 'GET' && url.pathname === '/api/prefill') {
        const args = ['-Kind', url.searchParams.get('kind') || 'subscriptions'];
        for (const [param, query] of [['-SubscriptionId', 'subscriptionId'], ['-FoundryAccount', 'foundryAccount'], ['-FoundryResourceGroup', 'foundryResourceGroup']]) {
          const value = url.searchParams.get(query);
          if (value) args.push(param, value);
        }
        const result = await runPowerShell(prefillScript, args, options);
        const parsed = JSON.parse(result.stdout);
        if (parsed.error) parsed.error = await redactText(parsed.error);
        return send(res, 200, parsed, setCookie);
      }
      if (req.method === 'POST' && url.pathname === '/api/commands') {
        const body = await readJsonBody(req);
        return send(res, 200, buildCommands(body.answersPath || './answers.json', await loadSchema()), setCookie);
      }
      if (req.method === 'POST' && url.pathname === '/api/plan') {
        const body = await readJsonBody(req);
        return send(res, 200, await withRunDirectory(async (dir) => {
          const answers = await writeAnswers(dir, body.answers || {});
          const result = await runPowerShell(planScript, ['-AnswersPath', answers], options);
          return JSON.parse(result.stdout);
        }, tempDirs), setCookie);
      }
      if (req.method === 'POST' && url.pathname === '/api/preflight') {
        const body = await readJsonBody(req);
        return send(res, 200, await withRunDirectory(async (dir) => {
          const answers = await writeAnswers(dir, body.answers || {});
          const result = await runInstaller('powershell', ['-AnswersPath', answers, '-Preflight', '-Json'], options);
          let parsed;
          try { parsed = JSON.parse(result.stdout); } catch { parsed = null; }
          return { exitCode: result.code, preflight: parsed, stdout: result.stdout, stderr: result.stderr, fieldsByCheckId: fieldsByCheckId(await loadSchema()) };
        }, tempDirs), setCookie);
      }
      if (req.method === 'POST' && url.pathname === '/api/run/stream') {
        if (activeRun) return send(res, 409, { error: 'an installer run is already active' }, setCookie);
        const body = await readJsonBody(req);
        activeRun = {};
        res.writeHead(200, {
          'content-type': 'application/x-ndjson; charset=utf-8',
          'cache-control': 'no-store',
          'content-security-policy': contentSecurityPolicy(),
          'x-content-type-options': 'nosniff',
          ...setCookie,
        });
        try {
          await withRunDirectory(async (dir) => {
            const steps = await validateRunRequest(body, options);
            const answers = await writeAnswers(dir, body.answers || {});
            const progress = join(dir, 'progress.ndjson');
            const args = ['-AnswersPath', answers, '-Yes', '-ProgressPath', progress];
            if (steps.length) args.push('-Steps', steps.join(','));
            let failedStepId = '';
            let resumeCommand = '';
            const code = await runInstallerStreaming('powershell', args, options, async (event) => {
              if (event.type === 'progress' && event.event === 'failed') {
                failedStepId = event.stepId || '';
                resumeCommand = event.resumeCommand || (failedStepId ? `Install-ClaudeGateway.ps1 -Steps ${failedStepId}` : '');
              }
              writeNdjson(res, event);
            }, progress);
            if (failedStepId && !resumeCommand) resumeCommand = `Install-ClaudeGateway.ps1 -Steps ${failedStepId}`;
            writeNdjson(res, { type: 'summary', exitCode: code, failedStepId, resumeCommand });
          }, tempDirs);
        } finally {
          activeRun = null;
          res.end();
          armIdle();
        }
        return;
      }
      if (req.method === 'POST' && url.pathname === '/api/run') {
        if (activeRun) return send(res, 409, { error: 'an installer run is already active' }, setCookie);
        const body = await readJsonBody(req);
        activeRun = {};
        try {
          const result = await withRunDirectory(async (dir) => {
            const steps = await validateRunRequest(body, options);
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
      if (!activeRun) armIdle();
    }
  });

  server.cleanup = cleanup;
  server.stopServer = stopServer;
  server.token = token;
  server.listenAsync = (host = options.host || '127.0.0.1') => new Promise((resolveListen) => {
    server.listen(options.port || 0, host, () => {
      port = server.address().port;
      armIdle();
      resolveListen(server.address());
    });
  });
  return server;
}

export async function main(argv = process.argv.slice(2)) {
  const hostIndex = argv.indexOf('--host');
  const portIndex = argv.indexOf('--port');
  const idleIndex = argv.indexOf('--idle-ms');
  const host = hostIndex >= 0 ? argv[hostIndex + 1] : '127.0.0.1';
  const bindWarning = host === '127.0.0.1' ? '' : ' Binding to a non-loopback address exposes this local installer server to the network.';
  const server = await createInstallerUiServer({
    host,
    port: portIndex >= 0 ? Number(argv[portIndex + 1]) : 0,
    idleMs: idleIndex >= 0 ? Number(argv[idleIndex + 1]) : defaultIdleMs,
    log: (line) => console.log(line),
    exitOnStop: true,
  });
  const address = await server.listenAsync(host);
  const url = `http://${host}:${address.port}/?token=${encodeURIComponent(server.token)}`;
  console.log(`Claude gateway installer UI: ${url}`);
  console.log(`One-time token: ${server.token}`);
  if (bindWarning) console.log(bindWarning);
  console.log('Cloud Shell ends a session after 20 minutes without interactive activity; keep the shell active before long waits.');
  process.on('SIGINT', async () => {
    await server.cleanup();
    console.log('Installer UI stopped: interrupt');
    server.closeAllConnections?.();
    server.close(() => process.exit(130));
  });
}

if (process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1])) {
  main().catch((error) => {
    console.error(error.message);
    process.exit(1);
  });
}
