const stepStates = new Set(['not-started', 'running', 'completed', 'skipped-verified', 'failed', 'pending']);
const preflightResults = new Set(['PASS', 'FAIL', 'NOT-RUN']);
const progressEvents = new Set(['started', 'completed', 'skipped-verified', 'warning', 'failed']);

function fail(interfaceName, message) {
  const error = new Error(`the installer's ${interfaceName} ${message}`);
  error.status = 502;
  error.interfaceName = interfaceName;
  return error;
}

function requireObject(value, interfaceName) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw fail(interfaceName, 'is not an object');
}

function requireVersion(value, interfaceName) {
  if (value.schemaVersion !== 1) throw fail(interfaceName, `is schemaVersion ${value.schemaVersion}; this UI reads version 1`);
}

function requireString(value, field, interfaceName) {
  if (typeof value[field] !== 'string') throw fail(interfaceName, `field ${field} is not text`);
}

export function validateStepList(payload) {
  const interfaceName = 'step list';
  requireObject(payload, interfaceName);
  requireVersion(payload, interfaceName);
  requireString(payload, 'installer', interfaceName);
  if (!Array.isArray(payload.steps)) throw fail(interfaceName, 'field steps is not an array');
  for (const [index, step] of payload.steps.entries()) {
    requireObject(step, interfaceName);
    for (const field of ['id', 'title', 'state']) requireString(step, field, interfaceName);
    if (!Array.isArray(step.dependencies) || !step.dependencies.every((item) => typeof item === 'string')) {
      throw fail(interfaceName, `step ${index} field dependencies is not a text array`);
    }
    if (!stepStates.has(step.state)) throw fail(interfaceName, `step ${step.id} has unsupported state ${step.state}`);
  }
  return payload;
}

export function validatePreflight(payload) {
  const interfaceName = 'preflight result';
  requireObject(payload, interfaceName);
  requireVersion(payload, interfaceName);
  requireString(payload, 'installer', interfaceName);
  if (payload.answersSchemaVersion !== 1) throw fail(interfaceName, `answersSchemaVersion is ${payload.answersSchemaVersion}; this UI reads version 1`);
  requireString(payload, 'result', interfaceName);
  if (!['PASS', 'FAIL'].includes(payload.result)) throw fail(interfaceName, `result ${payload.result} is not PASS or FAIL`);
  if (!Array.isArray(payload.checks)) throw fail(interfaceName, 'field checks is not an array');
  for (const [index, check] of payload.checks.entries()) {
    requireObject(check, interfaceName);
    for (const field of ['id', 'result']) requireString(check, field, interfaceName);
    if (!preflightResults.has(check.result)) throw fail(interfaceName, `check ${index} result ${check.result} is unsupported`);
    for (const optional of ['message', 'remedy', 'reason']) {
      if (check[optional] !== undefined && typeof check[optional] !== 'string') throw fail(interfaceName, `check ${index} field ${optional} is not text`);
    }
    if (check.problems !== undefined) {
      if (!Array.isArray(check.problems)) throw fail(interfaceName, `check ${index} field problems is not an array`);
      for (const problem of check.problems) {
        requireObject(problem, interfaceName);
        if (problem.message !== undefined && typeof problem.message !== 'string') throw fail(interfaceName, 'problem message is not text');
        if (problem.remedy !== undefined && typeof problem.remedy !== 'string') throw fail(interfaceName, 'problem remedy is not text');
      }
    }
  }
  return payload;
}

export function validateProgressEvent(payload) {
  const interfaceName = 'progress event';
  requireObject(payload, interfaceName);
  requireVersion(payload, interfaceName);
  for (const field of ['time', 'runId', 'stepId', 'event']) requireString(payload, field, interfaceName);
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(payload.time)) throw fail(interfaceName, 'field time is not yyyy-MM-ddTHH:mm:ssZ');
  if (!/^[a-fA-F0-9]{32}$/.test(payload.runId)) throw fail(interfaceName, 'field runId is not 32 hex characters');
  if (!progressEvents.has(payload.event)) throw fail(interfaceName, `event ${payload.event} is unsupported`);
  for (const optional of ['message', 'resumeCommand']) {
    if (payload[optional] !== undefined && typeof payload[optional] !== 'string') throw fail(interfaceName, `field ${optional} is not text`);
  }
  return payload;
}
