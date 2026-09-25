import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const batch = () => JSON.parse(readFileSync(resolve(root, 'guide', 'captures', 'architecture.json'), 'utf8'));

test('every architecture portal output has a unique discovery-only batch step', () => {
  const spec = batch();
  assert.equal(spec.version, 1);
  assert.ok(spec.steps.length >= 19);
  assert.equal(new Set(spec.steps.map(step => step.id)).size, spec.steps.length);
  assert.equal(new Set(spec.steps.map(step => step.output)).size, spec.steps.length);
  const published = JSON.parse(readFileSync(resolve(root, 'docs', 'images', 'architecture-live', 'captures.json'), 'utf8'));
  for (const image of published.captures.filter(image => !/^(terminal|console)-/.test(image.id))) {
    assert.ok(spec.steps.some(step => step.output === image.image), image.id);
  }
  for (const step of spec.steps) {
    assert.match(step.id, /^architecture-[a-z0-9-]+$/);
    assert.match(step.output, /^docs\/images\/architecture-live\/[a-z0-9-]+\.png$/);
    assert.ok(step.target.discover);
    assert.doesNotMatch(JSON.stringify(step.target), /https?:|\/subscriptions\/|\/resourceGroups\/|[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}/i);
    assert.ok(!('name' in step.target) && !('id' in step.target) && !('url' in step.target));
    if (step.target.nameFilterEnv) assert.match(step.target.nameFilterEnv, /^[A-Z][A-Z0-9_]+$/);
    assert.equal(step.redaction.mapEnv, 'PORTAL_REDACTIONS_FILE');
    for (const click of step.clicks ?? []) {
      assert.doesNotMatch(click.text ?? '', /^(?:sign in|save|delete|create|grant|run now|start|confirm)$/i);
    }
  }
});

test('every batch output and its pending or live status is documented without fake new images', () => {
  const guide = readFileSync(resolve(root, 'docs', 'architecture', 'LIVE-VERIFICATION.md'), 'utf8');
  const manifest = JSON.parse(readFileSync(resolve(root, 'docs', 'guide', 'portal-captures.json'), 'utf8'));
  for (const step of batch().steps) {
    assert.ok(guide.includes(step.output), step.output);
    const pending = guide.includes(`pending batch capture (${step.id})`);
    const live = guide.includes(`live batch capture (${step.id})`);
    assert.ok(pending !== live, `${step.id} must be documented as exactly one of pending or live`);
    if (live) {
      // A live claim needs the runner's own record, and the published pixels must be the
      // ones it recorded rather than a later substitute.
      const record = manifest.captures.find((item) => item.output === step.output);
      assert.ok(record?.live === true && record.redaction?.leak_check_passed === true, `${step.id} has no live batch record`);
      assert.equal(createHash('sha256').update(readFileSync(resolve(root, step.output))).digest('hex'), record.sha256, step.output);
    }
  }
  assert.ok(guide.includes('single original profile'));
  assert.ok(guide.includes('Do not retry'));
});

test('the retired per-worktree portal entry point never opens a browser', () => {
  const result = spawnSync(process.execPath, [resolve(root, 'guide', 'capture-architecture-live.mjs')], {
    cwd: root, encoding: 'utf8', timeout: 5000,
  });
  assert.equal(result.status, 2);
  assert.match(result.stderr, /lead-operated portal batch/);
});
