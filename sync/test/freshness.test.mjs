import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as plan from '../src/plan.mjs';
import { toEntitlement } from '../../resolver/src/entitlement.mjs';

const oid = '11111111-1111-4111-8111-111111111111';
const tenantId = '22222222-2222-4222-8222-222222222222';
const now = new Date('2026-09-24T12:00:00Z');
const lease = {
  reconciliationGeneration: '33333333-3333-4333-8333-333333333333',
  lastVerifiedAt: '2026-09-24T11:00:00.000Z',
  expiresAt: Date.parse('2026-09-24T13:00:00Z') / 1000,
};
const doc = { id: oid, oid, tenantId, tier: 'standard', ...lease };
const snapshot = { kind: 'claude-entitlement-snapshot', tenantId, generatedAt: lease.lastVerifiedAt, ...lease, records: [{ oid, tier: 'standard' }] };

test('expiry is absolute and derived from the start of the directory scan', () => {
  const r = plan.createReconciliation({ verifiedAt: now, now });
  assert.equal(r.lastVerifiedAt, now.toISOString());
  assert.equal(r.expiresAt, now.getTime() / 1000 + 7200);
  assert.match(r.reconciliationGeneration, /^[a-f0-9-]{36}$/);
});
test('a scan that took the whole lease cannot be published as fresh', () => {
  assert.throws(() => plan.createReconciliation({ verifiedAt: new Date(now - 7200000), now }), /expired/);
});
test('renewal rewrites unchanged members, never an orphan', () => {
  const r = plan.planChanges([{ oid, tier: 'standard' }], new Map([[oid, { tier: 'standard' }], ['orphan', { tier: 'standard' }]]), { refresh: true });
  assert.equal(r.toWrite.length, 1);
  assert.deepEqual(r.toDelete, ['orphan']);
  const d = plan.toDocument(r.toWrite[0], { tenantId, mappingVersion: 1, reconciliation: lease });
  for (const key of Object.keys(lease)) assert.equal(d[key], lease[key]);
});
test('old snapshot replay never renews its authorization', () => {
  assert.deepEqual(plan.validateSnapshot(snapshot, { tenantId, now }), []);
  assert.match(plan.validateSnapshot(snapshot, { tenantId, now: new Date('2026-09-24T13:00:00Z') }).join(), /expired/);
  for (const key of Object.keys(lease)) {
    const broken = { ...snapshot }; delete broken[key];
    assert.notEqual(plan.validateSnapshot(broken, { tenantId, now }).length, 0, key);
  }
});
test('a fresh entitlement carries its generation and absolute expiry through the resolver', () => {
  const r = toEntitlement(doc, { tenantId, now });
  assert.equal(r.ok, true);
  assert.equal(r.record.expiresAt, lease.expiresAt);
  assert.equal(r.record.reconciliationGeneration, lease.reconciliationGeneration);
});
test('expiry boundary and malformed freshness are service failures, never stale access or user-not-found', () => {
  for (const changes of [
    { expiresAt: now.getTime() / 1000 }, { expiresAt: 0 }, { expiresAt: null },
    { expiresAt: 'tomorrow' }, { expiresAt: lease.expiresAt + 1 },
    { lastVerifiedAt: 'bad' }, { lastVerifiedAt: new Date(now.getTime() + 1000).toISOString() },
    { reconciliationGeneration: '' }, { reconciliationGeneration: 'bad' },
  ]) {
    const r = toEntitlement({ ...doc, ...changes }, { tenantId, now });
    assert.equal(r.ok, false, JSON.stringify(changes));
    assert.equal(r.status, 503);
    assert.match(r.reason, /projection.*expired|projection.*freshness/);
  }
});
test('a missing tenant cannot authorize through a leased record', () => {
  const r = toEntitlement({ ...doc, tenantId: undefined }, { tenantId, now });
  assert.equal(r.ok, false);
  assert.equal(r.status, 403);
});
test('migration comparison refuses an expired record rather than approving the flip', () => {
  const r = plan.compareWithGateway({ standard: [oid] }, [{ ...doc, expiresAt: now.getTime() / 1000 }], { tenantId, now });
  assert.equal(r.differences[0]?.kind, 'would-lose-access');
});
