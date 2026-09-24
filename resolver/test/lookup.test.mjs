import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createLookup } from '../src/lookup.mjs';

test('twenty same-identity misses share one in-flight read, not a stale result cache', async () => {
  let reads = 0, release;
  const lookup = createLookup(async () => { reads++; await new Promise(r => { release = r; }); return { tier: 'standard' }; });
  const burst = Array.from({ length: 20 }, () => lookup('one'));
  await new Promise(r => setImmediate(r));
  assert.equal(reads, 1);
  release();
  assert.equal((await Promise.all(burst)).length, 20);
  const again = lookup('one');
  await new Promise(r => setImmediate(r));
  assert.equal(reads, 2);
  release(); await again;
});
test('a failure is shared but never poisons later requests', async () => {
  let reads = 0;
  const lookup = createLookup(async () => { reads++; if (reads === 1) throw new Error('unavailable'); return 'ok'; });
  const results = await Promise.allSettled([lookup('one'), lookup('one')]);
  assert.equal(reads, 1);
  assert.ok(results.every(r => r.status === 'rejected'));
  assert.equal(await lookup('one'), 'ok');
});
test('different identities cannot coalesce and overload is refused before a read', async () => {
  let reads = 0, release;
  const lookup = createLookup(async () => { reads++; await new Promise(r => { release = r; }); }, { maxInFlight: 1 });
  const first = lookup('one');
  await assert.rejects(lookup('two'), /busy/);
  assert.equal(reads, 1);
  release(); await first;
});
test('the deadline aborts transport and bounds a reader that ignores cancellation', async () => {
  let signal, release;
  const lookup = createLookup(async (oid, s) => { signal = s; await new Promise(r => { release = r; }); }, { deadlineMs: 20, maxInFlight: 1 });
  const start = Date.now();
  await assert.rejects(lookup('one'), /deadline/);
  assert.ok(Date.now() - start < 1000);
  assert.equal(signal.aborted, true);
  await assert.rejects(lookup('two'), /busy/, 'timed out transport must still occupy its slot until it settles');
  release(); await new Promise(r => setImmediate(r));
});
