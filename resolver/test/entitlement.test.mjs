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
import { toEntitlement, isObjectId, KNOWN_TIERS } from '../src/entitlement.mjs';

const OID = '43cc5304-b62c-48c4-a49e-427d621c19a9';
const TENANT = '16b3c013-d300-468d-ac64-7eda0820b6d3';

test('a standard record resolves', () => {
  const r = toEntitlement(
    { id: OID, oid: OID, tenantId: TENANT, tier: 'standard', businessUnit: 'ites-1' },
    { tenantId: TENANT });
  assert.equal(r.ok, true);
  assert.equal(r.record.tier, 'standard');
  assert.equal(r.record.businessUnit, 'ites-1');
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
