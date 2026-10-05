import { appendFileSync, readFileSync, writeFileSync } from 'node:fs';
import { spawn } from 'node:child_process';

const [, , mode, ...args] = process.argv;
const log = process.env.P93_INSTALLER_UI_STUB_LOG;
const callRecord = { mode, args };
if (process.env.P93_INSTALLER_UI_STUB_TIMES) callRecord.startedAt = Date.now();
if (log && !process.env.P93_INSTALLER_UI_STUB_TIMES) appendFileSync(log, JSON.stringify(callRecord) + '\n');
const finish = (code) => {
  if (log && process.env.P93_INSTALLER_UI_STUB_TIMES) appendFileSync(log, JSON.stringify({ ...callRecord, endedAt: Date.now() }) + '\n');
  process.exit(code);
};

function argValue(name) {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : '';
}

const runId = '0123456789abcdef0123456789abcdef';
const time = () => new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
const progressLine = (item) => JSON.stringify({
  schemaVersion: 1,
  time: time(),
  runId,
  stepId: item.stepId ?? '',
  event: item.event,
  message: item.message ?? '',
  resumeCommand: item.resumeCommand ?? '',
});
// The real step ids, titles and dependencies: scripts/ClaudeInstallCheckpoint.ps1:8-11 and scripts/ClaudeInstallSteps.ps1:9-11.
const realSteps = [
  ['claude-deployment', 'Claude deployment', []],
  ['resource-group', 'Resource group', []],
  ['gateway-deployment', 'Gateway deployment', ['resource-group']],
  ['company-address', 'Company address', ['gateway-deployment']],
  ['entra-groups', 'Entra groups', []],
  ['sync', 'Sync entitlement', ['gateway-deployment', 'entra-groups']],
  ['projection', 'Projection deployment', ['gateway-deployment']],
  ['business-units', 'Business units', ['gateway-deployment']],
  ['onboarding-package', 'Onboarding package', ['gateway-deployment']],
  ['verify', 'Verification', ['gateway-deployment']],
];
const stepTitle = (id) => realSteps.find(([stepId]) => stepId === id)?.[1] || id;

// The installer's own children (pwsh starting az) outlive it unless the whole tree is stopped. A Node child that is not
// detached ends with its Node parent on Windows (libuv UV_PROCESS_DETACHED, docs.libuv.org/en/v1.x/process.html), so the
// heartbeat grandchild is detached there and only a tree kill (taskkill /T) ends it. It still exits 10 s after its parent
// is gone, well after the tests' 500 ms check, so a missed tree kill fails the test without leaving a process behind.
function startHeartbeatGrandchild(heartbeat) {
  const script = "const {appendFileSync}=require('fs'); const parent=Number(process.argv[2]); let goneSince=0; setInterval(()=>{ appendFileSync(process.argv[1], Date.now()+'\\n'); try { process.kill(parent, 0); goneSince=0; } catch { goneSince=goneSince||Date.now(); if (Date.now()-goneSince>10000) process.exit(0); } },100);";
  return spawn(process.execPath, ['-e', script, heartbeat, String(process.pid)], { stdio: 'ignore', detached: process.platform === 'win32', windowsHide: true });
}

if (args.includes('-ListSteps')) {
  if (process.env.P93_INSTALLER_UI_STUB_BAD_LIST === 'version') {
    console.log(JSON.stringify({ schemaVersion: 2, installer: 'pwsh', checkpoint: null, runId: null, steps: [] }));
    finish(0);
  }
  if (process.env.P93_INSTALLER_UI_STUB_BAD_LIST === 'missing') {
    console.log(JSON.stringify({ schemaVersion: 1, installer: 'pwsh', checkpoint: null, runId: null }));
    finish(0);
  }
  if (process.env.P93_INSTALLER_UI_STUB_BAD_LIST === 'type') {
    console.log(JSON.stringify({ schemaVersion: 1, installer: 'pwsh', checkpoint: null, runId: null, steps: [{ id: 1, title: 'bad', dependencies: [], state: 'not-started' }] }));
    finish(0);
  }
  if (process.env.P93_INSTALLER_UI_STUB_CHECKPOINT_STATES) {
    console.log(JSON.stringify({
      schemaVersion: 1,
      installer: 'pwsh',
      checkpoint: 'checkpoint.json',
      runId: runId,
      steps: [
        { id: 'resource-group', title: 'resource group', dependencies: [], state: 'started' },
        { id: 'gateway-deployment', title: 'gateway deployment', dependencies: ['resource-group'], state: 'incomplete' },
        { id: 'verify', title: 'verify', dependencies: ['gateway-deployment'], state: 'completed' },
      ],
    }));
    finish(0);
  }
  console.log(JSON.stringify({
    schemaVersion: 1,
    installer: 'pwsh',
    checkpoint: null,
    runId: null,
    steps: realSteps.map(([id, title, dependencies]) => ({ id, title, dependencies, state: 'not-started' })),
  }));
  finish(0);
}

