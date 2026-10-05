import { createServer as createHttpServer } from 'node:http';
import { spawn } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { StringDecoder } from 'node:string_decoder';
import { once } from 'node:events';
import { mkdtemp, readFile, rm, writeFile, chmod } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { validatePreflight, validateProgressEvent, validateStepList } from './installer-contract.mjs';
import { createAzureLease } from './azure-lease.mjs';
import { assertSameOrigin, constantTimeTokenEquals, contentSecurityPolicy, isAllowedHost, isLoopbackBind, parseCookies, readJsonBody, send, sendText, tokenHash } from './http-helpers.mjs';
import { attachSubscriber, createRunRecord, publicRun, publishEvent } from './run-record.mjs';
import { createLineHandler, readProgressFile, writeNdjson } from './run-transport.mjs';
import { createSessionAuth } from './session-auth.mjs';
import { collectChildOutput } from './child-output.mjs';
import { validateRunRequest, validateStepScope } from './step-scope.mjs';
import { fieldsByCheckId, installerArguments, loadSchema, prefillArguments, preflightCheckIds, redactText, root, scrubLocalPaths } from './server-model.mjs';
import { answersDigest, createPreflightStore, preflightFingerprint, preflightRequired, scopeCovers, scopeFromBody } from './preflight-record.mjs';

export { loadSchema, redactText, scrubLocalPaths } from './server-model.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const psInstaller = join(root, 'Install-ClaudeGateway.ps1');
const identityScript = join(root, 'scripts', 'Get-ClaudeInstallerUiIdentity.ps1');
const prefillScript = join(root, 'scripts', 'Get-ClaudeInstallerUiPrefill.ps1');
const uiScript = join(here, 'installer-ui.js');
const uiBusinessUnitsScript = join(here, 'installer-ui-business-units.js');
const uiPrefillScript = join(here, 'installer-ui-prefill.js');
const uiActionsScript = join(here, 'installer-ui-actions.js');
const uiProblemsScript = join(here, 'installer-ui-problems.js');
const uiRunScript = join(here, 'installer-ui-run.js');
const uiModelScript = join(here, 'ui-model.js');
const uiCss = join(here, 'installer-ui.css');
const uiIndex = join(here, 'index.html');
const defaultIdleMs = 30 * 60 * 1000;
const consoleOutputCapBytes = 4 * 1024 * 1024;
const consoleLineCapBytes = 64 * 1024;

async function withRunDirectory(fn, tempDirs, parent = tmpdir()) {
  const dir = await mkdtemp(join(parent, 'claude-installer-ui-'));
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
  if (kind === 'powershell') return { file: options.pwsh || 'pwsh', args: ['-NoProfile', '-NonInteractive', '-File', psInstaller, ...args] };
  throw new Error(`unsupported installer engine: ${kind}`);
}

async function killProcessTree(child) {
  if (!child?.pid) return;
  if (process.platform === 'win32') {
    const killer = spawn('taskkill.exe', ['/PID', String(child.pid), '/T', '/F'], { shell: false, windowsHide: true, stdio: 'ignore' });
    await once(killer, 'close').catch(() => {});
    return;
  }
  try { process.kill(-child.pid, 'SIGTERM'); } catch { try { child.kill('SIGTERM'); } catch { /* already gone */ } }
  await new Promise((resolve) => setTimeout(resolve, 750));
  try { process.kill(-child.pid, 'SIGKILL'); } catch { try { child.kill('SIGKILL'); } catch { /* already gone */ } }
}

function childEnv(options) {
  return { ...process.env, NO_COLOR: '1', ...(options.env || {}) };
}

function spawnChild(file, args, options, spawnOptions = {}) {
  const child = spawn(file, args, {
    cwd: root,
    shell: false,
    windowsHide: true,
    detached: process.platform !== 'win32',
    env: childEnv(options),
    ...spawnOptions,
  });
  options._children?.add(child);
  child.on('close', () => options._children?.delete(child));
  child.on('error', () => options._children?.delete(child));
  return child;
}

async function runInstaller(kind, args, options, runOptions = {}) {
  const command = spawnInstallerArgs(kind, args, options);
  const child = spawnChild(command.file, command.args, options);
  return collectChildOutput(child, runOptions, 'installer read', { killProcessTree, redactText });
}

