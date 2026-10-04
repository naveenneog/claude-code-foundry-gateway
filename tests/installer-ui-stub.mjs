import { appendFileSync, readFileSync, writeFileSync } from 'node:fs';
import { spawn } from 'node:child_process';

const [, , mode, ...args] = process.argv;
const log = process.env.P93_INSTALLER_UI_STUB_LOG;
if (log) appendFileSync(log, JSON.stringify({ mode, args }) + '\n');

function argValue(name) {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : '';
}

const runId = '0123456789abcdef0123456789abcdef';
const time = () => new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
const progressLine = (event) => JSON.stringify({ schemaVersion: 1, time: time(), runId, ...event });

if (args.includes('-ListSteps')) {
  if (process.env.P93_INSTALLER_UI_STUB_BAD_LIST === 'version') {
    console.log(JSON.stringify({ schemaVersion: 2, installer: 'pwsh', checkpoint: null, runId: null, steps: [] }));
    process.exit(0);
  }
  if (process.env.P93_INSTALLER_UI_STUB_BAD_LIST === 'missing') {
    console.log(JSON.stringify({ schemaVersion: 1, installer: 'pwsh', checkpoint: null, runId: null }));
    process.exit(0);
  }
  if (process.env.P93_INSTALLER_UI_STUB_BAD_LIST === 'type') {
    console.log(JSON.stringify({ schemaVersion: 1, installer: 'pwsh', checkpoint: null, runId: null, steps: [{ id: 1, title: 'bad', dependencies: [], state: 'not-started' }] }));
    process.exit(0);
  }
  const ids = ['claude-deployment', 'resource-group', 'gateway-deployment', 'company-address', 'entra-groups', 'sync', 'projection', 'business-units', 'onboarding-package', 'verify'];
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
    process.exit(0);
  }
  console.log(JSON.stringify({
    schemaVersion: 1,
    installer: 'pwsh',
    checkpoint: null,
    runId: null,
    steps: ids.map((id, index) => ({ id, title: id.replaceAll('-', ' '), dependencies: index ? [ids[index - 1]] : [], state: 'not-started' })),
  }));
  process.exit(0);
}

const answersPath = argValue('-AnswersPath');
const answers = answersPath ? JSON.parse(readFileSync(answersPath, 'utf8')) : {};
if (args.includes('-Preflight')) {
  if (process.env.P93_INSTALLER_UI_STUB_PREFLIGHT_HANG) {
    const heartbeat = process.env.P93_INSTALLER_UI_STUB_PREFLIGHT_HANG;
    const child = spawn(process.execPath, ['-e', `const {appendFileSync}=require('fs'); setInterval(()=>appendFileSync(process.argv[1], Date.now()+"\\n"),100);`, heartbeat], { stdio: 'ignore', detached: false });
    appendFileSync(`${heartbeat}.pid`, `${process.pid}\n${child.pid}\n`);
    await new Promise(() => {});
  }
  if (process.env.P93_INSTALLER_UI_STUB_PREFLIGHT_DELAY_MS) await new Promise((resolve) => setTimeout(resolve, Number(process.env.P93_INSTALLER_UI_STUB_PREFLIGHT_DELAY_MS)));
  if (process.env.P93_INSTALLER_UI_STUB_PREFLIGHT_TEXT) {
    console.log(`preflight could not parse password=super-secret at ${answersPath}`);
    process.exit(2);
  }
  if (process.env.P93_INSTALLER_UI_STUB_BAD_PREFLIGHT === 'version') {
    console.log(JSON.stringify({ schemaVersion: 2, installer: 'pwsh', answersSchemaVersion: 1, result: 'PASS', checks: [] }));
    process.exit(0);
  }
  if (process.env.P93_INSTALLER_UI_STUB_BAD_PREFLIGHT === 'missing') {
    console.log(JSON.stringify({ schemaVersion: 1, installer: 'pwsh', answersSchemaVersion: 1, checks: [] }));
    process.exit(0);
  }
  if (process.env.P93_INSTALLER_UI_STUB_BAD_PREFLIGHT === 'type') {
    console.log(JSON.stringify({ schemaVersion: 1, installer: 'pwsh', answersSchemaVersion: 1, result: 'PASS', checks: [{ id: 'x', result: 1 }] }));
    process.exit(0);
  }
  if (process.env.P93_INSTALLER_UI_STUB_PREFLIGHT_FAIL_ON_SECOND) {
    const counterPath = process.env.P93_INSTALLER_UI_STUB_PREFLIGHT_FAIL_ON_SECOND;
    let count = 0;
    try { count = Number(readFileSync(counterPath, 'utf8')); } catch { count = 0; }
    writeFileSync(counterPath, String(count + 1));
    if (count >= 1) process.env.P93_INSTALLER_UI_STUB_PREFLIGHT_FAIL = '1';
  }
  const fail = process.env.P93_INSTALLER_UI_STUB_PREFLIGHT_FAIL === '1';
  console.log(JSON.stringify({
    schemaVersion: 1,
    installer: 'pwsh',
    answersSchemaVersion: 1,
    result: fail || !answers.SubscriptionId ? 'FAIL' : 'PASS',
    checks: [
      { id: 'target.tenant', result: process.env.P93_INSTALLER_UI_STUB_SIGNED_IN === '1' ? 'PASS' : 'NOT-RUN', reason: process.env.P93_INSTALLER_UI_STUB_SIGNED_IN === '1' ? null : 'not-signed-in', message: process.env.P93_INSTALLER_UI_STUB_SIGNED_IN === '1' ? 'Azure CLI tenant matches the subscription' : 'Azure CLI is not signed in', remedy: process.env.P93_INSTALLER_UI_STUB_SIGNED_IN === '1' ? '' : 'Run az login --use-device-code.', problems: [] },
      { id: 'answers.schema', result: fail || !answers.SubscriptionId ? 'FAIL' : 'PASS', reason: null, message: fail || !answers.SubscriptionId ? 'SubscriptionId is required' : 'answers file is valid', remedy: 'Give SubscriptionId.', problems: fail || !answers.SubscriptionId ? [{ message: 'SubscriptionId is required', remedy: 'Give SubscriptionId.' }] : [] },
    ],
  }));
  process.exit(process.env.P93_INSTALLER_UI_STUB_PREFLIGHT_PASS_EXIT_1 === '1' ? 1 : (fail ? 1 : 0));
}

if (args.includes('-Yes')) {
  const stepsArg = argValue('-Steps');
  const steps = stepsArg ? stepsArg.split(',') : ['resource-group', 'gateway-deployment'];
  const progressPath = argValue('-ProgressPath');
  const shouldFail = process.env.P93_INSTALLER_UI_STUB_FAIL_STEP || '';
  const delay = Number(process.env.P93_INSTALLER_UI_STUB_DELAY_MS || 0);
  if (process.env.P93_INSTALLER_UI_STUB_GRANDCHILD_HEARTBEAT) {
    const heartbeat = process.env.P93_INSTALLER_UI_STUB_GRANDCHILD_HEARTBEAT;
    const child = spawn(process.execPath, ['-e', `const {appendFileSync}=require('fs'); setInterval(()=>appendFileSync(process.argv[1], Date.now()+"\\n"),100);`, heartbeat], { stdio: 'ignore', detached: false });
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
    process.exit(0);
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
