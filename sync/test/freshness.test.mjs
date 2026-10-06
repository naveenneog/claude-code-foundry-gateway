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
test('renewal writes changed documents without record expiry, never an orphan', () => {
  const r = plan.planChanges([{ oid, tier: 'standard' }], new Map([[oid, { tier: 'standard' }], ['orphan', { tier: 'standard' }]]), { refresh: true });
  assert.equal(r.toWrite.length, 1);
  assert.deepEqual(r.toDelete, ['orphan']);
  const d = plan.toDocument(r.toWrite[0], { tenantId, mappingVersion: 1, reconciliation: lease });
  assert.equal(d.reconciliationGeneration, lease.reconciliationGeneration);
  assert.equal(d.lastVerifiedAt, lease.lastVerifiedAt);
  assert.equal('expiresAt' in d, false);
});
test('old snapshot replay never renews its authorization', () => {
  assert.deepEqual(plan.validateSnapshot(snapshot, { tenantId, now }), []);
  assert.match(plan.validateSnapshot(snapshot, { tenantId, now: new Date('2026-09-24T13:00:00Z') }).join(), /expired/);
  for (const key of Object.keys(lease)) {
    const broken = { ...snapshot }; delete broken[key];
    assert.notEqual(plan.validateSnapshot(broken, { tenantId, now }).length, 0, key);
  }
});
test('a fresh entitlement carries its generation but no expiry through the resolver', () => {
  const r = toEntitlement(doc, { tenantId, now });
  assert.equal(r.ok, true);
  assert.equal('expiresAt' in r.record, false);
  assert.equal(r.record.reconciliationGeneration, lease.reconciliationGeneration);
});
test('legacy future record expiry is ignored until it passes, while generation and verification freshness are service failures', () => {
  for (const changes of [
    { expiresAt: lease.expiresAt + 1 }, { expiresAt: undefined }, { expiresAt: null }, { expiresAt: 'tomorrow' },
  ]) {
    const r = toEntitlement({ ...doc, ...changes }, { tenantId, now });
    assert.equal(r.ok, true, JSON.stringify(changes));
    assert.equal('expiresAt' in r.record, false);
  }
  for (const changes of [
    { expiresAt: now.getTime() / 1000 - 1 }, { expiresAt: 0 },
  ]) {
    const r = toEntitlement({ ...doc, ...changes }, { tenantId, now });
    assert.equal(r.ok, false, JSON.stringify(changes));
    assert.equal(r.status, 404);
  }
  for (const changes of [
    { lastVerifiedAt: undefined }, { lastVerifiedAt: 'bad' }, { lastVerifiedAt: new Date(now.getTime() + 1000).toISOString() },
    { reconciliationGeneration: '' }, { reconciliationGeneration: 'bad' },
  ]) {
    const r = toEntitlement({ ...doc, ...changes }, { tenantId, now });
    assert.equal(r.ok, false, JSON.stringify(changes));
    assert.equal(r.status, 503);
    assert.match(r.reason, /projection record is invalid/);
  }
});
test('a missing tenant cannot authorize through a leased record', () => {
  const r = toEntitlement({ ...doc, tenantId: undefined }, { tenantId, now });
  assert.equal(r.ok, false);
  assert.equal(r.status, 403);
});
test('migration comparison uses resolver validation and ignores legacy record expiry', () => {
  const r = plan.compareWithGateway({ standard: [oid] }, [{ ...doc, expiresAt: lease.expiresAt + 1 }], { tenantId, now });
  assert.deepEqual(r.differences, []);
});

test('status records use a non-guid partition and retain seven days of switch evidence', () => {
  const status = plan.toStatusDocument({
    tenantId,
    accountResourceId: '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.DocumentDB/databaseAccounts/cosmos',
    databaseName: 'claude',
    containerName: 'entitlement',
    runId: 'run-1',
    imageDigest: 'sha256:' + 'a'.repeat(64),
    entrypoint: '/app/reconcile.mjs',
    command: ['node', '/app/reconcile.mjs'],
    memberCounts: { standard: 1 },
    writeCounts: { written: 1 },
    reconciliation: lease,
    startedAt: '2026-09-24T11:00:00.000Z',
    finishedAt: '2026-09-24T11:01:00.000Z',
    mode: 'full',
    executor: 'job',
  });
  assert.equal(status.id, `projection-status::${tenantId}::${lease.reconciliationGeneration}`);
  assert.equal(status.oid, `projection-status::${tenantId}`);
  assert.equal(status.type, 'projection-reconciliation-status');
  assert.equal(status.ttl, 604800);
  assert.equal(status.mode, 'full');
  assert.equal(status.executor, 'job');
  assert.equal(status.ok, true);
  assert.equal('oldestExpiresAt' in status, false);
  assert.equal('expiresAt' in status, false);
  assert.equal(plan.isStatusRecord(status), true);
  assert.equal(plan.isStatusPartitionKey(status.oid), true);
  assert.equal(plan.isStatusPartitionKey(lease.reconciliationGeneration), false);
});

