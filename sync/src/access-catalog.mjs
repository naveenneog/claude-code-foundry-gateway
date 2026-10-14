import { createHash } from 'node:crypto';

const GUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const ID = /^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$/;
const CAPABILITIES = ['code', 'cowork', 'chat', 'design'];
const MODEL_FAMILIES = ['haiku', 'sonnet', 'opus', 'fable', 'mythos'];
const CONNECTORS = ['m365'];
const COMPATIBILITY_TIERS = ['standard', 'premium'];

const CATALOG_FIELDS = ['schemaVersion', 'tenantId', 'plans', 'profiles'];
const PLAN_FIELDS = ['id', 'name', 'enabled', 'nominalCredit', 'compatibilityTier'];
const CREDIT_FIELDS = ['amount', 'currency', 'period', 'scope'];
const PROFILE_FIELDS = [
  'id',
  'name',
  'planId',
  'groupObjectId',
  'priority',
  'capabilities',
  'modelFamilies',
  'connectors',
  'enabled',
];

export function validateAccessCatalog(catalog) {
  if (!isRecord(catalog)) throw new Error('access catalog must be one object');
  rejectUnknownFields(catalog, CATALOG_FIELDS, 'catalog');
  if (catalog.schemaVersion !== 1) throw new Error('catalog schemaVersion must be 1');
  requireGuid(catalog.tenantId, 'catalog tenantId');
  requireBoundedArray(catalog.plans, 1, 16, 'catalog plans');
  requireBoundedArray(catalog.profiles, 1, 64, 'catalog profiles');

  const planIds = new Set();
  for (const [index, plan] of catalog.plans.entries()) {
    validatePlan(plan, index);
    if (planIds.has(plan.id)) throw new Error(`plan id '${plan.id}' must be unique`);
    planIds.add(plan.id);
  }

  const profileIds = new Set();
  for (const [index, profile] of catalog.profiles.entries()) {
    validateProfile(profile, index);
    if (profileIds.has(profile.id)) throw new Error(`profile id '${profile.id}' must be unique`);
    profileIds.add(profile.id);
  }

  const enabledPlans = new Set(catalog.plans.filter((plan) => plan.enabled).map((plan) => plan.id));
  const enabledGroups = new Set();
  const enabledPriorities = new Set();
  for (const profile of catalog.profiles) {
    if (!profile.enabled) continue;
    if (!enabledPlans.has(profile.planId)) {
      throw new Error(`enabled profile '${profile.id}' must reference an existing enabled plan`);
    }
    if (enabledGroups.has(profile.groupObjectId)) {
      throw new Error(`enabled profile groupObjectId '${profile.groupObjectId}' must be unique`);
    }
    enabledGroups.add(profile.groupObjectId);
    if (enabledPriorities.has(profile.priority)) {
      throw new Error(`enabled profile priority '${profile.priority}' must be unique; duplicate priority is ambiguous`);
    }
    enabledPriorities.add(profile.priority);
  }
}

export function canonicalizeAccessCatalog(catalog) {
  if (!isRecord(catalog)) throw new Error('access catalog must be one object');
  rejectUnknownFields(catalog, CATALOG_FIELDS, 'catalog');
  const canonical = {
    schemaVersion: catalog.schemaVersion,
    tenantId: lowerString(catalog.tenantId),
    plans: canonicalizePlans(catalog.plans),
    profiles: canonicalizeProfiles(catalog.profiles),
  };
  validateAccessCatalog(canonical);
  return canonical;
}

export function hashAccessCatalog(catalog) {
  const canonical = canonicalizeAccessCatalog(catalog);
  return createHash('sha256').update(JSON.stringify(canonical)).digest('hex');
}

export function hashAccessProfile(profile) {
  if (!isRecord(profile)) throw new Error('access profile must be one object');
  const canonical = canonicalizeProfiles([profile])[0];
  validateProfile(canonical, 0);
  return createHash('sha256').update(JSON.stringify(canonical)).digest('hex');
}

export function selectProfileForMemberships(catalog, memberships) {
  return createProfileSelector(catalog).select(memberships);
}

export function createProfileSelector(catalog) {
  const canonical = canonicalizeAccessCatalog(catalog);
  return {
    catalog: canonical,
    select: (memberships) => selectCanonicalProfile(canonical, memberships),
  };
}

function selectCanonicalProfile(canonical, memberships) {
  if (!Array.isArray(memberships)) throw new Error('memberships must be an array of group object id GUIDs');
  const groups = new Set(memberships.map((membership, index) => {
    const normalized = lowerString(membership);
    requireGuid(normalized, `membership ${index}`);
    return normalized;
  }));

  const matches = canonical.profiles
    .filter((profile) => profile.enabled && groups.has(profile.groupObjectId))
    .sort((left, right) => right.priority - left.priority);
  if (matches.length === 0) return null;
  if (matches.length > 1 && matches[0].priority === matches[1].priority) {
    throw new Error(`ambiguous highest priority '${matches[0].priority}' across enabled profiles`);
  }
  return matches[0];
}

function validatePlan(plan, index) {
  if (!isRecord(plan)) throw new Error(`plan ${index} must be an object`);
  rejectUnknownFields(plan, PLAN_FIELDS, `plan ${index}`);
  requireCanonicalId(plan.id, `plan ${index} id`);
  requireName(plan.name, `plan '${plan.id}' name`);
  if (typeof plan.enabled !== 'boolean') throw new Error(`plan '${plan.id}' enabled must be boolean`);
  validateCredit(plan.nominalCredit, plan.id);
  if (!COMPATIBILITY_TIERS.includes(plan.compatibilityTier)) {
    throw new Error(`plan '${plan.id}' compatibilityTier must be standard or premium`);
  }
}

