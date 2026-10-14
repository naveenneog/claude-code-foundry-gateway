import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  canonicalizeAccessCatalog,
  hashAccessCatalog,
  normalizeAccessCatalogDocument,
  selectProfileForMemberships,
  validateAccessCatalog,
} from '../src/access-catalog.mjs';
import { prepareAccessCatalogDocument } from '../src/access-catalog-administration.mjs';

const TENANT = '11111111-2222-4333-8444-555555555555';

function guid(number) {
  return `aaaaaaaa-bbbb-4ccc-8ddd-${number.toString(16).padStart(12, '0')}`;
}

function makePlan(index, overrides = {}) {
  return {
    id: `plan-${String(index).padStart(2, '0')}`,
    name: `Plan ${index}`,
    enabled: true,
    nominalCredit: {
      amount: index * 100,
      currency: 'USD',
      period: 'month',
      scope: 'user',
    },
    compatibilityTier: index % 2 === 0 ? 'premium' : 'standard',
    ...overrides,
  };
}

function makeProfile(index, overrides = {}) {
  const families = ['haiku', 'sonnet', 'opus', 'fable', 'mythos'];
  const capabilities = ['code', 'cowork', 'chat', 'design'];
  return {
    id: `profile-${String(index).padStart(2, '0')}`,
    name: `Profile ${index}`,
    planId: `plan-${String(((index - 1) % 9) + 1).padStart(2, '0')}`,
    groupObjectId: guid(index),
    priority: index,
    capabilities: [capabilities[(index - 1) % capabilities.length]],
    modelFamilies: [families[(index - 1) % families.length]],
    connectors: index % 3 === 0 ? ['m365'] : [],
    enabled: true,
    ...overrides,
  };
}

function makeCatalog({ planCount = 9, profileCount = 47 } = {}) {
  return {
    schemaVersion: 1,
    tenantId: TENANT,
    plans: Array.from({ length: planCount }, (_, index) => makePlan(index + 1)),
    profiles: Array.from({ length: profileCount }, (_, index) => makeProfile(index + 1, {
      planId: `plan-${String((index % Math.max(planCount, 1)) + 1).padStart(2, '0')}`,
    })),
  };
}

function clone(value) {
  return structuredClone(value);
}

function reverseObjectKeys(value) {
  if (Array.isArray(value)) return value.map(reverseObjectKeys);
  if (!value || typeof value !== 'object') return value;
  return Object.fromEntries(
    Object.entries(value).reverse().map(([key, child]) => [key, reverseObjectKeys(child)]),
  );
}

test('the supplied scale of nine plans and 47 profiles validates', () => {
  const catalog = makeCatalog();
  assert.doesNotThrow(() => validateAccessCatalog(catalog));
  assert.equal(catalog.plans.length, 9);
  assert.equal(catalog.profiles.length, 47);
});

test('the catalog is one version-one tenant object with only its schema fields', () => {
  const catalog = makeCatalog({ planCount: 1, profileCount: 1 });
  for (const invalid of [null, [], 'catalog', 1]) {
    assert.throws(() => validateAccessCatalog(invalid), /catalog.*object/i);
  }
  assert.throws(() => validateAccessCatalog({ ...catalog, schemaVersion: 2 }), /schemaVersion.*1/i);
  assert.throws(() => validateAccessCatalog({ ...catalog, tenantId: 'not-a-guid' }), /tenantId.*guid/i);
  assert.throws(() => validateAccessCatalog({ ...catalog, extra: true }), /unknown.*extra/i);
});

test('limits count enabled and disabled entries', () => {
  assert.throws(() => validateAccessCatalog(makeCatalog({ planCount: 0, profileCount: 1 })), /plans.*1.*16/i);
  assert.throws(() => validateAccessCatalog(makeCatalog({ planCount: 17, profileCount: 1 })), /plans.*1.*16/i);
  assert.throws(() => validateAccessCatalog(makeCatalog({ planCount: 1, profileCount: 0 })), /profiles.*1.*64/i);

  const tooMany = makeCatalog({ planCount: 1, profileCount: 65 });
  tooMany.profiles.forEach((profile) => { profile.enabled = false; });
  assert.throws(() => validateAccessCatalog(tooMany), /profiles.*1.*64/i);
});