test('status records cannot be returned as entitlements by point read or comparison query paths', () => {
  const status = {
    id: `projection-status::${tenantId}::${lease.reconciliationGeneration}`,
    oid: `projection-status::${tenantId}`,
    type: 'projection-reconciliation-status',
    tenantId,
    tier: 'standard',
    ...lease,
  };
  const point = toEntitlement(status, { tenantId, now });
  assert.equal(point.ok, false);
  assert.equal(point.status, 404);
  const r = plan.compareWithGateway({ standard: [] }, [{ ...status }], { tenantId, now });
  assert.equal(r.compared, 0);
  assert.deepEqual(r.differences, []);
});

test('status records are never deleted as orphaned entitlement records', () => {
  const statusPk = `projection-status::${tenantId}`;
  const r = plan.planChanges([{ oid, tier: 'standard' }], new Map([
    [oid, { tier: 'standard' }],
    [statusPk, { type: 'projection-reconciliation-status' }],
    ['33333333-3333-4333-8333-333333333333', { tier: 'premium' }],
  ]), { refresh: true });
  assert.deepEqual(r.toDelete, ['33333333-3333-4333-8333-333333333333']);
});

test('switch evidence requires one recent successful full status and live resolver-valid records', () => {
  const baseStatus = {
    type: 'projection-reconciliation-status',
    tenantId,
    accountResourceId: '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.DocumentDB/databaseAccounts/cosmos',
    databaseName: 'claude',
    containerName: 'entitlement',
    finishedAt: '2026-09-24T11:40:00.000Z',
    reconciliationGeneration: '33333333-3333-4333-8333-333333333333',
    mode: 'full',
    executor: 'runner',
    ok: true,
  };
  const expected = { tenantId, accountResourceId: baseStatus.accountResourceId, databaseName: 'claude', containerName: 'entitlement' };
  const entitlementRecords = [{ oid, tenantId, tier: 'standard', lastVerifiedAt: lease.lastVerifiedAt, reconciliationGeneration: lease.reconciliationGeneration }];
  const accepted = plan.evaluateProjectionAdmission({ statuses: [baseStatus], entitlementRecords, expected, now });
  assert.equal(accepted.ok, true);
  assert.deepEqual(accepted.newestFullSync, { finishedAt: baseStatus.finishedAt, executor: 'runner', generation: baseStatus.reconciliationGeneration });
  assert.equal(accepted.invalidCount, 0);

  assert.match(plan.evaluateProjectionAdmission({ statuses: [{ ...baseStatus, mode: 'user' }], entitlementRecords, expected, now }).reason, /full sync evidence/);
  assert.match(plan.evaluateProjectionAdmission({ statuses: [{ ...baseStatus, ok: false }], entitlementRecords, expected, now }).reason, /full sync evidence/);
  assert.match(plan.evaluateProjectionAdmission({ statuses: [{ ...baseStatus, finishedAt: '2026-09-23T11:00:00.000Z' }], entitlementRecords, expected, now, maxEvidenceAgeSeconds: 60 }).reason, /full sync evidence/);
  assert.match(plan.evaluateProjectionAdmission({ statuses: [{ ...baseStatus, accountResourceId: '/wrong' }], entitlementRecords, expected, now }).reason, /full sync evidence/);
  assert.match(plan.evaluateProjectionAdmission({ statuses: [baseStatus], expected, now }).reason, /live entitlement records/);
});

test('switch evidence counts only live records the resolver would refuse and hashes samples', () => {
  const status = {
    type: 'projection-reconciliation-status', tenantId,
    accountResourceId: '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.DocumentDB/databaseAccounts/cosmos',
    databaseName: 'claude', containerName: 'entitlement',
    finishedAt: '2026-09-24T11:40:00.000Z', reconciliationGeneration: lease.reconciliationGeneration,
    mode: 'full', executor: 'job', ok: true,
  };
  const expected = { tenantId, accountResourceId: status.accountResourceId, databaseName: 'claude', containerName: 'entitlement' };
  const records = [
    { oid, tenantId, tier: 'standard', lastVerifiedAt: lease.lastVerifiedAt, reconciliationGeneration: lease.reconciliationGeneration, expiresAt: 0 },
    { oid: '44444444-4444-4444-8444-444444444444', tenantId, tier: 'platinum', lastVerifiedAt: lease.lastVerifiedAt, reconciliationGeneration: lease.reconciliationGeneration },
    { oid: '55555555-5555-4555-8555-555555555555', tenantId, tier: 'standard', lastVerifiedAt: 'bad', reconciliationGeneration: lease.reconciliationGeneration },
    { oid: `projection-status::${tenantId}`, type: 'projection-reconciliation-status' },
  ];
  const evidence = plan.summarizeEntitlementEvidence(records, { tenantId, now });
  assert.equal(evidence.total, 3);
  assert.equal(evidence.invalidCount, 3);
  assert.equal(evidence.invalidSamples.length, 3);
  assert.match(evidence.invalidSamples[0].oidHash, /^[0-9a-f]{12}$/);
  assert.equal(JSON.stringify(evidence).includes('44444444-4444'), false);
  const admission = plan.evaluateProjectionAdmission({ statuses: [status], entitlementRecords: records, expected, now });
  assert.equal(admission.ok, false);
  assert.equal(admission.invalidCount, 3);
  assert.match(admission.reason, /would be refused by the resolver/);
});
