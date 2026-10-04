import assert from 'node:assert/strict';
import { once } from 'node:events';
import { spawn } from 'node:child_process';
import { mkdir, readFile, rm, rmdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { createInstallerUiServer } from '../tools/installer-ui/server.mjs';
import { PROGRESS_EVENTS, STEP_STATES, validatePreflight, validateStepList } from '../tools/installer-ui/installer-contract.mjs';

const repoRoot = fileURLToPath(new URL('..', import.meta.url)).replace(/[\\/]+$/, '');
const stub = fileURLToPath(new URL('./installer-ui-stub.mjs', import.meta.url));

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
    const response = await refused.fetch('/api/run/stream', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ answers: {}, steps: ['resource-group'] }),
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