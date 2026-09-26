export function selectCaptureSteps(steps, selected) {
  if (!selected) return steps;
  const names = selected.split(',');
  if (names.some(name => !steps.some(step => step.file === name))) {
    throw new Error('Unknown portal capture step; no evidence was collected.');
  }
  return steps.filter(step => names.includes(step.file));
}
