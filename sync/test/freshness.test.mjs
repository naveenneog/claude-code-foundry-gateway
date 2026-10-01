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

test('status records use a non-guid partition and retain six hours of history', () => {
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
    oldestExpiresAt: lease.expiresAt,
    reconciliation: lease,
    startedAt: '2026-09-24T11:00:00.000Z',
    finishedAt: '2026-09-24T11:01:00.000Z',
  });
  assert.equal(status.id, `projection-status::${tenantId}::${lease.reconciliationGeneration}`);
  assert.equal(status.oid, `projection-status::${tenantId}`);
  assert.equal(status.type, 'projection-reconciliation-status');
  assert.equal(status.ttl, 21600);
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

test('admission requires fresh destination evidence, two advances, tested image and no overrides', () => {
  const baseStatus = {
    type: 'projection-reconciliation-status',
    tenantId,
    accountResourceId: '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.DocumentDB/databaseAccounts/cosmos',
    databaseName: 'claude',
    containerName: 'entitlement',
    finishedAt: '2026-09-24T11:40:00.000Z',
    oldestExpiresAt: Date.parse('2026-09-24T13:30:00Z') / 1000,
    imageDigest: 'sha256:' + 'a'.repeat(64),
    entrypoint: '/app/reconcile.mjs',
    dryRun: false,
    commandOverride: false,
  };
  const statuses = [
    { ...baseStatus, memberCounts: { standard: 1 }, reconciliationGeneration: '33333333-3333-4333-8333-333333333331', finishedAt: '2026-09-24T11:00:00.000Z' },
    { ...baseStatus, memberCounts: { standard: 1 }, reconciliationGeneration: '33333333-3333-4333-8333-333333333332', finishedAt: '2026-09-24T11:30:00.000Z' },
    { ...baseStatus, memberCounts: { standard: 1 }, reconciliationGeneration: '33333333-3333-4333-8333-333333333333' },
  ];
  const expected = {
    tenantId,
    accountResourceId: baseStatus.accountResourceId,
    databaseName: 'claude',
    containerName: 'entitlement',
    imageDigest: baseStatus.imageDigest,
    entrypoint: baseStatus.entrypoint,
  };
  const job = { image: baseStatus.imageDigest, command: [], args: [] };
  const entitlementEvidence = {
    total: 1,
    oldestExpiresAt: baseStatus.oldestExpiresAt,
    latestGeneration: '33333333-3333-4333-8333-333333333333',
    olderActiveCount: 0,
    memberCounts: { standard: 1 },
  };
  assert.equal(plan.evaluateProjectionAdmission({ statuses, entitlementEvidence, expected, job, now }).ok, true);
  assert.match(plan.evaluateProjectionAdmission({ statuses: statuses.slice(2), entitlementEvidence, expected, job, now }).reason, /advanced at least twice/);
  const lowExpiry = Date.parse('2026-09-24T12:50:00Z') / 1000;
  assert.match(plan.evaluateProjectionAdmission({ statuses: statuses.map(s => ({ ...s, oldestExpiresAt: lowExpiry })), entitlementEvidence: { ...entitlementEvidence, oldestExpiresAt: lowExpiry }, expected, job, now }).reason, /60 minute/);
  assert.match(plan.evaluateProjectionAdmission({ statuses: statuses.map(s => ({ ...s, finishedAt: '2026-09-24T11:00:00.000Z' })), entitlementEvidence, expected, job, now }).reason, /45 minute/);
  assert.match(plan.evaluateProjectionAdmission({ statuses: statuses.map(s => ({ ...s, accountResourceId: '/wrong' })), entitlementEvidence, expected, job, now }).reason, /destination/);
  assert.match(plan.evaluateProjectionAdmission({ statuses, entitlementEvidence, expected, job: { ...job, args: ['--whatif'] }, now }).reason, /override|dry-run/);
  assert.match(plan.evaluateProjectionAdmission({ statuses, entitlementEvidence, expected: { ...expected, actionGroupResourceId: '' }, job, now }).reason, /action group/);
  assert.match(plan.evaluateProjectionAdmission({ statuses, expected, job, now }).reason, /entitlement records/);
  assert.match(plan.evaluateProjectionAdmission({ statuses, entitlementEvidence: { ...entitlementEvidence, oldestExpiresAt: baseStatus.oldestExpiresAt - 60 }, expected, job, now }).reason, /mismatch/);
  assert.match(plan.evaluateProjectionAdmission({ statuses, entitlementEvidence: { ...entitlementEvidence, olderActiveCount: 1 }, expected, job, now }).reason, /older generation/);
  assert.match(plan.evaluateProjectionAdmission({ statuses, entitlementEvidence: { ...entitlementEvidence, memberCounts: { standard: 2 } }, expected, job, now }).reason, /member count/);
});

test('admission computes freshness from resolver-served entitlement records, not status claims', () => {
  const latest = '33333333-3333-4333-8333-333333333333';
  const older = '33333333-3333-4333-8333-333333333332';
  const baseStatus = {
    type: 'projection-reconciliation-status',
    tenantId,
    accountResourceId: '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.DocumentDB/databaseAccounts/cosmos',
    databaseName: 'claude',
    containerName: 'entitlement',
    imageDigest: 'sha256:' + 'a'.repeat(64),
    entrypoint: '/app/reconcile.mjs',
    dryRun: false,
    commandOverride: false,
    memberCounts: { standard: 1 },
    oldestExpiresAt: Date.parse('2026-09-24T13:30:00Z') / 1000,
  };
  const statuses = [
    { ...baseStatus, reconciliationGeneration: '33333333-3333-4333-8333-333333333331', finishedAt: '2026-09-24T11:00:00.000Z' },
    { ...baseStatus, reconciliationGeneration: older, finishedAt: '2026-09-24T11:30:00.000Z' },
    { ...baseStatus, reconciliationGeneration: latest, finishedAt: '2026-09-24T11:40:00.000Z' },
  ];
  const expected = {
    tenantId,
    accountResourceId: baseStatus.accountResourceId,
    databaseName: 'claude',
    containerName: 'entitlement',
    imageDigest: baseStatus.imageDigest,
    entrypoint: baseStatus.entrypoint,
    actionGroupResourceId: '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Insights/actionGroups/ag',
  };
  const job = { image: baseStatus.imageDigest, command: [], args: [] };
  const staleRecords = [{ oid, tenantId, tier: 'standard', reconciliationGeneration: older, expiresAt: Date.parse('2026-09-24T13:30:00Z') / 1000 }];
  assert.match(plan.evaluateProjectionAdmission({ statuses, entitlementRecords: staleRecords, expected, job, now }).reason, /older generation/);
  const mismatchExpiry = [{ ...staleRecords[0], reconciliationGeneration: latest, expiresAt: Date.parse('2026-09-24T13:00:00Z') / 1000 }];
  assert.match(plan.evaluateProjectionAdmission({ statuses, entitlementRecords: mismatchExpiry, expected, job, now }).reason, /oldest expiry mismatch/);
  const mismatchCount = [
    { ...staleRecords[0], reconciliationGeneration: latest },
    { oid: '44444444-4444-4444-8444-444444444444', tenantId, tier: 'standard', reconciliationGeneration: latest, expiresAt: staleRecords[0].expiresAt },
  ];
  assert.match(plan.evaluateProjectionAdmission({ statuses, entitlementRecords: mismatchCount, expected, job, now }).reason, /member count/);
});
