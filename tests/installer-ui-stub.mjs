import { appendFileSync, readFileSync, writeFileSync } from 'node:fs';

const [, , mode, ...args] = process.argv;
const log = process.env.P93_INSTALLER_UI_STUB_LOG;
if (log) appendFileSync(log, JSON.stringify({ mode, args }) + '\n');

function argValue(name) {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : '';
}

if (args.includes('-ListSteps')) {
  console.log(JSON.stringify({
    schemaVersion: 1,
    steps: [
      { id: 'resource-group', title: 'Resource group', prerequisites: [], state: 'pending' },
      { id: 'gateway-deployment', title: 'Gateway deployment', prerequisites: ['resource-group'], state: 'pending' },
      { id: 'entra-groups', title: 'Entra groups', prerequisites: ['gateway-deployment'], state: 'pending' },
    ],
  }));
  process.exit(0);
}

const answersPath = argValue('-AnswersPath');
const answers = answersPath ? JSON.parse(readFileSync(answersPath, 'utf8')) : {};
if (args.includes('-Preflight')) {
  console.log(JSON.stringify({
    schemaVersion: 1,
    checks: [
      { id: 'target.tenant', result: 'NOT-RUN', reason: 'not-signed-in', message: 'Azure CLI is not signed in', remedy: 'Run az login --use-device-code.' },
      { id: 'answers.schema', result: answers.SubscriptionId ? 'PASS' : 'FAIL', message: answers.SubscriptionId ? 'answers file is valid' : 'SubscriptionId is required', remedy: 'Give SubscriptionId.' },
    ],
  }));
  process.exit(0);
}

if (args.includes('-Yes')) {
  const stepsArg = argValue('-Steps');
  const steps = stepsArg ? stepsArg.split(',') : ['resource-group', 'gateway-deployment'];
  const progressPath = argValue('-ProgressPath');
  const shouldFail = process.env.P93_INSTALLER_UI_STUB_FAIL_STEP || '';
  for (const step of steps) {
    const event = step === shouldFail ? 'failed' : 'completed';
    if (progressPath) appendFileSync(progressPath, JSON.stringify({
      schemaVersion: 1,
      time: new Date().toISOString(),
      runId: 'p93-stub',
      stepId: step,
      event,
      message: step === shouldFail ? 'password=super-secret failed' : `${step} ok`,
      resumeCommand: `Install-ClaudeGateway.ps1 -Steps ${step} -AddressCertificatePassword password=super-secret`,
    }) + '\n');
    if (event === 'failed') {
      console.error('Bearer abc.def.ghi failed');
      process.exit(7);
    }
  }
  console.log('run complete');
  process.exit(0);
}

console.error(`unsupported stub invocation: ${args.join(' ')}`);
process.exit(64);