const answersPath = argValue('-AnswersPath');
const answers = answersPath ? JSON.parse(readFileSync(answersPath, 'utf8')) : {};
if (args.includes('-Preflight')) {
  if (process.env.P93_INSTALLER_UI_STUB_PREFLIGHT_HANG) {
    const heartbeat = process.env.P93_INSTALLER_UI_STUB_PREFLIGHT_HANG;
    const child = startHeartbeatGrandchild(heartbeat);
    appendFileSync(`${heartbeat}.pid`, `${process.pid}\n${child.pid}\n`);
    await new Promise(() => {});
  }
  if (process.env.P93_INSTALLER_UI_STUB_PREFLIGHT_DELAY_MS) await new Promise((resolve) => setTimeout(resolve, Number(process.env.P93_INSTALLER_UI_STUB_PREFLIGHT_DELAY_MS)));
  if (process.env.P93_INSTALLER_UI_STUB_PREFLIGHT_MULTIBYTE) {
    const value = Buffer.from('split 😀 line\n');
    process.stdout.write(value.subarray(0, 8));
    await new Promise((resolve) => setTimeout(resolve, 20));
    process.stdout.write(value.subarray(8));
    finish(2);
  }
  if (process.env.P93_INSTALLER_UI_STUB_PREFLIGHT_LARGE_STDOUT) {
    process.stdout.write('x'.repeat(Number(process.env.P93_INSTALLER_UI_STUB_PREFLIGHT_LARGE_STDOUT)));
    finish(2);
  }
  if (process.env.P93_INSTALLER_UI_STUB_PREFLIGHT_TEXT) {
    console.log(`preflight could not parse password=super-secret at ${answersPath}`);
    finish(2);
  }
  if (process.env.P93_INSTALLER_UI_STUB_BAD_PREFLIGHT === 'version') {
    console.log(JSON.stringify({ schemaVersion: 2, installer: 'pwsh', answersSchemaVersion: 1, result: 'PASS', checks: [] }));
    finish(0);
  }
  if (process.env.P93_INSTALLER_UI_STUB_BAD_PREFLIGHT === 'missing') {
    console.log(JSON.stringify({ schemaVersion: 1, installer: 'pwsh', answersSchemaVersion: 1, checks: [] }));
    finish(0);
  }
  if (process.env.P93_INSTALLER_UI_STUB_BAD_PREFLIGHT === 'type') {
    console.log(JSON.stringify({ schemaVersion: 1, installer: 'pwsh', answersSchemaVersion: 1, result: 'PASS', checks: [{ id: 'x', result: 1 }] }));
    finish(0);
  }
  if (process.env.P93_INSTALLER_UI_STUB_PREFLIGHT_FAIL_ON_SECOND) {
    const counterPath = process.env.P93_INSTALLER_UI_STUB_PREFLIGHT_FAIL_ON_SECOND;
    let count = 0;
    try { count = Number(readFileSync(counterPath, 'utf8')); } catch { count = 0; }
    writeFileSync(counterPath, String(count + 1));
    if (count >= 1) process.env.P93_INSTALLER_UI_STUB_PREFLIGHT_FAIL = '1';
  }
  const fail = process.env.P93_INSTALLER_UI_STUB_PREFLIGHT_FAIL === '1';
  const noCurrentSubscription = process.env.P93_INSTALLER_UI_STUB_NO_CURRENT_SUBSCRIPTION === '1' && !answers.SubscriptionId;
  const overallFail = fail || noCurrentSubscription;
  const targetSubscription = answers.SubscriptionId
    ? { id: 'target.subscription', result: 'PASS', reason: null, message: `subscription Capture subscription (${answers.SubscriptionId})`, remedy: '', problems: [] }
    : noCurrentSubscription
      ? { id: 'target.subscription', result: 'FAIL', reason: null, message: 'the current subscription could not be read (az account show returned no subscription id)', remedy: 'Check az account show, or answer SubscriptionId, then run the preflight again.', problems: [{ message: 'the current subscription could not be read (az account show returned no subscription id)', remedy: 'Check az account show, or answer SubscriptionId, then run the preflight again.' }] }
      : { id: 'target.subscription', result: 'PASS', reason: null, message: 'SubscriptionId is not answered; the run uses the current subscription Capture subscription (00000000-0000-4000-8000-000000000093)', remedy: '', problems: [] };
  console.log(JSON.stringify({
    schemaVersion: 1,
    installer: 'pwsh',
    answersSchemaVersion: 1,
    result: overallFail ? 'FAIL' : 'PASS',
    checks: [
      { id: 'target.tenant', result: process.env.P93_INSTALLER_UI_STUB_SIGNED_IN === '1' ? 'PASS' : 'NOT-RUN', reason: process.env.P93_INSTALLER_UI_STUB_SIGNED_IN === '1' ? null : 'not-signed-in', message: process.env.P93_INSTALLER_UI_STUB_SIGNED_IN === '1' ? `signed in as ${process.env.P93_INSTALLER_UI_STUB_USER || 'operator@example.invalid'} in tenant ${process.env.P93_INSTALLER_UI_STUB_TENANT || 'tenant-capture'}` : 'Azure CLI is not signed in', remedy: process.env.P93_INSTALLER_UI_STUB_SIGNED_IN === '1' ? '' : 'Run az login --use-device-code.', problems: [] },
      targetSubscription,
      { id: 'answers.schema', result: fail ? 'FAIL' : 'PASS', reason: null, message: fail ? 'stub requested answers.schema failure' : 'the answers match the answers schema, version 1', remedy: fail ? 'Fix the stub-requested failure.' : '', problems: fail ? [{ message: 'stub requested answers.schema failure', remedy: 'Fix the stub-requested failure.' }] : [] },
    ],
  }));
  finish(process.env.P93_INSTALLER_UI_STUB_PREFLIGHT_PASS_EXIT_1 === '1' ? 1 : (overallFail ? 1 : 0));
}

