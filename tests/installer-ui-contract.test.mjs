import assert from 'node:assert/strict';
import { once } from 'node:events';
import { spawn } from 'node:child_process';
import { mkdir, readFile, rm, rmdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { createInstallerUiServer, loadSchema } from '../tools/installer-ui/server.mjs';
import { PROGRESS_EVENTS, STEP_STATES, validatePreflight, validateStepList } from '../tools/installer-ui/installer-contract.mjs';

const repoRoot = fileURLToPath(new URL('..', import.meta.url)).replace(/[\\/]+$/, '');
const stub = fileURLToPath(new URL('./installer-ui-stub.mjs', import.meta.url));
const passingAnswers = { schemaVersion: 1, SubscriptionId: '00000000-0000-4000-8000-000000000093' };

async function runPwsh(args, env = {}) {
  const child = spawn('pwsh', ['-NoProfile', '-NonInteractive', '-File', 'Install-ClaudeGateway.ps1', ...args], {
    cwd: repoRoot,
    shell: false,
    windowsHide: true,
    env: { ...process.env, NO_COLOR: '1', CI: '1', FORCE_COLOR: '0', ...env },
  });
  let stdout = '';
  let stderr = '';
  child.stdout.on('data', (chunk) => { stdout += chunk.toString('utf8'); });
  child.stderr.on('data', (chunk) => { stderr += chunk.toString('utf8'); });
  const [code] = await once(child, 'close');
  return { code, stdout, stderr };
}

async function runStub(args, env = {}) {
  const child = spawn(process.execPath, [stub, 'pwsh', ...args], {
    cwd: repoRoot,
    shell: false,
    windowsHide: true,
    env: { ...process.env, CI: '1', FORCE_COLOR: '0', ...env },
  });
  let stdout = '';
  let stderr = '';
  child.stdout.on('data', (chunk) => { stdout += chunk.toString('utf8'); });
  child.stderr.on('data', (chunk) => { stderr += chunk.toString('utf8'); });
  const [code] = await once(child, 'close');
  return { code, stdout, stderr };
}

function sortedKeys(value) {
  return Object.keys(value).sort();
}

function valueType(value) {
  if (value === null) return 'null';
  if (Array.isArray(value)) return 'array';
  return typeof value;
}

function assertPreflightValueTypes(preflight) {
  assert.equal(valueType(preflight.schemaVersion), 'number');
  assert.equal(valueType(preflight.installer), 'string');
  assert.equal(valueType(preflight.answersSchemaVersion), 'number');
  assert.equal(valueType(preflight.result), 'string');
  assert.equal(valueType(preflight.checks), 'array');
  for (const check of preflight.checks) {
    assert.equal(valueType(check.id), 'string');
    assert.equal(valueType(check.result), 'string');
    assert.equal(valueType(check.message), 'string');
    assert.equal(valueType(check.remedy), 'string');
    assert.equal(valueType(check.problems), 'array');
    if (check.result === 'NOT-RUN') assert.equal(valueType(check.reason), 'string');
    else assert.equal(valueType(check.reason), 'null');
  }
}

function recomputePreflightResult(preflight) {
  const blockingReasons = new Set(['not-signed-in', 'prerequisite-failed', 'not-evaluated']);
  return preflight.checks.some((check) => check.result === 'FAIL' || (check.result === 'NOT-RUN' && blockingReasons.has(check.reason))) ? 'FAIL' : 'PASS';
}

async function start(env = {}) {
  const scratch = join(tmpdir(), 'p93-installer-ui-contract', `${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`);
  await rm(scratch, { recursive: true, force: true });
  await mkdir(scratch, { recursive: true });
  const log = join(scratch, 'stub.ndjson');
  const server = await createInstallerUiServer({
    token: 'contract-token-with-at-least-32-bytes',
    stubInstaller: stub,
    idleMs: 60_000,
    env: { P93_INSTALLER_UI_STUB_LOG: log, ...env },
    readIdentity: async () => ({ signedIn: false, user: '', tenantId: '', subscriptionId: '' }),
  });
  const address = await server.listenAsync('127.0.0.1');
  const base = `http://127.0.0.1:${address.port}`;
  const boot = await fetch(`${base}/?token=${encodeURIComponent(server.token)}`, { redirect: 'manual' });
  const cookie = boot.headers.get('set-cookie').split(';')[0];
  const csrfToken = (await (await fetch(`${base}/api/session`, { headers: { cookie } })).json()).csrfToken;
  return {
    base,
    cookie,
    csrfToken,
    async fetch(path, options = {}) {
      const headers = { cookie, ...(options.headers || {}) };
      if (options.method === 'POST') headers['x-csrf-token'] ??= csrfToken;
      return fetch(`${base}${path}`, { ...options, headers });
    },
    async close() {
      await server.cleanup();
      server.close();
      await once(server, 'close').catch(() => {});
      await rm(scratch, { recursive: true, force: true });
    },
  };
}

test('contract adapter accepts real step list and logged-out preflight output', { timeout: 180_000 }, async () => {
  // The installer trusts a state directory only under a parent that other accounts cannot change (P91), so this
  // scratch sits in the checkout (ignored by git) rather than the system temporary directory.
  const scratch = join(repoRoot, '.p93-installer-ui-real-contract', `${process.pid}-${Date.now()}`);
  const stateDir = join(scratch, 'state-that-does-not-exist-yet');
  const answersPath = join(scratch, 'answers.json');
  await rm(scratch, { recursive: true, force: true });
  await mkdir(scratch, { recursive: true });
  try {
    await writeFile(answersPath, JSON.stringify({
      schemaVersion: 1,
      SubscriptionId: '00000000-0000-4000-8000-000000000093',
      ResourceGroup: 'rg-p93',
      FoundryAccount: 'ai-p93',
      FoundryResourceGroup: 'rg-ai-p93',
    }, null, 2));
    const env = {
      AZURE_CONFIG_DIR: process.env.AZURE_CONFIG_DIR,
      CLAUDE_GATEWAY_STATE_DIR: stateDir,
    };
    const steps = await runPwsh(['-ListSteps', '-Json'], env);
    assert.equal(steps.code, 0, steps.stderr || steps.stdout);
    assert.ok(validateStepList(JSON.parse(steps.stdout)).steps.length >= 10);
    const preflight = await runPwsh(['-AnswersPath', answersPath, '-Preflight', '-Json'], env);
    assert.ok([0, 1].includes(preflight.code), preflight.stderr || preflight.stdout);
    assert.ok(validatePreflight(JSON.parse(preflight.stdout)).checks.length > 0);
  } finally {
    await rm(scratch, { recursive: true, force: true });
    await rmdir(dirname(scratch)).catch(() => {});
  }
});

test('T2 stub step list and preflight stay byte-shape compatible with the real installer', { timeout: 180_000 }, async () => {
  const scratch = join(repoRoot, '.p93-installer-ui-real-contract', `${process.pid}-${Date.now()}`);
  const stateDir = join(scratch, 'state-that-does-not-exist-yet');
  const answersPath = join(scratch, 'answers.json');
  await rm(scratch, { recursive: true, force: true });
  await mkdir(scratch, { recursive: true });
  try {
    await writeFile(answersPath, JSON.stringify({
      schemaVersion: 1,
      SubscriptionId: '00000000-0000-4000-8000-000000000093',
      ResourceGroup: 'rg-p93',
      FoundryAccount: 'ai-p93',
      FoundryResourceGroup: 'rg-ai-p93',
    }, null, 2));
    const env = {
      AZURE_CONFIG_DIR: process.env.AZURE_CONFIG_DIR,
      CLAUDE_GATEWAY_STATE_DIR: stateDir,
    };
    const realStepsRun = await runPwsh(['-ListSteps', '-Json'], env);
    const stubStepsRun = await runStub(['-ListSteps', '-Json']);
    assert.equal(realStepsRun.code, 0, realStepsRun.stderr || realStepsRun.stdout);
    assert.equal(stubStepsRun.code, 0, stubStepsRun.stderr || stubStepsRun.stdout);
    const realSteps = JSON.parse(realStepsRun.stdout);
    const stubSteps = JSON.parse(stubStepsRun.stdout);
    assert.deepEqual(sortedKeys(stubSteps), sortedKeys(realSteps));
    assert.deepEqual(stubSteps.steps.map(({ id, title, dependencies }) => ({ id, title, dependencies })), realSteps.steps.map(({ id, title, dependencies }) => ({ id, title, dependencies })));
    assert.deepEqual([...new Set(stubSteps.steps.map((step) => step.state))].sort(), ['not-started']);
    for (const step of [...realSteps.steps, ...stubSteps.steps]) {
      assert.equal(valueType(step.id), 'string');
      assert.equal(valueType(step.title), 'string');
      assert.equal(valueType(step.dependencies), 'array');
      assert.equal(valueType(step.state), 'string');
      assert.ok(STEP_STATES.includes(step.state), `${step.state} is missing from STEP_STATES`);
    }

    const realPreflightRun = await runPwsh(['-AnswersPath', answersPath, '-Preflight', '-Json'], env);
    const stubPreflightRun = await runStub(['-AnswersPath', answersPath, '-Preflight', '-Json'], { P93_INSTALLER_UI_STUB_SIGNED_OUT: '1' });
    const realPreflight = JSON.parse(realPreflightRun.stdout);
    const stubPreflight = JSON.parse(stubPreflightRun.stdout);
    const expectedCheckIds = (await loadSchema())['x-preflightChecks'].map((check) => check.id).sort();
    assert.deepEqual(sortedKeys(stubPreflight), sortedKeys(realPreflight));
    assert.equal(realPreflightRun.code === 0, realPreflight.result === 'PASS');
    assert.equal(stubPreflightRun.code === 0, stubPreflight.result === 'PASS');
    assert.equal(realPreflight.result, stubPreflight.result);
    assert.equal(realPreflight.result, recomputePreflightResult(realPreflight));
    assert.equal(stubPreflight.result, recomputePreflightResult(stubPreflight));
    assert.deepEqual(new Set(stubPreflight.checks.map((check) => sortedKeys(check).join(','))), new Set(realPreflight.checks.map((check) => sortedKeys(check).join(','))));
    assertPreflightValueTypes(realPreflight);
    assertPreflightValueTypes(stubPreflight);
    assert.deepEqual(realPreflight.checks.map((check) => check.id).sort(), expectedCheckIds);
    assert.deepEqual(stubPreflight.checks.map((check) => check.id).sort(), expectedCheckIds);
    for (const output of [realPreflight, stubPreflight]) {
      const tenant = output.checks.find((check) => check.id === 'target.tenant');
      assert.equal(tenant.result, 'NOT-RUN');
      assert.equal(tenant.reason, 'not-signed-in');
      assert.equal(recomputePreflightResult(output), 'FAIL');
    }
    const results = new Set([...realPreflight.checks, ...stubPreflight.checks].map((check) => check.result));
    for (const result of results) assert.ok(['PASS', 'FAIL', 'NOT-RUN'].includes(result), `${result} is not a preflight result vocabulary member`);
  } finally {
    await rm(scratch, { recursive: true, force: true });
    await rmdir(dirname(scratch)).catch(() => {});
  }
});

test('T2 stub progress lines match the producer progress field contract', async () => {
  const scratch = join(tmpdir(), 'p93-installer-ui-progress', `${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`);
  const progress = join(scratch, 'progress.ndjson');
  const answers = join(scratch, 'answers.json');
  await mkdir(scratch, { recursive: true });
  try {
    await writeFile(answers, JSON.stringify(passingAnswers));
    const run = await runStub(['-AnswersPath', answers, '-ProgressPath', progress, '-Steps', 'resource-group,gateway-deployment', '-Yes', '-NonInteractive']);
    assert.equal(run.code, 0, run.stderr || run.stdout);
    const events = (await readFile(progress, 'utf8')).trim().split(/\r?\n/).map((line) => JSON.parse(line));
    assert.ok(events.length >= 4);
    for (const event of events) {
      assert.deepEqual(Object.keys(event), ['schemaVersion', 'time', 'runId', 'stepId', 'event', 'message', 'resumeCommand']);
      assert.equal(event.schemaVersion, 1);
      assert.match(event.time, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
      assert.match(event.runId, /^[0-9a-f]{32}$/);
      assert.ok(PROGRESS_EVENTS.includes(event.event), `${event.event} is missing from PROGRESS_EVENTS`);
      assert.equal(valueType(event.stepId), 'string');
      assert.equal(valueType(event.message), 'string');
      assert.equal(valueType(event.resumeCommand), 'string');
    }
    const p92StepSelection = await readFile(new URL('./Test-InstallerStepSelection.ps1', import.meta.url), 'utf8');
    assert.match(p92StepSelection, /schemaVersion,time,runId,stepId,event,message,resumeCommand/);
    assert.match(p92StepSelection, /\\d\{4\}-\\d\{2\}-\\d\{2\}T\\d\{2\}:\\d\{2\}:\\d\{2\}Z/);
    assert.match(p92StepSelection, /\[0-9a-f\]\{32\}/);
  } finally {
    await rm(scratch, { recursive: true, force: true });
  }
});

test('contract adapter vocabularies cover producer literals and resume/refusal shapes', async () => {
  const checkpoint = await start({ P93_INSTALLER_UI_STUB_CHECKPOINT_STATES: '1' });
  try {
    const response = await checkpoint.fetch('/api/steps');
    const text = await response.text();
    assert.equal(response.status, 200, text);
    const payload = JSON.parse(text);
    assert.deepEqual(payload.steps.map((step) => step.state), ['started', 'incomplete', 'completed']);
  } finally {
    await checkpoint.close();
  }

  const refused = await start({ P93_INSTALLER_UI_STUB_REFUSED_PROGRESS: '1' });
  try {
    const preflight = await (await refused.fetch('/api/preflight', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ answers: passingAnswers, steps: ['resource-group'] }),
    })).json();
    const response = await refused.fetch('/api/run/stream', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ answers: passingAnswers, steps: ['resource-group'], fingerprint: preflight.fingerprint }),
    });
    const events = (await response.text()).trim().split(/\r?\n/).filter(Boolean).map((line) => JSON.parse(line));
    assert.ok(events.some((event) => event.type === 'progress' && event.event === 'refused' && event.stepId === ''));
    assert.ok(events.some((event) => /Refused: nothing was changed/.test(event.message || '')));
    assert.equal(events.find((event) => event.type === 'summary').failedStepId, '');
  } finally {
    await refused.close();
  }
});

