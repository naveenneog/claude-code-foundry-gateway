/**
 * The resolver's decisions, tested without Azure.
 *
 *   node --test resolver/test/
 *
 * Everything here is a pure function of a document, which is why the Azure
 * wiring was kept out of entitlement.mjs. A test that needed a Cosmos account
 * would not be run, and a decision nobody runs is a decision nobody checked.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { toEntitlement as resolveDocument, isObjectId, KNOWN_TIERS } from '../src/entitlement.mjs';

// Existing authorization cases use a current generation and verification time;
// record freshness boundary cases exercise the unwrapped resolver in
// sync/test/freshness.test.mjs.
const toEntitlement = (doc, options) => resolveDocument(doc ? {
  reconciliationGeneration: '33333333-3333-4333-8333-333333333333',
  lastVerifiedAt: new Date().toISOString(),
  ...doc,
} : doc, options);

const OID = '7f2a1c94-3e5b-4d81-9a06-b1e4c8d72f35';
const TENANT = '11111111-2222-3333-4444-555555555555';
const CATALOG_VERSION = `sha256:${'a'.repeat(64)}`;
const PROFILE_HASH = `sha256:${'b'.repeat(64)}`;

const expandedRecord = (overrides = {}) => ({
  id: OID,
  oid: OID,
  tenantId: TENANT,
  schemaVersion: 3,
  tier: 'premium',
  planId: 'developer-plus',
  profileId: 'design-m365',
  capabilities: ['code', 'cowork', 'chat', 'design'],
  modelFamilies: ['haiku', 'sonnet', 'opus', 'fable', 'mythos'],
  connectors: ['m365'],
  catalogVersion: CATALOG_VERSION,
  profileHash: PROFILE_HASH,
  businessUnit: 'ites-1',
  mappingVersion: 17,
  effectiveFrom: '2026-10-14T10:00:00.000Z',
  ...overrides,
});

test('a standard record resolves', () => {
  const r = toEntitlement(
    { id: OID, oid: OID, tenantId: TENANT, tier: 'standard', businessUnit: 'ites-1' },
    { tenantId: TENANT });
  assert.equal(r.ok, true);
  assert.equal(r.record.tier, 'standard');
  assert.equal(r.record.businessUnit, 'ites-1');
  assert.equal('expiresAt' in r.record, false);
});

test('an absent record is not entitled, and is not an error', () => {
  const r = toEntitlement(null, { tenantId: TENANT });
  assert.equal(r.ok, false);
  assert.equal(r.status, 404, 'absent must read as not-entitled rather than a fault');
});

test('a record from another tenant is refused', () => {
  // Object ids are unique within a tenant, not across them. Without this a
  // lookup could be satisfied by the wrong directory.
  const r = toEntitlement(
    { id: OID, tenantId: 'ffffffff-ffff-ffff-ffff-ffffffffffff', tier: 'premium' },
    { tenantId: TENANT });
  assert.equal(r.ok, false);
  assert.equal(r.status, 403);
});

test('a tier the policy does not implement is refused, not passed through', () => {
  // The gateway has two branches. A third tier would be accepted here and then
  // silently unenforced there, which is worse than refusing it.
  const r = toEntitlement({ id: OID, tenantId: TENANT, tier: 'platinum' }, { tenantId: TENANT });
  assert.equal(r.ok, false);
  assert.equal(r.status, 409);
  assert.match(r.reason, /does not implement/);
});

test('every known tier is accepted', () => {
  for (const tier of KNOWN_TIERS) {
    const r = toEntitlement({ id: OID, tenantId: TENANT, tier }, { tenantId: TENANT });
    assert.equal(r.ok, true, `${tier} should resolve`);
  }
});

test('schema version 3 returns the expanded access profile and reconciliation evidence', () => {
  const lastVerifiedAt = '2026-10-14T12:00:00.000Z';
  const reconciliationGeneration = '33333333-3333-4333-8333-333333333333';
  const r = toEntitlement(expandedRecord({ lastVerifiedAt, reconciliationGeneration }), {
    tenantId: TENANT,
    now: new Date('2026-10-14T13:00:00.000Z'),
  });

  assert.equal(r.ok, true);
  assert.deepEqual(r.record, {
    oid: OID,
    schemaVersion: 3,
    tier: 'premium',
    planId: 'developer-plus',
    profileId: 'design-m365',
    capabilities: ['code', 'cowork', 'chat', 'design'],
    modelFamilies: ['haiku', 'sonnet', 'opus', 'fable', 'mythos'],
    connectors: ['m365'],
    catalogVersion: CATALOG_VERSION,
    profileHash: PROFILE_HASH,
    businessUnit: 'ites-1',
    mappingVersion: 17,
    effectiveFrom: '2026-10-14T10:00:00.000Z',
    reconciliationGeneration,
  });
});

test('schema version 3 accepts both compatibility buckets and empty subsets', () => {
  for (const tier of KNOWN_TIERS) {
    const r = toEntitlement(expandedRecord({
      tier,
      capabilities: [],
      modelFamilies: [],
      connectors: [],
    }), { tenantId: TENANT });
    assert.equal(r.ok, true, `${tier} should resolve`);
    assert.equal(r.record.tier, tier);
    assert.deepEqual(r.record.capabilities, []);
    assert.deepEqual(r.record.modelFamilies, []);
    assert.deepEqual(r.record.connectors, []);
  }
});

test('legacy standard and premium records retain their exact response shape', () => {
  for (const tier of KNOWN_TIERS) {
    const r = toEntitlement({
      id: OID,
      tenantId: TENANT,
      tier,
      businessUnit: 'ites-1',
      mappingVersion: 9,
      effectiveFrom: '2026-10-13T10:00:00.000Z',
    }, { tenantId: TENANT });
    assert.deepEqual(r, {
      ok: true,
      record: {
        oid: OID,
        tier,
        businessUnit: 'ites-1',
        mappingVersion: 9,
        effectiveFrom: '2026-10-13T10:00:00.000Z',
        reconciliationGeneration: '33333333-3333-4333-8333-333333333333',
      },
    });
  }
});

test('schema version 3 rejects malformed canonical ids and hashes', () => {
  const cases = [
    ['planId', 'Developer-Plus'],
    ['planId', 'developer_plus'],
    ['planId', ''],
    ['planId', 'a'.repeat(65)],
    ['profileId', 'design M365'],
    ['profileId', '-design'],
    ['profileId', 42],
    ['catalogVersion', `sha256:${'A'.repeat(64)}`],
    ['catalogVersion', `sha256:${'a'.repeat(63)}`],
    ['catalogVersion', 'a'.repeat(64)],
    ['profileHash', `sha256:${'g'.repeat(64)}`],
    ['profileHash', `sha256:${'b'.repeat(65)}`],
    ['profileHash', ''],
  ];

  for (const [field, value] of cases) {
    const r = toEntitlement(expandedRecord({ [field]: value }), { tenantId: TENANT });
    assert.equal(r.ok, false, `${field}=${value} must be refused`);
    assert.equal(r.status, 409);
    assert.match(r.reason, /schema version 3 record is invalid/);
  }
});

test('schema version 3 rejects unknown, duplicate and malformed subsets without stripping values', () => {
  const cases = [
    ['capabilities', ['code', 'unknown']],
    ['capabilities', ['code', 'code']],
    ['capabilities', 'code'],
    ['modelFamilies', ['sonnet', 'unknown']],
    ['modelFamilies', ['sonnet', 'sonnet']],
    ['modelFamilies', null],
    ['connectors', ['m365', 'unknown']],
    ['connectors', ['m365', 'm365']],
    ['connectors', { m365: true }],
  ];

  for (const [field, value] of cases) {
    const r = toEntitlement(expandedRecord({ [field]: value }), { tenantId: TENANT });
    assert.equal(r.ok, false, `${field}=${JSON.stringify(value)} must be refused`);
    assert.equal(r.status, 409);
    assert.match(r.reason, /schema version 3 record is invalid/);
  }
});

test('schema version 3 requires every expanded field', () => {
  for (const field of [
    'planId',
    'profileId',
    'capabilities',
    'modelFamilies',
    'connectors',
    'catalogVersion',
    'profileHash',
  ]) {
    const doc = expandedRecord();
    delete doc[field];
    const r = toEntitlement(doc, { tenantId: TENANT });
    assert.equal(r.ok, false, `${field} must be required`);
    assert.equal(r.status, 409);
    assert.match(r.reason, /schema version 3 record is invalid/);
  }
});

test('schema version 3 keeps existing control, tenant and verification failure contracts', () => {
  const cases = [
    [expandedRecord({ type: 'access-catalog' }), 404, /control record/],
    [expandedRecord({ tenantId: 'ffffffff-ffff-ffff-ffff-ffffffffffff' }), 403, /different tenant/],
    [expandedRecord({ lastVerifiedAt: '2026-10-15T00:00:00.000Z' }), 503, /projection record is invalid/],
    [expandedRecord({ lastVerifiedAt: 'not-a-date' }), 503, /projection record is invalid/],
    [expandedRecord({ reconciliationGeneration: 'not-an-object-id' }), 503, /projection record is invalid/],
  ];

  for (const [doc, status, reason] of cases) {
    const r = toEntitlement(doc, {
      tenantId: TENANT,
      now: new Date('2026-10-14T23:00:00.000Z'),
    });
    assert.equal(r.ok, false);
    assert.equal(r.status, status);
    assert.match(r.reason, reason);
  }
});

test('a legacy expiresAt grants only until that legacy deadline passes', () => {
  const legacyExpiresAt = Date.parse('2026-10-05T11:00:00.000Z') / 1000;
  const beforeExpiry = toEntitlement(
    { id: OID, tenantId: TENANT, tier: 'standard', expiresAt: legacyExpiresAt, lastVerifiedAt: '2026-10-05T09:00:00.000Z' },
    { tenantId: TENANT, now: new Date('2026-10-05T10:00:00.000Z') });
  assert.equal(beforeExpiry.ok, true);
  assert.equal('expiresAt' in beforeExpiry.record, false);

  const afterExpiry = toEntitlement(
    { id: OID, tenantId: TENANT, tier: 'standard', expiresAt: legacyExpiresAt, lastVerifiedAt: '2026-10-05T09:00:00.000Z' },
    { tenantId: TENANT, now: new Date('2026-10-05T12:00:00.000Z') });
  assert.equal(afterExpiry.ok, false);
  assert.equal(afterExpiry.status, 404);
  assert.match(afterExpiry.reason, /legacy projection record expired/);
});

test('a record that is not effective yet does not grant access', () => {
  // This is what lets a population be staged before a cutover without granting
  // anyone access early - ADR-0009 phase 1.
  const future = new Date(Date.now() + 86400000).toISOString();
  const r = toEntitlement(
    { id: OID, tenantId: TENANT, tier: 'premium', effectiveFrom: future },
    { tenantId: TENANT });
  assert.equal(r.ok, false);
  assert.equal(r.status, 404);
});

test('a record that became effective in the past does grant access', () => {
  const past = new Date(Date.now() - 86400000).toISOString();
  const r = toEntitlement(
    { id: OID, tenantId: TENANT, tier: 'premium', effectiveFrom: past },
    { tenantId: TENANT });
  assert.equal(r.ok, true);
});

test('an unparseable effectiveFrom does not silently withhold access', () => {
  // A malformed date must not be treated as "the future" and quietly deny an
  // entitled developer. It is ignored, and the record stands on its tier.
  const r = toEntitlement(
    { id: OID, tenantId: TENANT, tier: 'standard', effectiveFrom: 'not-a-date' },
    { tenantId: TENANT });
  assert.equal(r.ok, true);
});

test('an unassigned developer reads as empty, matching the other source', () => {
  const r = toEntitlement({ id: OID, tenantId: TENANT, tier: 'standard' }, { tenantId: TENANT });
  assert.equal(r.ok, true);
  assert.equal(r.record.businessUnit, '', 'the policy coalesces this to unassigned');
});

test('object ids are validated before they reach a resource path', () => {
  assert.equal(isObjectId(OID), true);
  for (const bad of ['', 'not-a-guid', '../../etc/passwd', `${OID}'`, null, undefined, 12345]) {
    assert.equal(isObjectId(bad), false, `${String(bad)} must not pass`);
  }
});
