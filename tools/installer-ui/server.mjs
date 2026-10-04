import { createServer as createHttpServer } from 'node:http';
import { spawn } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { StringDecoder } from 'node:string_decoder';
import { once } from 'node:events';
import { mkdtemp, open, readFile, rm, writeFile, chmod } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { validatePreflight, validateProgressEvent, validateStepList } from './installer-contract.mjs';
import { assertSameOrigin, constantTimeTokenEquals, contentSecurityPolicy, isAllowedHost, isLoopbackBind, parseCookies, readJsonBody, send, sendText, tokenHash } from './http-helpers.mjs';
import { renderHtml } from './page-template.mjs';
import { buildCommands, fieldsByCheckId, loadSchema, prefillArguments, redactText, root, scrubLocalPaths } from './server-model.mjs';

export { buildCommands, loadSchema, redactText, scrubLocalPaths } from './server-model.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const psInstaller = join(root, 'Install-ClaudeGateway.ps1');
const bashInstaller = join(root, 'install-claude-gateway.sh');
const identityScript = join(root, 'scripts', 'Get-ClaudeInstallerUiIdentity.ps1');
const prefillScript = join(root, 'scripts', 'Get-ClaudeInstallerUiPrefill.ps1');
const planScript = join(root, 'scripts', 'Get-ClaudeInstallerUiPlan.ps1');
const uiScript = join(here, 'installer-ui.js');
const uiModelScript = join(here, 'ui-model.js');
const uiCss = join(here, 'installer-ui.css');
const defaultIdleMs = 30 * 60 * 1000;
const consoleOutputCapBytes = 4 * 1024 * 1024;
const consoleLineCapBytes = 64 * 1024;
const runTailLimit = 1000;


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

async function waitForDrain(res) {
  if (res.destroyed || res.writableEnded) return;
  await once(res, 'drain').catch(() => {});
}

function reqDone(res) {
  return Promise.race([
    once(res, 'close'),
    once(res, 'finish'),
  ]);
}

async function writeNdjson(res, payload) {
  if (res.destroyed || res.writableEnded) return false;
  const ok = res.write(`${JSON.stringify(payload)}\n`);
  if (!ok) await waitForDrain(res);
  return !res.destroyed && !res.writableEnded;
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
  let stdout = '';
  let stderr = '';
  child.stdout.on('data', (chunk) => { stdout += chunk.toString('utf8'); });
  child.stderr.on('data', (chunk) => { stderr += chunk.toString('utf8'); });
  const timeoutMs = Number(runOptions.timeoutMs || 0);
  let timer;
  let timedOut = false;
  const code = await new Promise((resolveCode, reject) => {
    if (timeoutMs > 0) {
      timer = setTimeout(() => {
        timedOut = true;
        void killProcessTree(child);
      }, timeoutMs);
      timer.unref?.();
    }
    child.on('error', reject);
    child.on('close', resolveCode);
  });
  if (timer) clearTimeout(timer);
  if (timedOut) {
    const error = new Error(`${runOptions.readName || 'installer read'} timed out after ${timeoutMs} ms`);
    error.status = 504;
    throw error;
  }
  return { code, stdout: await redactText(stdout), stderr: await redactText(stderr) };
}

async function runPowerShell(script, args, options, runOptions = {}) {
  const child = spawnChild('pwsh', ['-NoProfile', '-NonInteractive', '-File', script, ...args], options);
  let stdout = '';
  let stderr = '';
  child.stdout.on('data', (chunk) => { stdout += chunk.toString('utf8'); });
  child.stderr.on('data', (chunk) => { stderr += chunk.toString('utf8'); });
  const timeoutMs = Number(runOptions.timeoutMs || 0);
  let timer;
  let timedOut = false;
  const code = await new Promise((resolveCode, reject) => {
    if (timeoutMs > 0) {
      timer = setTimeout(() => {
        timedOut = true;
        void killProcessTree(child);
      }, timeoutMs);
      timer.unref?.();
    }
    child.on('error', reject);
    child.on('close', resolveCode);
  });
  if (timer) clearTimeout(timer);
  if (timedOut) {
    const error = new Error(`${runOptions.readName || 'read-only installer child'} timed out after ${timeoutMs} ms`);
    error.status = 504;
    throw error;
  }
  return {
    code,
    stdout: runOptions.redactStdout === false ? stdout : await redactText(stdout),
    stderr: await redactText(stderr),
  };
}

