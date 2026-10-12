// Producer vocabularies: scripts/ClaudeInstallCheckpoint.ps1 writes started/completed/incomplete,
// scripts/ClaudeInstallSteps.ps1 adds not-started in -ListSteps and emits progress events.
export const STEP_STATES = ['not-started', 'started', 'completed', 'incomplete'];
export const PREFLIGHT_RESULTS = ['PASS', 'FAIL', 'NOT-RUN'];
export const PROGRESS_EVENTS = ['started', 'completed', 'skipped-verified', 'warning', 'failed', 'refused'];
const stepStates = new Set(STEP_STATES);
const preflightResults = new Set(PREFLIGHT_RESULTS);
const progressEvents = new Set(PROGRESS_EVENTS);
const preflightReasons = new Set(['not-signed-in', 'prerequisite-failed', 'not-evaluated', 'not-applicable', 'not-answered', 'discovery-skipped']);
const blockingNotRunReasons = new Set(['not-signed-in', 'prerequisite-failed', 'not-evaluated']);

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
  const ids = new Set();
  for (const [index, step] of payload.steps.entries()) {
    requireObject(step, interfaceName);
    for (const field of ['id', 'title', 'state']) requireString(step, field, interfaceName);
    if (!step.id) throw fail(interfaceName, `step ${index} id is empty`);
    if (ids.has(step.id)) throw fail(interfaceName, `has duplicate step id ${step.id}`);
    ids.add(step.id);
    if (!Array.isArray(step.dependencies) || !step.dependencies.every((item) => typeof item === 'string')) {
      throw fail(interfaceName, `step ${index} field dependencies is not a text array`);
    }
    if (!stepStates.has(step.state)) throw fail(interfaceName, `step ${step.id} has unsupported state ${step.state}`);
  }
  for (const step of payload.steps) {
    for (const dependency of step.dependencies) {
      if (!ids.has(dependency)) throw fail(interfaceName, `step ${step.id} has unknown dependency ${dependency}`);
    }
  }
  return payload;
}

function checkBlocks(check) {
  return check.result === 'FAIL' || (check.result === 'NOT-RUN' && blockingNotRunReasons.has(check.reason));
}

export function validatePreflight(payload, options = {}) {
  const interfaceName = 'preflight result';
  const expectedCheckIds = options.expectedCheckIds ? new Set(options.expectedCheckIds) : null;
  requireObject(payload, interfaceName);
  requireVersion(payload, interfaceName);
  requireString(payload, 'installer', interfaceName);
  if (payload.answersSchemaVersion !== 1) throw fail(interfaceName, `answersSchemaVersion is ${payload.answersSchemaVersion}; this UI reads version 1`);
  requireString(payload, 'result', interfaceName);
  if (!['PASS', 'FAIL'].includes(payload.result)) throw fail(interfaceName, `result ${payload.result} is not PASS or FAIL`);
  if (!Array.isArray(payload.checks)) throw fail(interfaceName, 'field checks is not an array');
  if (!payload.checks.length) throw fail(interfaceName, 'has zero checks');
  const seen = new Set();
  for (const [index, check] of payload.checks.entries()) {
    requireObject(check, interfaceName);
    for (const field of ['id', 'result', 'message', 'remedy']) requireString(check, field, interfaceName);
    if (seen.has(check.id)) throw fail(interfaceName, `has duplicate check id ${check.id}`);
    seen.add(check.id);
    if (expectedCheckIds && !expectedCheckIds.has(check.id)) throw fail(interfaceName, `has unknown check id ${check.id}`);
    if (!preflightResults.has(check.result)) throw fail(interfaceName, `check ${index} result ${check.result} is unsupported`);
    if (check.reason !== undefined && check.reason !== null && typeof check.reason !== 'string') throw fail(interfaceName, `check ${index} field reason is not text or null`);
    if (check.result === 'NOT-RUN') {
      if (!preflightReasons.has(check.reason)) throw fail(interfaceName, `NOT-RUN check ${check.id} has unsupported reason ${check.reason}`);
    } else if (check.reason !== undefined && check.reason !== null) {
      throw fail(interfaceName, `${check.result} check ${check.id} reason is not null`);
    }
    if (check.problems !== undefined) {
      if (!Array.isArray(check.problems)) throw fail(interfaceName, `check ${index} field problems is not an array`);
      for (const problem of check.problems) {
        requireObject(problem, interfaceName);
        if (problem.message !== undefined && typeof problem.message !== 'string') throw fail(interfaceName, 'problem message is not text');
        if (problem.remedy !== undefined && typeof problem.remedy !== 'string') throw fail(interfaceName, 'problem remedy is not text');
        if (problem.path !== undefined && typeof problem.path !== 'string') throw fail(interfaceName, 'problem path is not text');
      }
    }
  }
  if (expectedCheckIds) {
    for (const id of expectedCheckIds) {
      if (!seen.has(id)) throw fail(interfaceName, `is missing expected check ${id}`);
    }
  }
  const recomputed = payload.checks.some(checkBlocks) ? 'FAIL' : 'PASS';
  if (payload.result !== recomputed) throw fail(interfaceName, `result ${payload.result} does not match recomputed ${recomputed}`);
  return payload;
}

export function validateProgressEvent(payload) {
  const interfaceName = 'progress event';
  requireObject(payload, interfaceName);
  requireVersion(payload, interfaceName);
  for (const field of ['time', 'runId', 'stepId', 'event', 'message', 'resumeCommand']) requireString(payload, field, interfaceName);
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(payload.time)) throw fail(interfaceName, 'field time is not yyyy-MM-ddTHH:mm:ssZ');
  if (!/^[a-fA-F0-9]{32}$/.test(payload.runId)) throw fail(interfaceName, 'field runId is not 32 hex characters');
  if (!progressEvents.has(payload.event)) throw fail(interfaceName, `event ${payload.event} is unsupported`);
  if (!payload.stepId && !['failed', 'refused'].includes(payload.event)) throw fail(interfaceName, `event ${payload.event} needs a stepId`);
  return payload;
}
