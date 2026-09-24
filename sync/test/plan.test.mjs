import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mergeMembership, planChanges, toDocument, validateSnapshot, createReconciliation } from '../src/plan.mjs';
const lease = createReconciliation({ verifiedAt: new Date() });

const A = '11111111-1111-1111-1111-111111111111';
const B = '22222222-2222-2222-2222-222222222222';
const C = '33333333-3333-3333-3333-333333333333';
const T = '11111111-2222-3333-4444-555555555555';

test('premium wins over standard, as the policy checks premium first', () => {
  const { records } = mergeMembership({ tiers: { standard: [{ oid: A }], premium: [{ oid: A }] } });
  assert.equal(records.length, 1);
  assert.equal(records[0].tier, 'premium');
});

test('a business unit alone is not entitlement', () => {
  const { records, unitWithoutTier } = mergeMembership({
    tiers: { standard: [{ oid: A }] },
    businessUnits: [{ id: 'sales', members: [{ oid: A }, { oid: B }] }],
  });
  assert.deepEqual(records.map((r) => [r.oid, r.businessUnit]), [[A, 'sales']]);
  assert.deepEqual(unitWithoutTier, [{ oid: B, unit: 'sales' }]);
});

test('the first unit in precedence order wins, as bu-members is written', () => {
  // A team listed before the unit that contains it keeps its members.
  const { records } = mergeMembership({
    tiers: { standard: [{ oid: A }] },
    businessUnits: [{ id: 'team', members: [{ oid: A }] }, { id: 'parent', members: [{ oid: A }] }],
  });
  assert.equal(records[0].businessUnit, 'team');
});

test('an empty directory never revokes everyone', () => {
  const plan = planChanges([], new Map([[A, { tier: 'standard', businessUnit: '' }]]));
  assert.equal(plan.refused, true);
  assert.match(plan.reason, /refusing/);
});

test('unless the emptiness is declared real', () => {
  const plan = planChanges([], new Map([[A, { tier: 'standard', businessUnit: '' }]]), { allowEmpty: true });
  assert.equal(plan.refused, false);
  assert.deepEqual(plan.toDelete, [A]);
});

test('unchanged records are not rewritten', () => {
  const plan = planChanges([{ oid: A, tier: 'standard', businessUnit: '' }], new Map([[A, { tier: 'standard', businessUnit: '' }]]));
  assert.equal(plan.unchanged, 1);
  assert.equal(plan.toWrite.length, 0);
});

test('a tier or unit change is rewritten', () => {
  const existing = new Map([[A, { tier: 'standard', businessUnit: '' }], [B, { tier: 'standard', businessUnit: 'x' }]]);
  const plan = planChanges([{ oid: A, tier: 'premium', businessUnit: '' }, { oid: B, tier: 'standard', businessUnit: 'y' }], existing);
  assert.deepEqual(plan.toWrite.map((r) => r.oid), [A, B]);
});

test('someone removed from every group loses their record', () => {
  const existing = new Map([[A, { tier: 'standard' }], [C, { tier: 'premium' }]]);
  const plan = planChanges([{ oid: A, tier: 'standard' }], existing);
  assert.deepEqual(plan.toDelete, [C]);
});

test('orphans are kept only when asked, and reported', () => {
  const existing = new Map([[A, { tier: 'standard' }], [C, { tier: 'premium' }]]);
  const plan = planChanges([{ oid: A, tier: 'standard' }], existing, { keepOrphans: true });
  assert.deepEqual(plan.toDelete, []);
  assert.deepEqual(plan.keptOrphans, [C]);
});

test('the document is a point-read shape: id and partition key are the oid', () => {
  const d = toDocument({ oid: A, tier: 'premium', businessUnit: 'sales' }, { tenantId: T, mappingVersion: 7 });
  assert.equal(d.id, A);
  assert.equal(d.oid, A);
  assert.equal(d.tenantId, T);
  assert.equal(d.effectiveFrom, null);
});

test('the flip comparison names what each identity would experience', async () => {
  const { compareWithGateway } = await import('../src/plan.mjs');
  const gateway = { premium: [A], standard: [B, C], businessUnits: { [B]: 'sales' } };
  const records = [
    { oid: A, tier: 'standard', businessUnit: '', tenantId: T },       // tier-drift
    { oid: B, tier: 'standard', businessUnit: 'finance', tenantId: T }, // unit-drift
    // C absent                                                          // would-lose-access
    { oid: '44444444-4444-4444-4444-444444444444', tier: 'standard', tenantId: T }, // would-gain-access
  ];
  const { compared, differences } = compareWithGateway(gateway, records.map(r => ({ ...lease, ...r })), { tenantId: T });
  assert.equal(compared, 4);
  const kinds = Object.fromEntries(differences.map((d) => [d.oid, d.kind]));
  assert.equal(kinds[A], 'tier-drift');
  assert.equal(kinds[B], 'unit-drift');
  assert.equal(kinds[C], 'would-lose-access');
  assert.equal(kinds['44444444-4444-4444-4444-444444444444'], 'would-gain-access');
});

test('agreement is reported as no differences, and another tenant counts as no record', async () => {
  const { compareWithGateway } = await import('../src/plan.mjs');
  const same = compareWithGateway({ premium: [], standard: [A] }, [{ oid: A, tier: 'standard', businessUnit: '', tenantId: T, ...lease }], { tenantId: T });
  assert.deepEqual(same.differences, []);
  const foreign = compareWithGateway({ standard: [A] }, [{ oid: A, tier: 'standard', tenantId: '00000000-0000-0000-0000-000000000000', ...lease }], { tenantId: T });
  assert.equal(foreign.differences[0].kind, 'would-lose-access');
});

test('a snapshot for another tenant is refused before anything is written', () => {
  const snap = { kind: 'claude-entitlement-snapshot', tenantId: T, ...lease, records: [{ oid: A, tier: 'standard' }] };
  assert.deepEqual(validateSnapshot(snap, { tenantId: T }), []);
  assert.match(validateSnapshot(snap, { tenantId: '00000000-0000-0000-0000-000000000000' }).join(), /not 00000000/);
});

test('a snapshot with an unknown tier, a bad oid or a duplicate is refused', () => {
  const base = { kind: 'claude-entitlement-snapshot', tenantId: T, ...lease };
  assert.match(validateSnapshot({ ...base, records: [{ oid: A, tier: 'gold' }] }).join(), /tier 'gold'/);
  assert.match(validateSnapshot({ ...base, records: [{ oid: 'not-a-guid', tier: 'standard' }] }).join(), /not a guid/);
  assert.match(validateSnapshot({ ...base, records: [{ oid: A, tier: 'standard' }, { oid: A, tier: 'premium' }] }).join(), /twice/);
  assert.match(validateSnapshot({ tenantId: T, records: [] }).join(), /kind/);
});
