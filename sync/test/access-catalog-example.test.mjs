import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { validateAccessCatalog } from '../src/access-catalog.mjs';

const EXAMPLE_URL = new URL('../../config/access-catalog.example.json', import.meta.url);
const FAKE_TENANT_ID = '00000000-0000-4000-8000-000000000116';

const EXPECTED_PLANS = [
  ['standard-l1', 50, 'standard'],
  ['standard-l2', 100, 'standard'],
  ['standard-l3', 150, 'standard'],
  ['advanced-l1', 200, 'premium'],
  ['advanced-l2', 300, 'premium'],
  ['advanced-l3', 500, 'premium'],
  ['power-l1', 1000, 'premium'],
  ['power-l2', 2000, 'premium'],
  ['power-l3', 5000, 'premium'],
];

const EXPECTED_PROFILES = [
  ['standard-l1-code', 'standard-l1', 101, 'code', 'haiku,sonnet', ''],

  ['standard-l2-chat-design', 'standard-l2', 201, 'chat,design', 'haiku,sonnet', ''],
  ['standard-l2-code-chat', 'standard-l2', 202, 'code,chat', 'haiku,sonnet', ''],
  ['standard-l2-code-design', 'standard-l2', 203, 'code,design', 'haiku,sonnet', ''],
  ['standard-l2-cowork', 'standard-l2', 204, 'cowork', 'haiku,sonnet', ''],
  ['standard-l2-cowork-chat', 'standard-l2', 205, 'cowork,chat', 'haiku,sonnet', ''],
  ['standard-l2-cowork-design', 'standard-l2', 206, 'cowork,design', 'haiku,sonnet', ''],
  ['standard-l2-design', 'standard-l2', 207, 'design', 'haiku,sonnet', ''],

  ['standard-l3-code-chat-opus', 'standard-l3', 301, 'code,chat', 'haiku,sonnet,opus', ''],
  ['standard-l3-code-chat-design', 'standard-l3', 302, 'code,chat,design', 'haiku,sonnet', ''],
  ['standard-l3-code-cowork', 'standard-l3', 303, 'code,cowork', 'haiku,sonnet', ''],
  ['standard-l3-code-cowork-chat', 'standard-l3', 304, 'code,cowork,chat', 'haiku,sonnet', ''],
  ['standard-l3-code-cowork-design', 'standard-l3', 305, 'code,cowork,design', 'haiku,sonnet', ''],
  ['standard-l3-code-design-opus', 'standard-l3', 306, 'code,design', 'haiku,sonnet,opus', ''],
  ['standard-l3-cowork-chat-opus', 'standard-l3', 307, 'cowork,chat', 'haiku,sonnet,opus', ''],
  ['standard-l3-cowork-chat-design', 'standard-l3', 308, 'cowork,chat,design', 'haiku,sonnet', ''],
  ['standard-l3-cowork-design-opus', 'standard-l3', 309, 'cowork,design', 'haiku,sonnet,opus', ''],

  ['advanced-l1-chat-design', 'advanced-l1', 401, 'chat,design', 'haiku,sonnet,opus', ''],
  ['advanced-l1-all-capabilities', 'advanced-l1', 402, 'code,cowork,chat,design', 'haiku,sonnet', ''],
  ['advanced-l1-cowork', 'advanced-l1', 403, 'cowork', 'haiku,sonnet,opus', ''],
  ['advanced-l1-design', 'advanced-l1', 404, 'design', 'haiku,sonnet,opus', ''],

  ['advanced-l2-code', 'advanced-l2', 501, 'code', 'haiku,sonnet,opus', ''],
  ['advanced-l2-code-chat', 'advanced-l2', 502, 'code,chat', 'haiku,sonnet,opus', ''],
  ['advanced-l2-code-chat-design', 'advanced-l2', 503, 'code,chat,design', 'haiku,sonnet,opus', ''],
  ['advanced-l2-code-cowork', 'advanced-l2', 504, 'code,cowork', 'haiku,sonnet,opus', ''],
  ['advanced-l2-code-cowork-chat', 'advanced-l2', 505, 'code,cowork,chat', 'haiku,sonnet,opus', ''],
  ['advanced-l2-all-capabilities', 'advanced-l2', 506, 'code,cowork,chat,design', 'haiku,sonnet,opus', ''],
  ['advanced-l2-code-cowork-design', 'advanced-l2', 507, 'code,cowork,design', 'haiku,sonnet,opus', ''],
  ['advanced-l2-code-design', 'advanced-l2', 508, 'code,design', 'haiku,sonnet,opus', ''],
  ['advanced-l2-cowork-chat', 'advanced-l2', 509, 'cowork,chat', 'haiku,sonnet,opus', ''],
  ['advanced-l2-cowork-chat-design', 'advanced-l2', 510, 'cowork,chat,design', 'haiku,sonnet,opus', ''],
  ['advanced-l2-cowork-design', 'advanced-l2', 511, 'cowork,design', 'haiku,sonnet,opus', ''],

  ['advanced-l3-chat-design', 'advanced-l3', 601, 'chat,design', 'haiku,sonnet,opus', ''],
  ['advanced-l3-code', 'advanced-l3', 602, 'code', 'haiku,sonnet,opus', ''],
  ['advanced-l3-code-chat-design', 'advanced-l3', 603, 'code,chat,design', 'haiku,sonnet,opus', ''],
  ['advanced-l3-code-cowork', 'advanced-l3', 604, 'code,cowork', 'haiku,sonnet,opus', ''],
  ['advanced-l3-code-cowork-chat', 'advanced-l3', 605, 'code,cowork,chat', 'haiku,sonnet,opus', ''],
  ['advanced-l3-all-capabilities', 'advanced-l3', 606, 'code,cowork,chat,design', 'haiku,sonnet,opus', ''],
  ['advanced-l3-code-cowork-design', 'advanced-l3', 607, 'code,cowork,design', 'haiku,sonnet,opus', ''],
  ['advanced-l3-cowork', 'advanced-l3', 608, 'cowork', 'haiku,sonnet,opus', ''],
  ['advanced-l3-cowork-chat-design', 'advanced-l3', 609, 'cowork,chat,design', 'haiku,sonnet,opus', ''],
  ['advanced-l3-design', 'advanced-l3', 610, 'design', 'haiku,sonnet,opus', ''],

  ['power-l1-all-capabilities', 'power-l1', 701, 'code,cowork,chat,design', 'haiku,sonnet,opus', ''],
  ['power-l1-all-capabilities-m365', 'power-l1', 702, 'code,cowork,chat,design', 'haiku,sonnet,opus', 'm365'],
  ['power-l2-all-capabilities', 'power-l2', 801, 'code,cowork,chat,design', 'haiku,sonnet,opus,fable', ''],
  ['power-l3-all-capabilities', 'power-l3', 901, 'code,cowork,chat,design', 'haiku,sonnet,opus,fable', ''],
  ['power-l3-all-capabilities-m365', 'power-l3', 902, 'code,cowork,chat,design', 'haiku,sonnet,opus,fable', 'm365'],
];