test('plan ids are canonical and unique and plan fields are complete', () => {
  const catalog = makeCatalog({ planCount: 2, profileCount: 1 });
  catalog.plans[1].id = catalog.plans[0].id;
  assert.throws(() => validateAccessCatalog(catalog), /plan id.*unique/i);

  for (const [change, pattern] of [
    [(plan) => { plan.id = 'Plan-One'; }, /plan.*id.*lowercase/i],
    [(plan) => { plan.name = ''; }, /plan.*name/i],
    [(plan) => { delete plan.enabled; }, /plan.*enabled.*boolean/i],
    [(plan) => { plan.compatibilityTier = 'enterprise'; }, /compatibilityTier.*standard.*premium/i],
    [(plan) => { plan.extra = true; }, /plan.*unknown.*extra/i],
  ]) {
    const invalid = makeCatalog({ planCount: 1, profileCount: 1 });
    change(invalid.plans[0]);
    assert.throws(() => validateAccessCatalog(invalid), pattern);
  }
});

test('nominal credit is a bounded positive monthly per-user USD amount', () => {
  for (const amount of [0, -1, Number.NaN, Number.POSITIVE_INFINITY, 1000000.01]) {
    const catalog = makeCatalog({ planCount: 1, profileCount: 1 });
    catalog.plans[0].nominalCredit.amount = amount;
    assert.throws(() => validateAccessCatalog(catalog), /amount.*positive.*1000000/i);
  }
  const maximum = makeCatalog({ planCount: 1, profileCount: 1 });
  maximum.plans[0].nominalCredit.amount = 1000000;
  assert.doesNotThrow(() => validateAccessCatalog(maximum));

  for (const [field, value, pattern] of [
    ['currency', 'EUR', /currency.*USD/i],
    ['period', 'year', /period.*month/i],
    ['scope', 'organization', /scope.*user/i],
  ]) {
    const catalog = makeCatalog({ planCount: 1, profileCount: 1 });
    catalog.plans[0].nominalCredit[field] = value;
    assert.throws(() => validateAccessCatalog(catalog), pattern);
  }
  const extra = makeCatalog({ planCount: 1, profileCount: 1 });
  extra.plans[0].nominalCredit.extra = true;
  assert.throws(() => validateAccessCatalog(extra), /nominalCredit.*unknown.*extra/i);
});

test('profile ids are canonical and unique and scalar fields have the required types', () => {
  const duplicate = makeCatalog({ planCount: 1, profileCount: 2 });
  duplicate.profiles[1].id = duplicate.profiles[0].id;
  assert.throws(() => validateAccessCatalog(duplicate), /profile id.*unique/i);

  for (const [change, pattern] of [
    [(profile) => { profile.id = 'Profile-One'; }, /profile.*id.*lowercase/i],
    [(profile) => { profile.name = ''; }, /profile.*name/i],
    [(profile) => { profile.planId = 'Plan-01'; }, /planId.*lowercase/i],
    [(profile) => { profile.groupObjectId = 'not-a-guid'; }, /groupObjectId.*guid/i],
    [(profile) => { profile.priority = 1.5; }, /priority.*integer/i],
    [(profile) => { profile.priority = Number.MAX_SAFE_INTEGER + 1; }, /priority.*integer/i],
    [(profile) => { profile.enabled = 'yes'; }, /enabled.*boolean/i],
    [(profile) => { profile.extra = true; }, /profile.*unknown.*extra/i],
  ]) {
    const invalid = makeCatalog({ planCount: 1, profileCount: 1 });
    change(invalid.profiles[0]);
    assert.throws(() => validateAccessCatalog(invalid), pattern);
  }
});

