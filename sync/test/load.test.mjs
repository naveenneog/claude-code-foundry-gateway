import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const script = fileURLToPath(new URL('../../guide/loadtest-projection.mjs', import.meta.url));
for (const args of [
  [],
  ['--endpoint', 'https://example.documents.azure.com', '--container', 'entitlement'],
  ['--endpoint', 'https://example.documents.azure.com', '--container', 'loadtest', '--count', '0'],
  ['--endpoint', 'https://example.documents.azure.com', '--container', 'loadtest', '--concurrency', '6400'],
]) {
  test(`unsafe load invocation is refused before Azure: ${args.join(' ')}`, () => {
    const r = spawnSync(process.execPath, [script, ...args], { encoding: 'utf8' });
    assert.equal(r.status, 2);
    assert.match(r.stderr, /loadtest|count|concurrency/);
    assert.doesNotMatch(r.stderr, /ERR_MODULE_NOT_FOUND/);
  });
}