async function runInstallerStreaming(kind, args, options, onEvent, progressPath, runOptions = {}) {
  const command = spawnInstallerArgs(kind, args, options);
  const child = spawnChild(command.file, command.args, options);
  runOptions.onChild?.(child);
  let progressOffset = 0;
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
  const makeLineHandler = (type) => {
    const decoder = new StringDecoder('utf8');
    let carry = '';
    let work = Promise.resolve();
    let discarding = false;
    const emitBounded = async (line, final = false) => {
      if (discarding) {
        if (final) discarding = false;
        return;
      }
      const bytes = Buffer.byteLength(line);
      if (bytes > consoleLineCapBytes) {
        await emitConsoleLine(type, `${Buffer.from(line).subarray(0, consoleLineCapBytes).toString('utf8')} [line truncated]`);
        discarding = !final;
      } else if (line) {
        await emitConsoleLine(type, line);
      }
    };
    return {
      chunk(chunk) {
        work = work.then(async () => {
        carry += decoder.write(chunk);
        const lines = carry.split(/\r?\n/);
        carry = lines.pop() || '';
        for (const line of lines) await emitBounded(line, true);
        if (Buffer.byteLength(carry) > consoleLineCapBytes) {
          await emitBounded(carry, false);
          carry = '';
        }
        });
        return work;
      },
      async end() {
        await work;
        carry += decoder.end();
        if (carry) await emitBounded(carry, true);
        carry = '';
      },
    };
  };
  const stdout = makeLineHandler('stdout');
  const stderr = makeLineHandler('stderr');
  child.stdout.on('data', (chunk) => { void stdout.chunk(chunk); });
  child.stderr.on('data', (chunk) => { void stderr.chunk(chunk); });
  const progressDecoder = new StringDecoder('utf8');
  const processProgressText = async (text, final) => {
    progressCarry += text;
    const lines = progressCarry.split(/\r?\n/);
    progressCarry = lines.pop() || '';
    if (final && progressCarry) {
      lines.push(progressCarry);
      progressCarry = '';
    }
    for (const line of lines) {
      if (!line) continue;
      try {
        const event = validateProgressEvent(JSON.parse(line));
        if (event.message) event.message = await redactText(event.message);
        if (event.resumeCommand) event.resumeCommand = await redactText(event.resumeCommand);
        await enqueue({ type: 'progress', ...event });
      } catch (error) {
        await enqueue({ type: 'error', message: await redactText(`progress parse failed: ${error.message}`) });
      }
    }
  };
  const readProgress = async (final = false) => {
    if (!progressPath || !existsSync(progressPath)) return;
    const file = await open(progressPath, 'r');
    try {
      const stat = await file.stat();
      if (stat.size <= progressOffset && !final) return;
      const length = stat.size - progressOffset;
      if (length > 0) {
        const buffer = Buffer.alloc(length);
        await file.read(buffer, 0, length, progressOffset);
        progressOffset = stat.size;
        await processProgressText(progressDecoder.write(buffer), final);
      } else if (final) {
        await processProgressText('', true);
      }
    } finally {
      await file.close();
    }
  };
  const timer = setInterval(() => { progressReading = progressReading.then(() => readProgress(false)).catch((error) => enqueue({ type: 'error', message: `progress read failed: ${error.message}` })); }, 100);
  const code = await new Promise((resolveCode, reject) => {
    child.on('error', reject);
    child.on('close', resolveCode);
  });
  clearInterval(timer);
  await Promise.all([
    child.stdout.readableEnded ? Promise.resolve() : once(child.stdout, 'end').catch(() => {}),
    child.stderr.readableEnded ? Promise.resolve() : once(child.stderr, 'end').catch(() => {}),
  ]);
  await stdout.end();
  await stderr.end();
  await progressReading;
  await processProgressText(progressDecoder.end(), false);
  await readProgress(true);
  await emitQueue;
  return code;
}

