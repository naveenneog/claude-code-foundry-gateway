import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { resolve, join } from 'node:path';
import { text, withSourceSnapshot } from './architecture-model.mjs';

test('source caching belongs to one synchronous check, never a later mutation', () => {
  const root = resolve('.shots-entra', `architecture-cache-${randomUUID()}`);
  mkdirSync(root, { recursive: true });
  try {
    const file = join(root, 'source.txt');
    writeFileSync(file, 'before\r\n');
    withSourceSnapshot(root, () => {
      assert.equal(text(root, 'source.txt'), 'before\n');
      writeFileSync(file, 'after\n');
      assert.equal(text(root, 'source.txt'), 'before\n');
    });
    withSourceSnapshot(root, () => assert.equal(text(root, 'source.txt'), 'after\n'));
    rmSync(file);
    assert.throws(() => withSourceSnapshot(root, () => text(root, 'source.txt')), /ENOENT/);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('a thrown check releases its cache', () => {
  const root = resolve('.shots-entra', `architecture-cache-${randomUUID()}`);
  mkdirSync(root, { recursive: true });
  try {
    const file = join(root, 'source.txt');
    writeFileSync(file, 'old');
    assert.throws(() => withSourceSnapshot(root, () => {
      text(root, 'source.txt');
      throw new Error('expected failure');
    }), /expected failure/);
    writeFileSync(file, 'new');
    assert.equal(text(root, 'source.txt'), 'new');
  } finally { rmSync(root, { recursive: true, force: true }); }
});