function validateCredit(credit, planId) {
  if (!isRecord(credit)) throw new Error(`plan '${planId}' nominalCredit must be an object`);
  rejectUnknownFields(credit, CREDIT_FIELDS, `plan '${planId}' nominalCredit`);
  if (!Number.isFinite(credit.amount) || credit.amount <= 0 || credit.amount > 1000000) {
    throw new Error(`plan '${planId}' nominalCredit amount must be positive, finite and at most 1000000`);
  }
  if (credit.currency !== 'USD') throw new Error(`plan '${planId}' nominalCredit currency must be USD`);
  if (credit.period !== 'month') throw new Error(`plan '${planId}' nominalCredit period must be month`);
  if (credit.scope !== 'user') throw new Error(`plan '${planId}' nominalCredit scope must be user`);
}

function validateProfile(profile, index) {
  if (!isRecord(profile)) throw new Error(`profile ${index} must be an object`);
  rejectUnknownFields(profile, PROFILE_FIELDS, `profile ${index}`);
  requireCanonicalId(profile.id, `profile ${index} id`);
  requireName(profile.name, `profile '${profile.id}' name`);
  requireCanonicalId(profile.planId, `profile '${profile.id}' planId`);
  requireGuid(profile.groupObjectId, `profile '${profile.id}' groupObjectId`);
  if (!Number.isSafeInteger(profile.priority)) {
    throw new Error(`profile '${profile.id}' priority must be an integer`);
  }
  validateDimension(profile.capabilities, CAPABILITIES, `profile '${profile.id}' capabilities`);
  validateDimension(profile.modelFamilies, MODEL_FAMILIES, `profile '${profile.id}' modelFamilies`);
  validateDimension(profile.connectors, CONNECTORS, `profile '${profile.id}' connectors`);
  if (typeof profile.enabled !== 'boolean') throw new Error(`profile '${profile.id}' enabled must be boolean`);
}

function canonicalizePlans(plans) {
  if (!Array.isArray(plans)) return plans;
  return plans.map((plan) => {
    if (!isRecord(plan)) return plan;
    rejectUnknownFields(plan, PLAN_FIELDS, 'plan');
    let credit = plan.nominalCredit;
    if (isRecord(plan.nominalCredit)) {
      rejectUnknownFields(plan.nominalCredit, CREDIT_FIELDS, `plan '${plan.id}' nominalCredit`);
      credit = {
          amount: plan.nominalCredit.amount,
          currency: upperString(plan.nominalCredit.currency),
          period: lowerString(plan.nominalCredit.period),
          scope: lowerString(plan.nominalCredit.scope),
        };
    }
    return {
      id: lowerString(plan.id),
      name: trimString(plan.name),
      enabled: plan.enabled,
      nominalCredit: credit,
      compatibilityTier: lowerString(plan.compatibilityTier),
    };
  }).sort((left, right) => compareText(left?.id, right?.id));
}

function canonicalizeProfiles(profiles) {
  if (!Array.isArray(profiles)) return profiles;
  return profiles.map((profile) => {
    if (!isRecord(profile)) return profile;
    rejectUnknownFields(profile, PROFILE_FIELDS, 'profile');
    return {
      id: lowerString(profile.id),
      name: trimString(profile.name),
      planId: lowerString(profile.planId),
      groupObjectId: lowerString(profile.groupObjectId),
      priority: profile.priority,
      capabilities: canonicalizeDimension(profile.capabilities),
      modelFamilies: canonicalizeDimension(profile.modelFamilies),
      connectors: canonicalizeDimension(profile.connectors),
      enabled: profile.enabled,
    };
  }).sort((left, right) => compareText(left?.id, right?.id));
}

function validateDimension(values, allowed, label) {
  if (!Array.isArray(values)) throw new Error(`${label} must be an array`);
  const seen = new Set();
  for (const value of values) {
    if (typeof value !== 'string' || !allowed.includes(value)) {
      throw new Error(`${label} values must be one of ${allowed.join(', ')}`);
    }
    if (seen.has(value)) throw new Error(`${label} values must be unique`);
    seen.add(value);
  }
}

function canonicalizeDimension(values) {
  if (!Array.isArray(values)) return values;
  return values.map(lowerString).sort(compareText);
}

function requireCanonicalId(value, label) {
  if (typeof value !== 'string' || !ID.test(value)) {
    throw new Error(`${label} must be a canonical lowercase id`);
  }
}

function requireGuid(value, label) {
  if (typeof value !== 'string' || !GUID.test(value)) throw new Error(`${label} must be a GUID`);
}

function requireName(value, label) {
  if (typeof value !== 'string' || !value.trim()) throw new Error(`${label} must be a non-empty string`);
  if (value !== value.trim()) throw new Error(`${label} must not have surrounding whitespace`);
}

function requireBoundedArray(value, minimum, maximum, label) {
  if (!Array.isArray(value) || value.length < minimum || value.length > maximum) {
    throw new Error(`${label} must contain ${minimum}-${maximum} entries`);
  }
}

function rejectUnknownFields(value, allowed, label) {
  for (const key of Object.keys(value)) {
    if (!allowed.includes(key)) throw new Error(`${label} has unknown field '${key}'`);
  }
}

function isRecord(value) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function lowerString(value) {
  return typeof value === 'string' ? value.trim().toLowerCase() : value;
}

function upperString(value) {
  return typeof value === 'string' ? value.trim().toUpperCase() : value;
}

function trimString(value) {
  return typeof value === 'string' ? value.trim() : value;
}

function compareText(left, right) {
  const a = String(left ?? '');
  const b = String(right ?? '');
  return a < b ? -1 : a > b ? 1 : 0;
}