async function listSteps(options, timeoutMs = 60_000) {
  const result = await runInstaller('powershell', ['-ListSteps', '-Json'], options, { timeoutMs, readName: 'step list' });
  if (result.code !== 0) throw new Error(`step list failed: ${result.stderr || result.stdout}`);
  return validateStepList(JSON.parse(result.stdout));
}

function flattenStepIds(stepPayload) {
  const steps = Array.isArray(stepPayload) ? stepPayload : Array.isArray(stepPayload.steps) ? stepPayload.steps : [];
  return new Set(steps.map((step) => String(step.id || step.stepId || '')).filter(Boolean));
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

export async function createInstallerUiServer(options = {}) {
  const token = options.token || randomBytes(32).toString('base64url');
  const tokenDigest = tokenHash(token);
  const csrfToken = options.csrfToken || randomBytes(32).toString('base64url');
  const tempDirs = new Set();
  let port = Number(options.port || 0);
  let tokenConsumed = false;
  let activeRun = null;
  let lastRun = null;
  let idleTimer = null;
  let stopping = false;
  let inFlight = 0;
  options._children = new Set();
  const idleMs = Number(options.idleMs || defaultIdleMs);
  const timeoutFor = (name) => Number(options.readOnlyTimeoutMs || ({ steps: 60_000, identity: 120_000, prefill: 120_000, preflight: 600_000, plan: 120_000 }[name]));
  const extraHosts = options.allowedHosts || [];
  const log = options.log || (() => {});

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

  const assertFetchMetadataForChildGet = (request) => {
    const fetchSite = request.headers['sec-fetch-site'];
    if (fetchSite && fetchSite !== 'same-origin' && fetchSite !== 'none') {
      const error = new Error('same-origin request required');
      error.status = 403;
      throw error;
    }
  };

  const publicRun = (run, includeTail = false) => run && ({
    id: run.id,
    steps: run.steps,
    state: run.state,
    currentStepId: run.currentStepId,
    exitCode: run.exitCode,
    failedStepId: run.failedStepId,
    resumeCommand: run.resumeCommand,
    startTime: run.startTime,
    nextSeq: run.nextSeq,
    stoppedMessage: run.stoppedMessage,
    tempDirRemoved: run.tempDirRemoved,
    events: includeTail ? run.tail : undefined,
  });

  const publish = async (run, event) => {
    const item = { seq: run.nextSeq++, ...event };
    run.tail.push(item);
    if (run.tail.length > runTailLimit) run.tail.splice(0, run.tail.length - runTailLimit);
    if (item.type === 'progress' && item.event === 'started') run.currentStepId = item.stepId || run.currentStepId;
    if (item.type === 'progress' && item.event === 'failed') {
      run.failedStepId = item.stepId || '';
      run.resumeCommand = item.resumeCommand || (run.failedStepId ? `Install-ClaudeGateway.ps1 -Steps ${run.failedStepId}` : '');
    }
    await Promise.all([...run.subscribers].map((subscriber) => subscriber.enqueue()));
  };

  const attachRun = async (run, res, after) => {
    if (!Number.isInteger(after) || after < 0) {
      const error = new Error('after must be a non-negative integer');
      error.status = 400;
      throw error;
    }
    res.writeHead(200, {
      'content-type': 'application/x-ndjson; charset=utf-8',
      'cache-control': 'no-store',
      'content-security-policy': contentSecurityPolicy(),
      'x-content-type-options': 'nosniff',
    });
    let closed = false;
    const subscriber = {
      cursor: after,
      writing: false,
      enqueue() {
        return this.flush();
      },
      async flush() {
        if (this.writing) return;
        this.writing = true;
        try {
          for (;;) {
            if (closed) return;
            const firstSeq = run.tail[0]?.seq ?? run.nextSeq;
            if (this.cursor < firstSeq - 1) {
              const skipped = firstSeq - this.cursor - 1;
              this.cursor = firstSeq - 1;
              if (!await writeNdjson(res, { seq: this.cursor, type: 'notice', skippedEvents: skipped, message: 'Earlier run events fell out of the bounded tail.' })) return;
            }
            const next = run.tail.find((event) => event.seq > this.cursor);
            if (!next) return;
            if (!await writeNdjson(res, next)) return;
            this.cursor = next.seq;
            if (next.type === 'summary') {
              closed = true;
              res.end();
              return;
            }
          }
        } finally {
          this.writing = false;
          if (!closed && run.tail.some((event) => event.seq > this.cursor)) void this.flush();
        }
      },
      end() {
        if (!closed) res.end();
      },
    };
    if (run.state === 'running' || run.state === 'stopping') run.subscribers.add(subscriber);
    subscriber.enqueue();
    reqDone(res).then(() => { closed = true; run.subscribers.delete(subscriber); }).catch(() => {});
  };

  const createRun = (steps) => {
    if (activeRun?.state === 'running' || activeRun?.state === 'stopping') return null;
    const run = {
      id: randomBytes(16).toString('hex'),
      steps,
      state: 'running',
      currentStepId: '',
      exitCode: null,
      failedStepId: '',
      resumeCommand: '',
      startTime: new Date().toISOString(),
      nextSeq: 1,
      tail: [],
      subscribers: new Set(),
      child: null,
      tempDir: '',
      progressPath: '',
      stoppedMessage: '',
      tempDirRemoved: false,
    };
    activeRun = run;
    lastRun = run;
    return run;
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
        res.writeHead(303, {
          location: './',
          'set-cookie': `installer_token=${encodeURIComponent(queryToken)}; HttpOnly; SameSite=Strict; Path=/`,
          'content-security-policy': contentSecurityPolicy(),
          'x-content-type-options': 'nosniff',
          'referrer-policy': 'no-referrer',
        });
        res.end();
        return;
      }
      if (!constantTimeTokenEquals(String(cookieToken || ''), tokenDigest)) return send(res, 401, { error: 'installer token is required' });
      const setCookie = {};
      if (req.method === 'GET' && url.pathname === '/api/session') return send(res, 200, { schemaVersion: 1, csrfToken }, setCookie);
      if (req.method === 'POST') {
        if (!String(req.headers['content-type'] || '').toLowerCase().startsWith('application/json')) return send(res, 415, { error: 'Content-Type application/json is required' }, setCookie);
        if (!constantTimeTokenEquals(String(req.headers['x-csrf-token'] || ''), tokenHash(csrfToken))) return send(res, 403, { error: 'CSRF token is required' }, setCookie);
      }

      if (req.method === 'GET' && (url.pathname === '/' || url.pathname === '/index.html')) return send(res, 200, await renderHtml(loadSchema), setCookie);
      if (req.method === 'GET' && url.pathname === '/installer-ui.js') return sendText(res, 200, await readFile(uiScript, 'utf8'), 'text/javascript; charset=utf-8', setCookie);
      if (req.method === 'GET' && url.pathname === '/ui-model.js') return sendText(res, 200, await readFile(uiModelScript, 'utf8'), 'text/javascript; charset=utf-8', setCookie);
      if (req.method === 'GET' && url.pathname === '/installer-ui.css') return sendText(res, 200, await readFile(uiCss, 'utf8'), 'text/css; charset=utf-8', setCookie);
      if (req.method === 'GET' && url.pathname === '/api/schema') return send(res, 200, await loadSchema(), setCookie);
      if (req.method === 'GET' && url.pathname === '/api/steps') {
        assertFetchMetadataForChildGet(req);
        return send(res, 200, await withJob(() => listSteps(options, timeoutFor('steps'))), setCookie);
      }
      if (req.method === 'GET' && url.pathname === '/api/identity') {
        assertFetchMetadataForChildGet(req);
        const result = await withJob(() => runPowerShell(identityScript, [], options, { timeoutMs: timeoutFor('identity'), readName: 'identity' }));
        return send(res, 200, JSON.parse(result.stdout), setCookie);
      }
      if (req.method === 'GET' && url.pathname === '/api/run/status') return send(res, 200, { schemaVersion: 1, ...(publicRun(activeRun || lastRun) || {}) }, setCookie);
      if (req.method === 'GET' && url.pathname === '/api/run/attach') {
        const run = activeRun || lastRun;
        if (!run) return send(res, 404, { error: 'no installer run is available' }, setCookie);
        await attachRun(run, res, Number(url.searchParams.get('after') || 0));
        return;
      }
      if (req.method === 'POST' && url.pathname === '/api/prefill') {
        assertSameOrigin(req);
        const body = await readJsonBody(req);
        const args = prefillArguments(body);
        const result = await withJob(() => runPowerShell(prefillScript, args, options, { redactStdout: false, timeoutMs: timeoutFor('prefill'), readName: 'prefill' }));
        if (!result.stdout.trim()) {
          log(`Prefill returned no JSON (exit ${result.code}): ${scrubLocalPaths(result.stderr)}`);
          return send(res, 500, { schemaVersion: 1, error: 'The prefill read returned no result. The terminal that started the installer UI shows the details.' }, setCookie);
        }
        const parsed = JSON.parse(result.stdout);
        if (parsed.error) parsed.error = scrubLocalPaths(await redactText(parsed.error));
        return send(res, parsed.field ? 400 : 200, parsed, setCookie);
      }
      if (req.method === 'POST' && url.pathname === '/api/commands') {
        const body = await readJsonBody(req);
        return send(res, 200, buildCommands(body.answersPath || './answers.json', await loadSchema()), setCookie);
      }
      if (req.method === 'POST' && url.pathname === '/api/plan') {
        assertSameOrigin(req);
        const body = await readJsonBody(req);
        return send(res, 200, await withJob(() => withRunDirectory(async (dir) => {
          const answers = await writeAnswers(dir, body.answers || {});
          const result = await runPowerShell(planScript, ['-AnswersPath', answers], options, { timeoutMs: timeoutFor('plan'), readName: 'plan' });
          return JSON.parse(result.stdout);
        }, tempDirs)), setCookie);
      }
      if (req.method === 'POST' && url.pathname === '/api/preflight') {
        assertSameOrigin(req);
        const body = await readJsonBody(req);
        return send(res, 200, await withJob(() => withRunDirectory(async (dir) => {
          const answers = await writeAnswers(dir, body.answers || {});
          const result = await runInstaller('powershell', ['-AnswersPath', answers, '-Preflight', '-Json'], options, { timeoutMs: timeoutFor('preflight'), readName: 'preflight' });
          let parsed;
          try { parsed = validatePreflight(JSON.parse(result.stdout)); } catch (error) {
            if (error.status === 502) throw error;
            const detail = scrubLocalPaths(await redactText(`${result.stdout}\n${result.stderr}`)).trim().slice(-1000);
            const malformed = new Error('preflight output was not JSON; the installer output is shown in detail.');
            malformed.status = 502;
            malformed.detail = detail;
            malformed.exitCode = result.code;
            throw malformed;
          }
          return { exitCode: result.code, preflight: parsed, stdout: result.stdout, stderr: result.stderr, fieldsByCheckId: fieldsByCheckId(await loadSchema()) };
        }, tempDirs)), setCookie);
      }
      if (req.method === 'POST' && url.pathname === '/api/run/stream') {
        assertSameOrigin(req);
        if (activeRun?.state === 'running' || activeRun?.state === 'stopping') return send(res, 409, { error: 'an installer run is already active' }, setCookie);
        const body = await readJsonBody(req);
        const steps = await validateRunRequest(body, options);
        const run = createRun(steps);
        if (!run) return send(res, 409, { error: 'an installer run is already active' }, setCookie);
        const dir = await mkdtemp(join(tmpdir(), 'claude-installer-ui-'));
        tempDirs.add(dir);
        try { await chmod(dir, 0o700); } catch { /* Windows ACLs are inherited; the directory is still per-run. */ }
        run.tempDir = dir;
        const answers = await writeAnswers(dir, body.answers || {});
        const progress = join(dir, 'progress.ndjson');
        run.progressPath = progress;
        const args = ['-AnswersPath', answers, '-Yes', '-ProgressPath', progress];
        if (steps.length) args.push('-Steps', steps.join(','));
        await attachRun(run, res, 0);
        void (async () => {
          try {
            const code = await runInstallerStreaming('powershell', args, options, async (event) => {
              await publish(run, event);
            }, progress, { onChild: (child) => { run.child = child; } });
            run.exitCode = code;
            run.state = run.state === 'stopping' ? 'stopped' : 'exited';
          } catch (error) {
            run.exitCode = 1;
            run.state = run.state === 'stopping' ? 'stopped' : 'exited';
            await publish(run, { type: 'error', message: await redactText(scrubLocalPaths(error.message)) });
          } finally {
            if (run.failedStepId && !run.resumeCommand) run.resumeCommand = `Install-ClaudeGateway.ps1 -Steps ${run.failedStepId}`;
            await publish(run, { type: 'summary', exitCode: run.exitCode, failedStepId: run.failedStepId, resumeCommand: run.resumeCommand, state: run.state, message: run.stoppedMessage });
            for (const subscriber of [...run.subscribers]) {
              await subscriber.flush?.();
              subscriber.end?.();
            }
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
        assertSameOrigin(req);
        const body = await readJsonBody(req);
        const run = activeRun || lastRun;
        if (!run || run.id !== body.runId || (run.state !== 'running' && run.state !== 'stopping')) return send(res, 404, { error: 'active run not found' }, setCookie);
        run.state = 'stopping';
        const step = run.currentStepId || run.steps[0] || 'the current step';
        run.stoppedMessage = `Stopped installer run at ${step}. The install checkpoint resumes when the same steps run again.`;
        await publish(run, { type: 'stopped', stepId: step, message: run.stoppedMessage });
        await killProcessTree(run.child);
        return send(res, 200, { schemaVersion: 1, runId: run.id, message: run.stoppedMessage }, setCookie);
      }
      if (req.method === 'POST' && url.pathname === '/api/run') {
        return send(res, 404, { error: 'route not found' }, setCookie);
      }
      return send(res, 404, { error: 'route not found' }, setCookie);
    } catch (error) {
      if (res.headersSent) {
        await writeNdjson(res, { type: 'error', message: await redactText(scrubLocalPaths(error.message || 'request failed')) }).catch(() => {});
        res.end();
        return;
      }
      if (!error.status) return send(res, 500, { error: 'request failed' });
      return send(res, error.status, error.field ? { schemaVersion: 1, field: error.field, error: error.message, remedy: error.remedy } : { error: error.message, detail: error.detail, exitCode: error.exitCode });
    } finally {
      if (!activeRun?.state || activeRun.state !== 'running') armIdle();
    }
  });

  server.cleanup = cleanup;
  server.stopServer = stopServer;
  server.token = token;
  server.csrfToken = csrfToken;
  server.listenAsync = (host = options.host || '127.0.0.1') => new Promise((resolveListen) => {
    server.listen(options.port || 0, host, () => {
      port = server.address().port;
      armIdle();
      resolveListen(server.address());
    });
  });
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
  process.on('SIGINT', async () => {
    await shutdownInstallerUiServer(server, 'interrupt');
    console.log('Installer UI stopped: interrupt');
    process.exit(130);
  });
}

if (process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1])) {
  main().catch((error) => {
    console.error(error.message);
    process.exit(1);
  });
}