test('profile dimensions are arrays of unique canonical allowed values', () => {
  for (const [field, invalidValue, pattern] of [
    ['capabilities', ['search'], /capabilities.*code.*cowork.*chat.*design/i],
    ['modelFamilies', ['instant'], /modelFamilies.*haiku.*sonnet.*opus.*fable.*mythos/i],
    ['connectors', ['github'], /connectors.*m365/i],
    ['capabilities', 'code', /capabilities.*array/i],
    ['modelFamilies', ['sonnet', 'sonnet'], /modelFamilies.*unique/i],
    ['connectors', ['m365', 'm365'], /connectors.*unique/i],
  ]) {
    const catalog = makeCatalog({ planCount: 1, profileCount: 1 });
    catalog.profiles[0][field] = invalidValue;
    assert.throws(() => validateAccessCatalog(catalog), pattern);
  }

  const emptyDimensions = makeCatalog({ planCount: 1, profileCount: 1 });
  emptyDimensions.profiles[0].capabilities = [];
  emptyDimensions.profiles[0].modelFamilies = [];
  emptyDimensions.profiles[0].connectors = [];
  assert.doesNotThrow(() => validateAccessCatalog(emptyDimensions));
});

test('enabled profiles reference enabled plans', () => {
  const missing = makeCatalog({ planCount: 1, profileCount: 1 });
  missing.profiles[0].planId = 'missing';
  assert.throws(() => validateAccessCatalog(missing), /enabled profile.*existing enabled plan/i);

  const disabledPlan = makeCatalog({ planCount: 1, profileCount: 1 });
  disabledPlan.plans[0].enabled = false;
  assert.throws(() => validateAccessCatalog(disabledPlan), /enabled profile.*existing enabled plan/i);

  const disabledProfile = clone(disabledPlan);
  disabledProfile.profiles[0].enabled = false;
  assert.doesNotThrow(() => validateAccessCatalog(disabledProfile));
});

test('enabled profiles have unique group object ids and exact priorities', () => {
  const duplicateGroup = makeCatalog({ planCount: 1, profileCount: 2 });
  duplicateGroup.profiles[1].groupObjectId = duplicateGroup.profiles[0].groupObjectId;
  assert.throws(() => validateAccessCatalog(duplicateGroup), /enabled profile.*groupObjectId.*unique/i);

  const duplicatePriority = makeCatalog({ planCount: 1, profileCount: 2 });
  duplicatePriority.profiles[1].priority = duplicatePriority.profiles[0].priority;
  assert.throws(() => validateAccessCatalog(duplicatePriority), /enabled profile.*priority.*unique/i);

  duplicateGroup.profiles[1].enabled = false;
  duplicateGroup.profiles[1].priority = duplicateGroup.profiles[0].priority;
  assert.doesNotThrow(() => validateAccessCatalog(duplicateGroup));
});

test('canonicalization lowercases ids and dimensions, sorts unordered arrays and does not mutate input', () => {
  const input = makeCatalog({ planCount: 2, profileCount: 2 });
  input.tenantId = TENANT.toUpperCase();
  input.plans[0].id = 'PLAN-01';
  input.profiles[0] = {
    ...input.profiles[0],
    id: 'PROFILE-01',
    planId: 'PLAN-01',
    groupObjectId: guid(1).toUpperCase(),
    capabilities: ['DESIGN', 'CODE'],
    modelFamilies: ['OPUS', 'HAIKU'],
    connectors: ['M365'],
  };
  input.plans.reverse();
  input.profiles.reverse();
  const before = clone(input);

  const canonical = canonicalizeAccessCatalog(input);

  assert.deepEqual(input, before);
  assert.equal(canonical.tenantId, TENANT);
  assert.deepEqual(canonical.plans.map((plan) => plan.id), ['plan-01', 'plan-02']);
  assert.deepEqual(canonical.profiles.map((profile) => profile.id), ['profile-01', 'profile-02']);
  assert.deepEqual(canonical.profiles[0].capabilities, ['code', 'design']);
  assert.deepEqual(canonical.profiles[0].modelFamilies, ['haiku', 'opus']);
  assert.deepEqual(canonical.profiles[0].connectors, ['m365']);
  assert.doesNotThrow(() => validateAccessCatalog(canonical));
});

test('canonicalization does not hide duplicates created by case folding', () => {
  const catalog = makeCatalog({ planCount: 1, profileCount: 1 });
  catalog.profiles[0].capabilities = ['code', 'CODE'];
  assert.throws(() => canonicalizeAccessCatalog(catalog), /capabilities.*unique/i);
});

test('canonicalization does not discard unknown nested schema fields', () => {
  const catalog = makeCatalog({ planCount: 1, profileCount: 1 });
  catalog.plans[0].nominalCredit.rollover = true;
  assert.throws(() => canonicalizeAccessCatalog(catalog), /nominalCredit.*unknown.*rollover/i);
});