async function runPowerShell(script, args, options, runOptions = {}) {
  const child = spawnChild(options.pwsh || 'pwsh', ['-NoProfile', '-NonInteractive', '-File', script, ...args], options);
  return collectChildOutput(child, runOptions, 'read-only installer child', { killProcessTree, redactText });
}

async function checkPowerShell(options) {
  const command = options.pwsh || 'pwsh';
  const child = spawn(command, ['-NoProfile', '-NonInteractive', '-Command', '$PSVersionTable.PSVersion.Major'], { cwd: root, shell: false, windowsHide: true, env: childEnv(options) });
  let stdout = '';
  let stderr = '';
  child.stdout.on('data', (chunk) => { stdout += chunk.toString('utf8'); });
  child.stderr.on('data', (chunk) => { stderr += chunk.toString('utf8'); });
  let timer;
  const code = await new Promise((resolve) => {
    timer = setTimeout(() => { void killProcessTree(child); resolve(null); }, Number(options.pwshCheckTimeoutMs || 5000));
    timer.unref?.();
    child.on('error', (error) => resolve(error));
    child.on('close', resolve);
  });
  if (timer) clearTimeout(timer);
  if (code instanceof Error) return { ok: false, reason: `${command} is not available: ${code.message}` };
  if (code === null) return { ok: false, reason: `${command} did not answer the PowerShell version check.` };
  const major = Number(stdout.trim());
  if (code !== 0 || !Number.isInteger(major)) return { ok: false, reason: `${command} could not report PowerShell 7 or newer. ${stderr.trim()}`.trim() };
  if (major < 7) return { ok: false, reason: `${command} reports PowerShell ${major}; PowerShell 7 or newer is required for live mode.` };
  return { ok: true, reason: '' };
}

async function runInstallerStreaming(kind, args, options, onEvent, progressPath, runOptions = {}) {
  const command = spawnInstallerArgs(kind, args, options);
  const child = spawnChild(command.file, command.args, options);
  runOptions.onChild?.(child);
  let progressCarry = '';
  let progressReading = Promise.resolve();
  let emitQueue = Promise.resolve();
  let consoleBytes = 0;
  let capNoticed = false;
  const enqueue = (event) => {
    emitQueue = emitQueue.then(() => onEvent(event)).catch((error) => onEvent({ type: 'error', message: error.message }).catch(() => {}));
    return emitQueue;
  };
  const emitConsoleLine = async (type, line) => {
    if (!line) return;
    const redacted = await redactText(line);
    const bytes = Buffer.byteLength(redacted);
    if (consoleBytes + bytes > consoleOutputCapBytes) {
      if (!capNoticed) {
        capNoticed = true;
        await enqueue({ type: 'notice', message: `The ${consoleOutputCapBytes} byte output cap was reached; the installer continues and progress plus summary events are still shown.` });
      }
      return;
    }
    consoleBytes += bytes;
    await enqueue({ type, line: redacted });
  };
  const stdout = createLineHandler('stdout', emitConsoleLine, consoleLineCapBytes);
  const stderr = createLineHandler('stderr', emitConsoleLine, consoleLineCapBytes);
  child.stdout.on('data', (chunk) => { void stdout.chunk(chunk); });
  child.stderr.on('data', (chunk) => { void stderr.chunk(chunk); });
  const progressDecoder = new StringDecoder('utf8');
  let progressDiscarding = false;
  const processProgressText = async (text, final) => {
    progressCarry += text;
    const lines = progressCarry.split(/\r?\n/);
    progressCarry = lines.pop() || '';
    if (final && progressCarry) {
      lines.push(progressCarry);
      progressCarry = '';
    }
    for (const line of lines) {
      if (progressDiscarding) {
        progressDiscarding = false;
        continue;
      }
      if (!line) continue;
      if (Buffer.byteLength(line) > consoleLineCapBytes) {
        await enqueue({ type: 'error', message: `progress line exceeded the ${consoleLineCapBytes} byte cap` });
        continue;
      }
      try {
        const event = validateProgressEvent(JSON.parse(line));
        if (event.message) event.message = await redactText(event.message);
        if (event.resumeCommand) event.resumeCommand = await redactText(event.resumeCommand);
        await enqueue({ type: 'progress', ...event });
      } catch (error) {
        await enqueue({ type: 'error', message: await redactText(`progress parse failed: ${error.message}`) });
      }
    }
    if (Buffer.byteLength(progressCarry) > consoleLineCapBytes) {
      progressCarry = '';
      // A line that is already being discarded has had its one error event.
      if (!progressDiscarding) await enqueue({ type: 'error', message: `progress line exceeded the ${consoleLineCapBytes} byte cap` });
      progressDiscarding = true;
    }
  };
  const progressState = { offset: 0, decoder: progressDecoder };
  const timer = setInterval(() => { progressReading = progressReading.then(() => readProgressFile(progressPath, progressState, processProgressText, false)).catch((error) => enqueue({ type: 'error', message: `progress read failed: ${error.message}` })); }, 100);
  let code;
  try {
    code = await new Promise((resolveCode, reject) => {
      child.on('error', reject);
      child.on('close', resolveCode);
    });
  } finally {
    clearInterval(timer);
  }
  await Promise.all([
    child.stdout.readableEnded ? Promise.resolve() : once(child.stdout, 'end').catch(() => {}),
    child.stderr.readableEnded ? Promise.resolve() : once(child.stderr, 'end').catch(() => {}),
  ]);
  await stdout.end();
  await stderr.end();
  await progressReading;
  await readProgressFile(progressPath, progressState, processProgressText, true);
  await processProgressText(progressDecoder.end(), true);
  await emitQueue;
  return code;
}