function profileTuple(profile) {
  return [
    profile.id,
    profile.planId,
    profile.priority,
    profile.capabilities.join(','),
    profile.modelFamilies.join(','),
    profile.connectors.join(','),
  ];
}

function assertMatchesCustomerMatrix(catalog) {
  assert.doesNotThrow(() => validateAccessCatalog(catalog));
  assert.equal(catalog.tenantId, FAKE_TENANT_ID);
  assert.equal(catalog.plans.length, 9);
  assert.equal(catalog.profiles.length, 47);
  assert.deepEqual(
    catalog.plans.map((plan) => [plan.id, plan.nominalCredit.amount, plan.compatibilityTier]),
    EXPECTED_PLANS,
  );
  assert.deepEqual(catalog.profiles.map(profileTuple), EXPECTED_PROFILES);

  assert.ok(catalog.plans.every((plan) =>
    plan.enabled
    && plan.nominalCredit.currency === 'USD'
    && plan.nominalCredit.period === 'month'
    && plan.nominalCredit.scope === 'user'));
  assert.ok(catalog.profiles.every((profile) => profile.enabled && profile.name.length >= 12));
  assert.equal(new Set(catalog.profiles.map((profile) => profile.id)).size, 47);
  assert.equal(new Set(catalog.profiles.map((profile) => profile.groupObjectId)).size, 47);
  assert.equal(new Set(catalog.profiles.map((profile) => profile.priority)).size, 47);
  assert.ok(catalog.profiles.every((profile, index) =>
    profile.groupObjectId === `00000000-0000-4000-8000-${String(index + 1).padStart(12, '0')}`));
}

test('the deployable example exactly represents the nine-plan 47-profile customer matrix', async () => {
  const catalog = JSON.parse(await readFile(EXAMPLE_URL, 'utf8'));
  assertMatchesCustomerMatrix(catalog);
});

test('the customer-matrix assertion rejects a changed or removed combination', async () => {
  const catalog = JSON.parse(await readFile(EXAMPLE_URL, 'utf8'));

  const changed = structuredClone(catalog);
  changed.profiles[0].capabilities = ['chat'];
  assert.throws(() => assertMatchesCustomerMatrix(changed));

  const removed = structuredClone(catalog);
  removed.profiles.splice(20, 1);
  assert.throws(() => assertMatchesCustomerMatrix(removed));
});