test('contract vocabulary drift detector reads producer sources', async () => {
  const checkpointSource = await readFile(new URL('../scripts/ClaudeInstallCheckpoint.ps1', import.meta.url), 'utf8');
  const resumeSource = await readFile(new URL('../scripts/ClaudeInstallResume.ps1', import.meta.url), 'utf8');
  const stepSource = await readFile(new URL('../scripts/ClaudeInstallSteps.ps1', import.meta.url), 'utf8');
  // Every state a producer writes into the checkpoint, and the one -ListSteps adds.
  const states = new Set();
  for (const source of [checkpointSource, resumeSource]) for (const match of source.matchAll(/-State\s+'([a-z-]+)'/g)) states.add(match[1]);
  const completion = checkpointSource.match(/\$state = if \(\$Incomplete\) \{ '([a-z-]+)' \} else \{ '([a-z-]+)' \}/);
  assert.ok(completion, 'Complete-ClaudeInstallStep state literals are found');
  states.add(completion[1]).add(completion[2]);
  const listed = stepSource.match(/state = \$\(if \(\$s\) \{ \[string\]\$s\.state \} else \{ '([a-z-]+)' \}\)/);
  assert.ok(listed, 'the -ListSteps default state literal is found');
  states.add(listed[1]);
  assert.ok(states.size >= 4, `the detector found the producer states: ${[...states].join(', ')}`);
  for (const state of states) assert.ok(STEP_STATES.includes(state), `${state} is missing from STEP_STATES`);
  // Every progress event: the step-event ValidateSet and every literal -Event value.
  const events = new Set();
  const validateSet = stepSource.match(/\[ValidateSet\(([^)]*)\)\]\[string\]\$Event/)?.[1] || '';
  for (const match of validateSet.matchAll(/'([^']+)'/g)) events.add(match[1]);
  for (const match of stepSource.matchAll(/-Event\s+'([a-z-]+)'/g)) events.add(match[1]);
  assert.ok(events.size >= 6, `the detector found the producer events: ${[...events].join(', ')}`);
  for (const event of events) assert.ok(PROGRESS_EVENTS.includes(event), `${event} is missing from PROGRESS_EVENTS`);
});