async function listSteps(options, timeoutMs = 60_000) {
  const result = await runInstaller('powershell', ['-ListSteps', '-Json'], options, { timeoutMs, readName: 'step list' });
  if (result.code !== 0) throw new Error(`step list failed: ${result.stderr || result.stdout}`);
  return validateStepList(JSON.parse(result.stdout));
}

async function writeAnswers(dir, answers) {
  const path = join(dir, 'answers.json');
  await writeFile(path, `${JSON.stringify(answers ?? {}, null, 2)}\n`, { encoding: 'utf8', mode: 0o600 });
  return path;
}

export async function createInstallerUiServer(options = {}) {
  const token = options.token || randomBytes(32).toString('base64url');
  const tokenDigest = tokenHash(token);
  const sessionAuth = createSessionAuth();
  const azureLease = createAzureLease();
  const csrfToken = options.csrfToken || randomBytes(32).toString('base64url');
  const tempDirs = new Set();
  let port = Number(options.port || 0);
  let tokenConsumed = false;
  let activeRun = null;
  let lastRun = null;
  let idleTimer = null;
  let stopping = false;
  let inFlight = 0;
  const preflightPasses = createPreflightStore(20);
  let liveMode = { ok: false, reason: 'PowerShell live-mode check has not completed.' };
  options._children = new Set();
  const idleMs = Number(options.idleMs || defaultIdleMs);
  const tempRoot = options.tempRoot || tmpdir();
  const timeoutFor = (name) => Number(options.readOnlyTimeoutMs || ({ steps: 60_000, identity: 120_000, prefill: 120_000, preflight: 600_000 }[name]));
  const outputCapFor = () => Number(options.readOnlyOutputCapBytes || 1024 * 1024);
  const extraHosts = options.allowedHosts || [];
  const log = options.log || (() => {});
  const logRequestRefusal = (request) => {
    log(`Refused same-origin request: origin=${request.headers.origin || ''}; host=${request.headers.host || ''}; sec-fetch-site=${request.headers['sec-fetch-site'] || ''}; x-forwarded-host=${request.headers['x-forwarded-host'] || ''}; x-forwarded-proto=${request.headers['x-forwarded-proto'] || ''}; x-forwarded-prefix=${request.headers['x-forwarded-prefix'] || ''}`);
  };

  const cleanup = async () => {
    if (idleTimer) clearTimeout(idleTimer);
    await Promise.all([...options._children].map((child) => killProcessTree(child).catch(() => {})));
    server.closeAllConnections?.();
    for (const dir of [...tempDirs]) await rm(dir, { recursive: true, force: true, maxRetries: 20, retryDelay: 100 }).catch(() => {});
  };

  const stopServer = async (reason) => {
    if ((activeRun?.state === 'running' || activeRun?.state === 'stopping') || inFlight > 0 || stopping) return;
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
    if ((activeRun?.state === 'running' || activeRun?.state === 'stopping') || inFlight > 0) return;
    idleTimer = setTimeout(() => { void stopServer('idle timeout'); }, idleMs);
    idleTimer.unref?.();
  };

  const withJob = async (fn) => {
    inFlight++;
    if (idleTimer) clearTimeout(idleTimer);
    try { return await fn(); }
    finally { inFlight--; armIdle(); }
  };

  const withAzureRead = async (operation, fn) => withJob(async () => {
    const lease = await azureLease.acquire(operation, 'read', timeoutFor(operation));
    try { return await fn(lease); }
    finally { lease.release(); }
  });

  const childTimeout = (lease) => ({ timeoutMs: lease.remainingTimeout(), budgetMs: lease.timeoutMs });

  const readIdentityPayload = async (timing) => {
    if (options.readIdentity) return options.readIdentity();
    const result = await runPowerShell(identityScript, [], options, { ...timing, readName: 'identity', outputCapBytes: outputCapFor() });
    return JSON.parse(result.stdout);
  };

  const identitySnapshot = (value) => ({
    signedIn: Boolean(value?.signedIn),
    user: String(value?.user || ''),
    tenantId: String(value?.tenantId || ''),
    subscriptionId: String(value?.subscriptionId || value?.id || ''),
  });

  const readIdentitySnapshot = async (timing) => {
    return identitySnapshot(await readIdentityPayload(timing));
  };

  const changedIdentityFields = (before, after) => {
    const fields = [];
    if (Boolean(before?.signedIn) !== Boolean(after?.signedIn)) fields.push('signed-in state');
    if (String(before?.user || '') !== String(after?.user || '')) fields.push('user');
    if (String(before?.tenantId || '') !== String(after?.tenantId || '')) fields.push('tenant');
    if (String(before?.subscriptionId || '') !== String(after?.subscriptionId || '')) fields.push('subscription');
    return fields;
  };

  const assertFetchMetadataForChildGet = (request) => {
    const fetchSite = request.headers['sec-fetch-site'];
    if (fetchSite && fetchSite !== 'same-origin' && fetchSite !== 'none') {
      logRequestRefusal(request);
      const error = new Error('same-origin request required');
      error.status = 403;
      throw error;
    }
  };

  const requireLive = () => {
    if (liveMode.ok) return;
    const error = new Error(liveMode.reason);
    error.status = 503;
    error.reason = liveMode.reason;
    throw error;
  };

  const publish = publishEvent;
  const attachRun = attachSubscriber;

  const createRun = (steps) => {
    if (activeRun?.state === 'running' || activeRun?.state === 'stopping') return null;
    const run = createRunRecord(steps, { tailEvents: options.runTailEvents, tailBytes: options.runTailBytes });
    activeRun = run;
    lastRun = run;
    return run;
  };

  // The run's own directory (answers and progress file) and the installer arguments. When the directory
  // cannot be prepared, the run is released with an error and a summary, so later runs are not refused.
  const prepareRun = async (run, answers, steps) => {
    try {
      run.tempDir = await mkdtemp(join(tempRoot, 'claude-installer-ui-'));
      tempDirs.add(run.tempDir);
      try { await chmod(run.tempDir, 0o700); } catch { /* Windows ACLs are inherited; the directory is still per-run. */ }
      const answersPath = await writeAnswers(run.tempDir, answers || {});
      run.progressPath = join(run.tempDir, 'progress.ndjson');
      const args = await installerArguments({ engine: 'pwsh', action: 'run', answersPath, progressPath: run.progressPath, steps, fullRun: !steps.length });
      return args;
    } catch (error) {
      log(`Installer run could not start: ${error.message}`);
      const message = 'The installer run could not start: its temporary directory could not be prepared. The terminal that started the installer UI shows the details.';
      run.state = 'exited';
      publish(run, { type: 'error', message });
      publish(run, { type: 'summary', exitCode: null, failedStepId: '', resumeCommand: '', state: run.state, message: '' });
      if (run.tempDir) {
        await rm(run.tempDir, { recursive: true, force: true, maxRetries: 20, retryDelay: 100 }).catch(() => {});
        tempDirs.delete(run.tempDir);
      }
      run.tempDirRemoved = true;
      if (activeRun === run) activeRun = null;
      const failure = new Error(message);
      failure.status = 500;
      throw failure;
    }
  };

  const server = createHttpServer(async (req, res) => {
    try {
      if (!isAllowedHost(req.headers.host, port, extraHosts)) {
        log(`Refused Host: host=${req.headers.host || ''}; x-forwarded-host=${req.headers['x-forwarded-host'] || ''}; x-forwarded-proto=${req.headers['x-forwarded-proto'] || ''}; x-forwarded-prefix=${req.headers['x-forwarded-prefix'] || ''}`);
        return send(res, 403, { error: 'host header is not allowed' });
      }
      if (req.method === 'OPTIONS') return send(res, 405, { error: 'OPTIONS is not allowed' });
      const url = new URL(req.url, `http://${req.headers.host}`);
      const queryToken = url.searchParams.get('token');
      const cookies = parseCookies(req.headers.cookie);
      const cookieToken = cookies.get('installer_token');
      if (queryToken) {
        if (!(req.method === 'GET' && (url.pathname === '/' || url.pathname === '/index.html')) || tokenConsumed || !constantTimeTokenEquals(queryToken, tokenDigest)) {
          return send(res, 401, { error: 'installer token is required' });
        }
        tokenConsumed = true;
        const sessionSecret = sessionAuth.issueSecret();
        res.writeHead(303, {
          location: './',
          'set-cookie': `installer_token=${encodeURIComponent(sessionSecret)}; HttpOnly; SameSite=Strict; Path=/`,
          'content-security-policy': contentSecurityPolicy(),
          'x-content-type-options': 'nosniff',
          'referrer-policy': 'no-referrer',
        });
        res.end();
        return;
      }
      if (!sessionAuth.accepts(cookieToken)) return send(res, 401, { error: 'installer token is required' });
      const setCookie = {};
      if (req.method === 'GET' && url.pathname === '/api/session') return send(res, 200, { schemaVersion: 1, csrfToken, mode: liveMode.ok ? 'live' : 'static', reason: liveMode.reason || undefined }, setCookie);
      if (req.method === 'POST') {
        if (!String(req.headers['content-type'] || '').toLowerCase().startsWith('application/json')) return send(res, 415, { error: 'Content-Type application/json is required' }, setCookie);
        if (!constantTimeTokenEquals(String(req.headers['x-csrf-token'] || ''), tokenHash(csrfToken))) return send(res, 403, { error: 'CSRF token is required' }, setCookie);
      }

      if (req.method === 'GET' && (url.pathname === '/' || url.pathname === '/index.html')) return sendText(res, 200, await readFile(uiIndex, 'utf8'), 'text/html; charset=utf-8', setCookie);
      if (req.method === 'GET' && url.pathname === '/installer-ui.js') return sendText(res, 200, await readFile(uiScript, 'utf8'), 'text/javascript; charset=utf-8', setCookie);
      if (req.method === 'GET' && url.pathname === '/installer-ui-business-units.js') return sendText(res, 200, await readFile(uiBusinessUnitsScript, 'utf8'), 'text/javascript; charset=utf-8', setCookie);
      if (req.method === 'GET' && url.pathname === '/installer-ui-prefill.js') return sendText(res, 200, await readFile(uiPrefillScript, 'utf8'), 'text/javascript; charset=utf-8', setCookie);
      if (req.method === 'GET' && url.pathname === '/installer-ui-actions.js') return sendText(res, 200, await readFile(uiActionsScript, 'utf8'), 'text/javascript; charset=utf-8', setCookie);
      if (req.method === 'GET' && url.pathname === '/installer-ui-problems.js') return sendText(res, 200, await readFile(uiProblemsScript, 'utf8'), 'text/javascript; charset=utf-8', setCookie);
      if (req.method === 'GET' && url.pathname === '/installer-ui-run.js') return sendText(res, 200, await readFile(uiRunScript, 'utf8'), 'text/javascript; charset=utf-8', setCookie);
      if (req.method === 'GET' && url.pathname === '/ui-model.js') return sendText(res, 200, await readFile(uiModelScript, 'utf8'), 'text/javascript; charset=utf-8', setCookie);
      if (req.method === 'GET' && url.pathname === '/installer-ui.css') return sendText(res, 200, await readFile(uiCss, 'utf8'), 'text/css; charset=utf-8', setCookie);
      if (req.method === 'GET' && url.pathname === '/api/schema') return send(res, 200, await loadSchema(), setCookie);
      if (req.method === 'GET' && url.pathname === '/api/steps') {
        requireLive();
        assertFetchMetadataForChildGet(req);
        return send(res, 200, await withJob(() => listSteps(options, timeoutFor('steps'))), setCookie);
      }
      if (req.method === 'GET' && url.pathname === '/api/identity') {
        requireLive();
        assertFetchMetadataForChildGet(req);
        return send(res, 200, await withAzureRead('identity', (lease) => readIdentityPayload(childTimeout(lease))), setCookie);
      }
      if (req.method === 'GET' && url.pathname === '/api/run/status') return send(res, 200, { schemaVersion: 1, ...(publicRun(activeRun || lastRun) || {}) }, setCookie);
      if (req.method === 'GET' && url.pathname === '/api/run/attach') {
        const run = activeRun || lastRun;
        if (!run) return send(res, 404, { error: 'no installer run is available' }, setCookie);
        await attachRun(run, res, Number(url.searchParams.get('after') || 0));
        return;
      }
      if (req.method === 'POST' && url.pathname === '/api/prefill') {
        requireLive();
        assertSameOrigin(req, logRequestRefusal);
        const body = await readJsonBody(req);
        const args = prefillArguments(body);
        const result = await withAzureRead('prefill', (lease) => runPowerShell(prefillScript, args, options, { redactStdout: false, ...childTimeout(lease), readName: 'prefill', outputCapBytes: outputCapFor() }));
        if (!result.stdout.trim()) {
          log(`Prefill returned no JSON (exit ${result.code}): ${scrubLocalPaths(result.stderr)}`);
          return send(res, 500, { schemaVersion: 1, error: 'The prefill read returned no result. The terminal that started the installer UI shows the details.' }, setCookie);
        }
        const parsed = JSON.parse(result.stdout);
        if (parsed.error) parsed.error = scrubLocalPaths(await redactText(parsed.error));
        return send(res, parsed.field ? 400 : 200, parsed, setCookie);
      }
      if (req.method === 'POST' && url.pathname === '/api/preflight') {
        requireLive();
        assertSameOrigin(req, logRequestRefusal);
        const body = await readJsonBody(req);
        const requestedSteps = await withJob(() => validateStepScope(body, () => listSteps(options)));
        const scope = scopeFromBody(body, requestedSteps);
        const digest = answersDigest(body.answers || {});
        const engine = 'pwsh';
        return send(res, 200, await withAzureRead('preflight', (lease) => withRunDirectory(async (dir) => {
          const answers = await writeAnswers(dir, body.answers || {});
          const result = await runInstaller('powershell', await installerArguments({ engine: 'pwsh', action: 'preflight', answersPath: answers }), options, { ...childTimeout(lease), readName: 'preflight', outputCapBytes: outputCapFor() });
          let parsed;
          const schema = await loadSchema();
          const expectedCheckIds = await preflightCheckIds(schema);
          try { parsed = validatePreflight(JSON.parse(result.stdout), { expectedCheckIds }); } catch (error) {
            if (error.status === 502) throw error;
            const detail = scrubLocalPaths(await redactText(`${result.stdout}\n${result.stderr}`)).trim().slice(-1000);
            const malformed = new Error('preflight output was not JSON; the installer output is shown in detail.');
            malformed.status = 502;
            malformed.detail = detail;
            malformed.exitCode = result.code;
            throw malformed;
          }
          let fingerprint = '';
          let identity;
          if (parsed.result === 'PASS' && result.code === 0) {
            identity = await readIdentitySnapshot(childTimeout(lease));
            fingerprint = preflightFingerprint({ answers: body.answers || {}, scope, engine });
            preflightPasses.replaceForAnswers({ fingerprint, answersDigest: digest, engine, scope, time: new Date().toISOString(), identity });
          } else {
            preflightPasses.clearForAnswers(digest, engine);
          }
          return { exitCode: result.code, fingerprint: fingerprint || undefined, identity, scope: fingerprint ? scope : undefined, preflight: parsed, stdout: result.stdout, stderr: result.stderr, fieldsByCheckId: await fieldsByCheckId(schema) };
        }, tempDirs, tempRoot)), setCookie);
      }
      if (req.method === 'POST' && url.pathname === '/api/run/stream') {
        requireLive();
        assertSameOrigin(req, logRequestRefusal);
        if (activeRun?.state === 'running' || activeRun?.state === 'stopping') return send(res, 409, { error: 'an installer run is already active', reason: 'azure-busy', operation: 'run' }, setCookie);
        const body = await readJsonBody(req);
        const steps = await validateRunRequest(body, () => listSteps(options));
        if (body.answers?.AddressMode === 'custom' && body.answers?.AddressCertificateSource === 'Pfx') {
          return send(res, 409, { error: 'A PFX certificate is installed from a terminal because the installer asks for the PFX password only when it runs without -Yes.', reason: 'pfx-needs-terminal' }, setCookie);
        }
        const scope = scopeFromBody(body, steps);
        const digest = answersDigest(body.answers || {});
        const lease = await azureLease.acquire('run', 'run', 0);
        const record = preflightPasses.lookup(body.fingerprint);
        try {
          if (!record) throw preflightRequired('No passing preflight matched this run. Run preflight again before starting the installer.');
          if (record.engine !== 'pwsh' || record.answersDigest !== digest || !scopeCovers(record.scope, scope)) {
            throw preflightRequired('The answers or selected steps changed since the last passing preflight. Run preflight again.');
          }
          const currentIdentity = await readIdentitySnapshot({ timeoutMs: timeoutFor('identity') });
          const changed = changedIdentityFields(record.identity, currentIdentity);
          if (changed.length) {
            const error = new Error(`The Azure identity ${changed.join(', ')} changed since preflight. Run preflight again.`);
            error.status = 409;
            error.reason = 'identity-changed';
            throw error;
          }
        } catch (error) {
          lease.release();
          throw error;
        }
        const run = createRun(steps);
        if (!run) {
          lease.release();
          return send(res, 409, { error: 'an installer run is already active', reason: 'azure-busy', operation: 'run' }, setCookie);
        }
        let args;
        try {
          args = await prepareRun(run, body.answers, steps);
        } catch (error) {
          lease.release();
          throw error;
        }
        await attachRun(run, res, 0);
        void (async () => {
          try {
            if (options.beforeRunSpawn) await options.beforeRunSpawn(run);
            if (run.stopRequested) {
              run.state = 'stopped';
              run.exitCode = null;
              return;
            }
            const code = await runInstallerStreaming('powershell', args, options, async (event) => {
              publish(run, event);
            }, run.progressPath, { onChild: (child) => { run.child = child; if (run.stopRequested) void killProcessTree(child); } });
            run.exitCode = code;
            run.state = run.state === 'stopping' ? 'stopped' : 'exited';
          } catch (error) {
            run.exitCode = 1;
            run.state = run.state === 'stopping' ? 'stopped' : 'exited';
            publish(run, { type: 'error', message: await redactText(scrubLocalPaths(error.message)) });
          } finally {
            if (run.failedStepId && !run.resumeCommand) run.resumeCommand = `Install-ClaudeGateway.ps1 -Steps ${run.failedStepId}`;
            // Each subscriber ends its own response once it has written this summary.
            publish(run, { type: 'summary', exitCode: run.exitCode, failedStepId: run.failedStepId, resumeCommand: run.resumeCommand, state: run.state, message: run.stoppedMessage });
            lease.release();
            try {
              await rm(run.tempDir, { recursive: true, force: true, maxRetries: 20, retryDelay: 100 });
              tempDirs.delete(run.tempDir);
              run.tempDirRemoved = true;
            } catch {
              setTimeout(() => {
                void rm(run.tempDir, { recursive: true, force: true, maxRetries: 20, retryDelay: 100 }).then(() => {
                  tempDirs.delete(run.tempDir);
                  run.tempDirRemoved = true;
                }).catch(() => {});
              }, 500).unref?.();
            }
            if (activeRun === run) activeRun = null;
            armIdle();
          }
        })();
        return;
      }
      if (req.method === 'POST' && url.pathname === '/api/run/stop') {
        requireLive();
        assertSameOrigin(req, logRequestRefusal);
        const body = await readJsonBody(req);
        const run = activeRun || lastRun;
        if (!run || run.id !== body.runId || (run.state !== 'running' && run.state !== 'stopping')) return send(res, 404, { error: 'active run not found' }, setCookie);
        run.state = 'stopping';
        run.stopRequested = true;
        const step = run.currentStepId || run.steps[0] || 'the current step';
        run.stoppedMessage = `Stopped installer run at ${step}. The install checkpoint resumes when the same steps run again.`;
        publish(run, { type: 'stopped', stepId: step, message: run.stoppedMessage });
        await killProcessTree(run.child);
        return send(res, 200, { schemaVersion: 1, runId: run.id, message: run.stoppedMessage }, setCookie);
      }
      return send(res, 404, { error: 'route not found' }, setCookie);
    } catch (error) {
      if (res.headersSent) {
        await writeNdjson(res, { type: 'error', message: await redactText(scrubLocalPaths(error.message || 'request failed')) }).catch(() => {});
        res.end();
        return;
      }
      if (!error.status) {
        log(`Installer UI request failed: ${scrubLocalPaths(error.stack || error.message || error)}`);
        return send(res, 500, { error: 'request failed' });
      }
      return send(res, error.status, error.field ? { schemaVersion: 1, field: error.field, error: error.message, remedy: error.remedy } : { error: error.message, reason: error.reason, operation: error.operation, detail: error.detail, exitCode: error.exitCode });
    } finally {
      if (!activeRun?.state || activeRun.state !== 'running') armIdle();
    }
  });

  server.cleanup = cleanup;
  server.stopServer = stopServer;
  server.token = token;
  server.csrfToken = csrfToken;
  server.listenAsync = async (host = options.host || '127.0.0.1') => {
    liveMode = await checkPowerShell(options);
    if (!liveMode.ok) log(`Installer UI live mode disabled for ${options.pwsh || 'pwsh'}: ${liveMode.reason}`);
    return new Promise((resolveListen) => {
    server.listen(options.port || 0, host, () => {
      port = server.address().port;
      armIdle();
      resolveListen(server.address());
    });
  });
  };
  return server;
}

