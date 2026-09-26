import test from 'node:test';
import assert from 'node:assert/strict';
import { selectCaptureSteps } from '../guide/lib/capture-steps.mjs';

test('multiple requested screens share one capture and completion count', () => {
  const steps = ['overview', 'owners', 'members'].map(file => ({ file }));
  assert.equal(selectCaptureSteps(steps, 'overview,owners,members').length, 3);
  assert.equal(selectCaptureSteps(steps, 'owners').length, 1);
  assert.equal(selectCaptureSteps(steps, null).length, 3);
  assert.throws(() => selectCaptureSteps(steps, 'missing'), /Unknown/);
});