if (args.includes('-Yes')) {
  const stepsArg = argValue('-Steps');
  const steps = stepsArg ? stepsArg.split(',') : ['resource-group', 'gateway-deployment'];
  const progressPath = argValue('-ProgressPath');
  let shouldFail = process.env.P93_INSTALLER_UI_STUB_FAIL_STEP || '';
  const failOnce = process.env.P93_INSTALLER_UI_STUB_FAIL_STEP_ONCE || '';
  if (failOnce) {
    const counter = process.env.P93_INSTALLER_UI_STUB_FAIL_STEP_ONCE_COUNTER || `${log}.fail-once`;
    let count = 0;
    try { count = Number(readFileSync(counter, 'utf8')); } catch { count = 0; }
    if (count === 0) {
      shouldFail = failOnce;
      writeFileSync(counter, '1');
    }
  }
  const delay = Number(process.env.P93_INSTALLER_UI_STUB_DELAY_MS || 0);
  if (process.env.P93_INSTALLER_UI_STUB_REAL_FAILURE === '1' && shouldFail) {
    const failure = `${stepTitle(shouldFail)}: failed: the deployment did not finish (capture stub)`;
    if (progressPath) appendFileSync(progressPath, progressLine({ stepId: shouldFail, event: 'started', message: `${stepTitle(shouldFail)}: started` }) + '\n');
    if (progressPath) appendFileSync(progressPath, progressLine({ stepId: shouldFail, event: 'failed', message: failure, resumeCommand: "Set-Location -LiteralPath '/home/operator/claude-code-foundry-gateway'; ./Install-ClaudeGateway.ps1" }) + '\n');
    console.error(failure);
    process.exit(7);
  }
  if (process.env.P93_INSTALLER_UI_STUB_GRANDCHILD_HEARTBEAT) {
    const heartbeat = process.env.P93_INSTALLER_UI_STUB_GRANDCHILD_HEARTBEAT;
    const child = startHeartbeatGrandchild(heartbeat);
    appendFileSync(`${heartbeat}.pid`, `${process.pid}\n${child.pid}\n`);
    if (progressPath) appendFileSync(progressPath, progressLine({ stepId: steps[0], event: 'started', message: 'started' }) + '\n');
    setInterval(() => {}, 1000);
    await new Promise(() => {});
  }
  if (process.env.P93_INSTALLER_UI_STUB_MULTIBYTE) {
    const value = Buffer.from('split 😀 line\n');
    process.stdout.write(value.subarray(0, 8));
    await new Promise((resolve) => setTimeout(resolve, 20));
    process.stdout.write(value.subarray(8));
    process.exit(0);
  }
  if (process.env.P93_INSTALLER_UI_STUB_SPLIT_LINE) {
    process.stdout.write('split ');
    await new Promise((resolve) => setTimeout(resolve, 20));
    process.stdout.write('line\n');
    process.exit(0);
  }
  if (process.env.P93_INSTALLER_UI_STUB_NO_FINAL_NEWLINE) {
    process.stdout.write('last line without newline');
    process.exit(0);
  }
  if (process.env.P93_INSTALLER_UI_STUB_LONG_LINE) {
    process.stdout.write('x'.repeat(Number(process.env.P93_INSTALLER_UI_STUB_LONG_LINE)));
    process.stdout.write('\nnext line\n');
    process.exit(0);
  }
  if (process.env.P93_INSTALLER_UI_STUB_MANY_LINES) {
    const count = Number(process.env.P93_INSTALLER_UI_STUB_MANY_LINES);
    const pad = 'y'.repeat(Number(process.env.P93_INSTALLER_UI_STUB_PAD || 0));
    for (let i = 0; i < count; i++) console.log(`line ${String(i).padStart(4, '0')}${pad}`);
    process.exit(0);
  }
  if (process.env.P93_INSTALLER_UI_STUB_PROGRESS_EVENTS && progressPath) {
    const count = Number(process.env.P93_INSTALLER_UI_STUB_PROGRESS_EVENTS);
    for (let i = 0; i < count; i++) appendFileSync(progressPath, progressLine({ stepId: steps[0], event: i % 2 ? 'completed' : 'started', message: `event ${i}` }) + '\n');
    finish(0);
  }
  if (process.env.P93_INSTALLER_UI_STUB_PROGRESS_LONG_LINE && progressPath) {
    appendFileSync(progressPath, 'x'.repeat(Number(process.env.P93_INSTALLER_UI_STUB_PROGRESS_LONG_LINE)));
    await new Promise((resolve) => setTimeout(resolve, 150));
    appendFileSync(progressPath, '\n');
    appendFileSync(progressPath, progressLine({ stepId: steps[0], event: 'completed', message: 'after long progress' }) + '\n');
    finish(0);
  }
  if (process.env.P93_INSTALLER_UI_STUB_MALFORMED_PROGRESS && progressPath) {
    appendFileSync(progressPath, '{bad json password=super-secret}\n');
    appendFileSync(progressPath, progressLine({ stepId: steps[0], event: 'completed', message: 'after malformed' }) + '\n');
  }
  if (process.env.P93_INSTALLER_UI_STUB_BAD_PROGRESS && progressPath) {
    const bad = process.env.P93_INSTALLER_UI_STUB_BAD_PROGRESS;
    const event = bad === 'version'
      ? { schemaVersion: 2, time: time(), runId, stepId: steps[0], event: 'failed', message: 'bad version', resumeCommand: 'bad' }
      : bad === 'missing'
        ? { schemaVersion: 1, time: time(), runId, stepId: steps[0], message: 'missing', resumeCommand: 'bad' }
        : { schemaVersion: 1, time: time(), runId, stepId: steps[0], event: 99, message: 'wrong', resumeCommand: 'bad' };
    appendFileSync(progressPath, JSON.stringify(event) + '\n');
    process.exit(0);
  }
  if (process.env.P93_INSTALLER_UI_STUB_PROGRESS_NO_NEWLINE && progressPath) {
    appendFileSync(progressPath, progressLine({ stepId: steps[0], event: 'failed', message: 'failed at tail', resumeCommand: `Install-ClaudeGateway.ps1 -Steps ${steps[0]}` }));
    process.exit(7);
  }
  if (process.env.P93_INSTALLER_UI_STUB_REFUSED_PROGRESS && progressPath) {
    appendFileSync(progressPath, progressLine({ stepId: '', event: 'refused', message: 'Refused: nothing was changed.', resumeCommand: '' }) + '\n');
    process.exit(1);
  }
  for (const step of steps) {
    if (delay) await new Promise((resolve) => setTimeout(resolve, delay));
    if (progressPath) appendFileSync(progressPath, progressLine({ stepId: step, event: 'started', message: `${step} started` }) + '\n');
    const event = step === shouldFail ? 'failed' : 'completed';
    if (progressPath) appendFileSync(progressPath, progressLine({
      stepId: step,
      event,
      message: step === shouldFail ? 'password=super-secret failed' : `${step} ok`,
      resumeCommand: `Install-ClaudeGateway.ps1 -Steps ${step} -AddressCertificatePassword password=super-secret`,
    }) + '\n');
    if (event === 'failed') {
      console.error('password=super-secret failed');
      process.exit(7);
    }
  }
  console.log('run complete');
  process.exit(0);
}

console.error(`unsupported stub invocation: ${args.join(' ')}`);
process.exit(64);