export async function shutdownInstallerUiServer(server, reason = 'interrupt') {
  await server.cleanup();
  server.closeAllConnections?.();
  return new Promise((resolveShutdown) => {
    server.close(() => {
      server.emit('installer-ui-stopped', reason);
      resolveShutdown(reason);
    });
  });
}

export async function main(argv = process.argv.slice(2)) {
  const hostIndex = argv.indexOf('--host');
  const portIndex = argv.indexOf('--port');
  const idleIndex = argv.indexOf('--idle-ms');
  const allowHostIndex = argv.indexOf('--allow-host');
  const host = hostIndex >= 0 ? argv[hostIndex + 1] : '127.0.0.1';
  const allowHost = allowHostIndex >= 0 ? argv[allowHostIndex + 1] : '';
  if (!isLoopbackBind(host) && !allowHost) {
    throw new Error('A non-loopback --host requires --allow-host <host[:port]>; this exposes the local installer server to that host.');
  }
  const bindWarning = host === '127.0.0.1' ? '' : ' Binding to a non-loopback address exposes this local installer server to the network.';
  const server = await createInstallerUiServer({
    host,
    port: portIndex >= 0 ? Number(argv[portIndex + 1]) : 0,
    idleMs: idleIndex >= 0 ? Number(argv[idleIndex + 1]) : defaultIdleMs,
    allowedHosts: allowHost ? [allowHost] : [],
    log: (line) => console.log(line),
    exitOnStop: true,
  });
  const address = await server.listenAsync(host);
  const displayedHost = allowHost || host;
  const url = `http://${displayedHost.includes(':') ? displayedHost : `${displayedHost}:${address.port}`}/?token=${encodeURIComponent(server.token)}`;
  console.log(`Claude gateway installer UI: ${url}`);
  console.log(`One-time token: ${server.token}`);
  if (bindWarning) console.log(bindWarning);
  console.log('Cloud Shell ends a session after 20 minutes without interactive activity; keep the shell active before long waits.');
  const stopForSignal = async () => {
    await shutdownInstallerUiServer(server, 'interrupt');
    console.log('Installer UI stopped: interrupt');
    process.exit(130);
  };
  process.on('SIGINT', stopForSignal);
  process.on('SIGTERM', stopForSignal);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1])) {
  main().catch((error) => {
    console.error(error.message);
    process.exit(1);
  });
}
