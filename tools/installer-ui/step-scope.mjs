import { sortedUniqueSteps } from './preflight-record.mjs';

function flattenStepIds(stepPayload) {
  const steps = Array.isArray(stepPayload) ? stepPayload : Array.isArray(stepPayload.steps) ? stepPayload.steps : [];
  return new Set(steps.map((step) => String(step.id || step.stepId || '')).filter(Boolean));
}

export async function validateRunRequest(body, listSteps) {
  const steps = Array.isArray(body.steps) ? body.steps.map(String).filter(Boolean) : [];
  if (!steps.length && !(body.fullRun && body.confirmFullRun)) {
    const error = new Error('Select at least one step, or confirm a full run.');
    error.status = 400;
    throw error;
  }

  const allowed = flattenStepIds(await listSteps());
  const injected = steps.filter((step) => !allowed.has(step));
  if (injected.length) {
    const error = new Error(`unknown step id: ${injected.join(', ')}`);
    error.status = 400;
    throw error;
  }
  return steps;
}

export async function validateStepScope(body, listSteps) {
  const steps = Array.isArray(body.steps) ? sortedUniqueSteps(body.steps) : [];
  if (!steps.length) return steps;
  const allowed = flattenStepIds(await listSteps());
  const injected = steps.filter((step) => !allowed.has(step));
  if (injected.length) {
    const error = new Error(`unknown step id: ${injected.join(', ')}`);
    error.status = 400;
    throw error;
  }
  return steps;
}