test('the canonical hash ignores object key order and semantically unordered array order', () => {
  const catalog = makeCatalog({ planCount: 3, profileCount: 5 });
  catalog.profiles[0].capabilities = ['design', 'code'];
  catalog.profiles[0].modelFamilies = ['opus', 'haiku'];
  const reordered = reverseObjectKeys(clone(catalog));
  reordered.plans.reverse();
  reordered.profiles.reverse();
  reordered.profiles.find((profile) => profile.id === 'profile-01').capabilities.reverse();
  reordered.profiles.find((profile) => profile.id === 'profile-01').modelFamilies.reverse();

  const hash = hashAccessCatalog(catalog);
  assert.match(hash, /^[0-9a-f]{64}$/);
  assert.equal(hashAccessCatalog(reordered), hash);
});

test('the canonical hash retains priority and whole-profile semantics', () => {
  const catalog = makeCatalog({ planCount: 1, profileCount: 2 });
  const changedPriority = clone(catalog);
  changedPriority.profiles[0].priority = 100;
  assert.notEqual(hashAccessCatalog(changedPriority), hashAccessCatalog(catalog));

  const changedCapability = clone(catalog);
  changedCapability.profiles[0].capabilities = ['chat'];
  assert.notEqual(hashAccessCatalog(changedCapability), hashAccessCatalog(catalog));
});

test('membership selection returns the one whole highest-priority enabled profile', () => {
  const catalog = makeCatalog({ planCount: 2, profileCount: 3 });
  catalog.profiles[0] = makeProfile(1, {
    planId: 'plan-01',
    priority: 10,
    capabilities: ['code'],
    modelFamilies: ['haiku'],
    connectors: [],
  });
  catalog.profiles[1] = makeProfile(2, {
    planId: 'plan-02',
    priority: 50,
    capabilities: ['design'],
    modelFamilies: ['opus'],
    connectors: ['m365'],
  });
  catalog.profiles[2] = makeProfile(3, {
    planId: 'plan-01',
    priority: 100,
    enabled: false,
    capabilities: ['chat'],
    modelFamilies: ['sonnet'],
  });

  const selected = selectProfileForMemberships(catalog, [
    catalog.profiles[0].groupObjectId,
    catalog.profiles[1].groupObjectId.toUpperCase(),
    catalog.profiles[2].groupObjectId,
  ]);

  assert.deepEqual(selected, canonicalizeAccessCatalog(catalog).profiles[1]);
  assert.deepEqual(selected.capabilities, ['design']);
  assert.deepEqual(selected.modelFamilies, ['opus']);
  assert.deepEqual(selected.connectors, ['m365']);
  assert.equal(selectProfileForMemberships(catalog, []), null);
});

test('membership selection rejects malformed membership ids and an ambiguous highest priority', () => {
  const catalog = makeCatalog({ planCount: 1, profileCount: 2 });
  assert.throws(() => selectProfileForMemberships(catalog, ['not-a-guid']), /membership.*guid/i);

  catalog.profiles[1].priority = catalog.profiles[0].priority;
  assert.throws(
    () => selectProfileForMemberships(catalog, catalog.profiles.map((profile) => profile.groupObjectId)),
    /ambiguous.*priority|priority.*unique/i,
  );
});

test('a published control document normalizes to its validated tenant catalog and verifies its hash', () => {
  const catalog = makeCatalog({ planCount: 2, profileCount: 3 });
  const document = prepareAccessCatalogDocument(catalog, {
    tenantId: TENANT,
    now: () => new Date('2026-10-14T12:00:00.000Z'),
  });
  assert.deepEqual(normalizeAccessCatalogDocument(document, { tenantId: TENANT }), canonicalizeAccessCatalog(catalog));

  const tampered = structuredClone(document);
  tampered.catalogVersion = `sha256:${'0'.repeat(64)}`;
  assert.throws(
    () => normalizeAccessCatalogDocument(tampered, { tenantId: TENANT }),
    /catalogVersion|hash/i,
  );
  assert.throws(
    () => normalizeAccessCatalogDocument(document, { tenantId: '00000000-0000-4000-8000-000000000000' }),
    /tenant/i,
  );
});
