import { test } from 'node:test';
import assert from 'node:assert/strict';
import { acquireApplyLock } from '../src/apply-lock.mjs';

test('an unexpired apply lock waits only to the bounded timeout and names the remedy', async () => {
  const now = new Date('2026-10-06T00:00:00.000Z');
  const lock = {
    resource: {
      id: 'projection-apply-lock',
      oid: 'projection-apply-lock',
      type: 'projection-apply-lock',
      holder: 'other-run',
      mode: 'user',
      acquiredAt: now.toISOString(),
      leaseExpiresAt: new Date(now.getTime() + 300_000).toISOString(),
      _etag: '"held"',
    },
    etag: '"held"',
  };
  const calls = [];
  const container = {
    items: {
      create: async () => {
        const error = new Error('conflict');
        error.code = 409;
        throw error;
      },
    },
    item: () => ({
      read: async () => lock,
    }),
  };

  await assert.rejects(
    acquireApplyLock(container, {
      runId: 'run-a',
      mode: 'full',
      waitSeconds: 0,
      now: () => now,
      sleep: async (ms) => calls.push(ms),
    }),
    (error) => {
      assert.equal(error.stage, 'lock');
      assert.match(error.message, /other-run/);
      assert.match(error.message, /leaseExpiresAt/);
      assert.match(error.message, /Remedy: rerun scripts\/Sync-ClaudeAccess\.ps1 -ResourceGroup <rg> -ApimName <apim>.* after /);
      return true;
    },
  );
  assert.deepEqual(calls, []);
});

test('an expired apply lock is taken over with IfMatch and released with IfMatch', async () => {
  let current = {
    id: 'projection-apply-lock',
    oid: 'projection-apply-lock',
    type: 'projection-apply-lock',
    holder: 'old-run',
    mode: 'full',
    acquiredAt: '2026-10-05T23:50:00.000Z',
    leaseExpiresAt: '2026-10-05T23:55:00.000Z',
    _etag: '"old"',
  };
  const options = [];
  const container = {
    items: {
      create: async () => {
        const error = new Error('conflict');
        error.code = 409;
        throw error;
      },
    },
    item: () => ({
      read: async () => ({ resource: current, etag: current._etag }),
      replace: async (body, option) => {
        options.push(option);
        assert.equal(option.accessCondition.type, 'IfMatch');
        assert.equal(option.accessCondition.condition, '"old"');
        current = { ...body, _etag: '"new"' };
        return { resource: current, etag: '"new"' };
      },
      delete: async (option) => {
        options.push(option);
        assert.equal(option.accessCondition.type, 'IfMatch');
        assert.equal(option.accessCondition.condition, '"new"');
        current = null;
        return {};
      },
    }),
  };

  const lease = await acquireApplyLock(container, {
    runId: 'run-a',
    mode: 'full',
    now: () => new Date('2026-10-06T00:00:00.000Z'),
    sleep: async () => assert.fail('expired lock should not sleep'),
  });
  assert.equal(current.holder, 'run-a');
  await lease.release();
  assert.equal(current, null);
  assert.equal(options.length, 2);
});

test('a lost renewal fails at the lock stage before the caller writes more', async () => {
  let reads = 0;
  let replaced = 0;
  const created = {
    id: 'projection-apply-lock',
    oid: 'projection-apply-lock',
    type: 'projection-apply-lock',
    holder: 'run-a',
    mode: 'full',
    acquiredAt: '2026-10-06T00:00:00.000Z',
    leaseExpiresAt: '2026-10-06T00:05:00.000Z',
    _etag: '"new"',
  };
  const container = {
    items: { create: async () => ({ resource: created, etag: '"new"' }) },
    item: () => ({
      read: async () => {
        reads++;
        return { resource: created, etag: '"new"' };
      },
      replace: async () => {
        replaced++;
        const error = new Error('precondition failed');
        error.code = 412;
        throw error;
      },
      delete: async () => ({}),
    }),
  };
  const lease = await acquireApplyLock(container, {
    runId: 'run-a',
    mode: 'full',
    now: () => new Date('2026-10-06T00:00:00.000Z'),
    sleep: async () => {},
  });

  await assert.rejects(
    lease.renewIfNeeded({ force: true, now: () => new Date('2026-10-06T00:02:00.000Z') }),
    (error) => {
      assert.equal(error.stage, 'lock');
      assert.match(error.message, /lost the projection apply lock/);
      assert.match(error.message, /Remedy: rerun scripts\/Sync-ClaudeAccess\.ps1 -ResourceGroup <rg> -ApimName <apim>/);
      return true;
    },
  );
  assert.equal(reads, 0);
  assert.equal(replaced, 1);
});
