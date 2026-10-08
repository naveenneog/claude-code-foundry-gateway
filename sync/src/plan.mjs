/**
 * What a sync would change, as pure functions of what the directory says and
 * what the projection holds. No Azure here, so every rule is tested without an
 * account, a network or a token - the same split the resolver makes.
 *
 * The rules are the ones scripts/Sync-ClaudeProjection.ps1 applies, and they
 * have to stay identical: Compare-ClaudeEntitlement.ps1 compares the named-value
 * path with the projection, and a difference in code would read as drift.
 */

import { createHash, randomUUID } from 'node:crypto';
import { toEntitlement } from '../../resolver/src/entitlement.mjs';

export const TIERS_BY_PRECEDENCE = ['premium', 'standard'];
export const MAX_PROJECTION_AGE_SECONDS = 7200;
export const STATUS_RECORD_TYPE = 'projection-reconciliation-status';
export const STATUS_PARTITION_PREFIX = 'projection-status::';
export const STATUS_TTL_SECONDS = 604800;
export const APPLY_LOCK_RECORD_TYPE = 'projection-apply-lock';
export const APPLY_LOCK_ID = 'projection-apply-lock';

export function createReconciliation({ verifiedAt, now = new Date(), maxAgeSeconds = MAX_PROJECTION_AGE_SECONDS } = {}) {
  const start = new Date(verifiedAt).getTime();
  if (!Number.isFinite(start) || start > now.getTime() ||
      !Number.isInteger(maxAgeSeconds) || maxAgeSeconds < 60 || maxAgeSeconds > MAX_PROJECTION_AGE_SECONDS) {
    throw new Error('invalid reconciliation freshness');
  }
  const expiresAt = Math.floor(start / 1000) + maxAgeSeconds;
  if (expiresAt <= Math.floor(now.getTime() / 1000)) throw new Error('reconciliation expired before publication');
  return { reconciliationGeneration: randomUUID(), lastVerifiedAt: new Date(start).toISOString(), expiresAt };
}

/**
 * Merge tier and business-unit membership into one record per identity.
 *
 *   tiers          { premium: [{oid,name}], standard: [{oid,name}] }
 *   businessUnits  [{ id, members: [{oid,name}] }] in registry order
 *
 * Premium is read first and wins, matching the policy, which checks the
 * premium list before the standard one. A business unit is recorded only for
 * an identity that holds a tier - being in a unit is not entitlement. Units
 * arrive in precedence order - deepest first, then registry order, as
 * Sort-ClaudeBuByDepth produces them - and the first match wins, which is how
 * Sync-ClaudeAccess.ps1 writes bu-members for the named-value path.
 */
export function mergeMembership({ tiers = {}, businessUnits = [] } = {}) {
  const byOid = new Map();
  for (const tier of TIERS_BY_PRECEDENCE) {
    for (const m of tiers[tier] ?? []) {
      if (!byOid.has(m.oid)) {
        byOid.set(m.oid, { oid: m.oid, name: m.name ?? '', tier, businessUnit: '' });
      }
    }
  }
  const unitWithoutTier = [];
  const assigned = new Set();
  for (const unit of businessUnits) {
    for (const m of unit.members ?? []) {
      const rec = byOid.get(m.oid);
      if (!rec) { unitWithoutTier.push({ oid: m.oid, unit: unit.id }); continue; }
      if (!assigned.has(m.oid)) { rec.businessUnit = unit.id; assigned.add(m.oid); }
    }
  }
  return { records: [...byOid.values()], unitWithoutTier };
}

/**
 * Decide what to write and what to remove.
 *
 *   resolved  records from mergeMembership, or from a snapshot
 *   existing  Map oid -> { tier, businessUnit } read from the container
 *
 * Refuses, rather than returning a plan, when the directory resolved nobody
 * while the projection holds records: a directory that cannot be read looks
 * exactly like a directory with nobody in it, and acting on it would revoke
 * everyone. allowEmpty overrides that for an emptiness that is real.
 */
export function planChanges(resolved, existing, { allowEmpty = false, keepOrphans = false, refresh = false } = {}) {
  if (resolved.length === 0 && existing.size > 0 && !allowEmpty) {
    return {
      refused: true,
      reason: `groups resolved to nobody while the projection holds ${existing.size} record(s); refusing to remove them all`,
    };
  }
  const wanted = new Set();
  const toWrite = [];
  let unchanged = 0;
  for (const r of resolved) {
    wanted.add(r.oid);
    const cur = existing.get(r.oid);
    if (cur && cur.tier === r.tier && (cur.businessUnit ?? '') === (r.businessUnit ?? '')) {
      if (Object.hasOwn(cur, 'expiresAt')) {
        toWrite.push(r);
        continue;
      }
      unchanged++;
      if (!refresh) continue;
    }
    toWrite.push(r);
  }
  const orphans = [...existing.entries()]
    .filter(([oid, doc]) => !wanted.has(oid) && !isControlRecord({ id: oid, oid, ...doc }))
    .map(([oid]) => oid);
  return {
    refused: false,
    toWrite,
    toDelete: keepOrphans ? [] : orphans,
    keptOrphans: keepOrphans ? orphans : [],
    unchanged,
  };
}

export function removalLimit(existing) {
  return Math.max(10, Math.floor(existing / 10));
}

export function removalLimitExceeded({ deletes, existing }) {
  const limit = removalLimit(existing);
  return { exceeded: deletes > limit, limit };
}

/**
 * The stored document. Same shape the PowerShell sync writes and the resolver
 * reads: id and partition key are both the object id, so a lookup is a point
 * read.
 */
export function toDocument(r, { tenantId, mappingVersion, reconciliation }) {
  return {
    id: r.oid,
    oid: r.oid,
    tenantId,
    tier: r.tier,
    businessUnit: r.businessUnit ?? '',
    mappingVersion,
    effectiveFrom: null,
    reconciliationGeneration: reconciliation?.reconciliationGeneration,
    lastVerifiedAt: reconciliation?.lastVerifiedAt,
  };
}

export function statusPartitionKey(tenantId) {
  if (!GUID.test(tenantId ?? '')) throw new Error('tenantId is not a guid');
  return `${STATUS_PARTITION_PREFIX}${tenantId}`;
}

export function isStatusPartitionKey(value) {
  return typeof value === 'string' && value.startsWith(STATUS_PARTITION_PREFIX) && !GUID.test(value);
}

export function isStatusRecord(doc) {
  return Boolean(doc) && (
    doc.type === STATUS_RECORD_TYPE ||
    isStatusPartitionKey(doc.oid) ||
    (typeof doc.id === 'string' && doc.id.startsWith(STATUS_PARTITION_PREFIX))
  );
}

export function isControlRecord(doc) {
  return Boolean(doc) && (isStatusRecord(doc) || doc.type === APPLY_LOCK_RECORD_TYPE);
}

export function toStatusDocument({
  tenantId,
  accountResourceId,
  databaseName,
  containerName,
  runId,
  imageDigest,
  entrypoint,
  command = [],
  dryRun = false,
  commandOverride = false,
  memberCounts = {},
  writeCounts = {},
  reconciliation,
  startedAt,
  finishedAt,
  mode = 'full',
  executor = 'runner',
  ok = true,
  settings = null,
  user = null,
}) {
  if (!reconciliation || !GUID.test(reconciliation.reconciliationGeneration ?? '')) {
    throw new Error('status requires a reconciliation generation');
  }
  const oid = statusPartitionKey(tenantId);
  return {
    id: `${oid}::${reconciliation.reconciliationGeneration}`,
    oid,
    type: STATUS_RECORD_TYPE,
    ttl: STATUS_TTL_SECONDS,
    tenantId,
    accountResourceId,
    databaseName,
    containerName,
    runId,
    imageDigest,
    entrypoint,
    command,
    dryRun: Boolean(dryRun),
    commandOverride: Boolean(commandOverride),
    ok: Boolean(ok),
    mode,
    executor,
    ...(user ? { user } : {}),
    memberCounts,
    writeCounts,
    startedAt,
    finishedAt,
    reconciliationGeneration: reconciliation.reconciliationGeneration,
    lastVerifiedAt: reconciliation.lastVerifiedAt,
    settings: settings ? normalizeJobSettings(settings) : null,
  };
}

const SETTING_KEYS = ['clientId', 'standardGroupId', 'premiumGroupId', 'gatewayResourceId'];

/**
 * The job settings a status record carries and switch evidence binds: the identity's client id,
 * the tier group object ids (premium may be 'none') and the gateway id.
 * Azure ids compare without case. Null when any is missing.
 */
export function normalizeJobSettings(settings = {}) {
  const values = SETTING_KEYS.map((key) => settings?.[key]);
  if (values.some((value) => typeof value !== 'string' || !value.trim())) return null;
  return Object.fromEntries(SETTING_KEYS.map((key, i) => [key, values[i].trim().toLowerCase()]));
}

export function validateJobSettings(env = {}) {
  const remedy = 'Remedy: redeploy the job with scripts/Deploy-ClaudeProjectionRenewal.ps1 -ResourceGroup <rg> -ApimName <apim> -NamePrefix <prefix> -AlertEmail <address>.';
  const problems = [];
  const objectId = (value) => GUID.test(value ?? '');
  const apimId = (value) => typeof value === 'string' &&
    /^\/subscriptions\/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\/resourceGroups\/[^/]+\/providers\/Microsoft\.ApiManagement\/service\/[^/]+$/i.test(value);
  const clientId = env.AZURE_CLIENT_ID;
  const standard = env.PROJECTION_STANDARD_GROUP_ID;
  const premium = env.PROJECTION_PREMIUM_GROUP_ID;
  const gateway = env.PROJECTION_GATEWAY_RESOURCE_ID;
  const accountResourceId = env.PROJECTION_ACCOUNT_RESOURCE_ID;
  if (!objectId(clientId)) problems.push(`AZURE_CLIENT_ID must be the job identity client id GUID. ${remedy}`);
  if (!objectId(standard)) problems.push(`PROJECTION_STANDARD_GROUP_ID must be the standard tier group object id GUID, not a group name. ${remedy}`);
  if (typeof premium !== 'string' || !premium.trim()) {
    problems.push(`PROJECTION_PREMIUM_GROUP_ID must be the premium tier group object id GUID, or none. ${remedy}`);
  } else if (premium !== 'none' && !objectId(premium)) {
    problems.push(`PROJECTION_PREMIUM_GROUP_ID must be the premium tier group object id GUID, or none. ${remedy}`);
  } else if (objectId(standard) && premium.toLowerCase() === standard.toLowerCase()) {
    problems.push(`PROJECTION_PREMIUM_GROUP_ID must not equal PROJECTION_STANDARD_GROUP_ID; one group for both tiers would make premium take every standard member. ${remedy}`);
  }
  if (!apimId(gateway)) problems.push(`PROJECTION_GATEWAY_RESOURCE_ID must be a Microsoft.ApiManagement/service resource id. ${remedy}`);
  if (!cosmosAccountId(accountResourceId)) problems.push(`PROJECTION_ACCOUNT_RESOURCE_ID must be a Microsoft.DocumentDB/databaseAccounts resource id. ${remedy}`);
  return problems;
}

const GUID = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
const cosmosAccountId = (value) => typeof value === 'string' &&
  /^\/subscriptions\/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\/resourceGroups\/[^/]+\/providers\/Microsoft\.DocumentDB\/databaseAccounts\/[^/]+$/i.test(value);

/**
 * What each identity would experience at the flip: the tier the gateway
 * enforces today from its named values, against the record the resolver would
 * serve. This is the comparison the migration's step 4 needs. The directory
 * comparison (Compare-ClaudeEntitlement.ps1 on its own) says whether the lists
 * are current; only this says whether the projection agrees with them.
 *
 *   gateway   { premium: [oid], standard: [oid], businessUnits: { oid: unit } }
 *   records   [{ oid, tier, businessUnit, tenantId }] as stored
 *
 * A record stamped with another tenant is served as a refusal by the resolver,
 * so it counts as no record here.
 */
export function compareWithGateway(gateway, records, { tenantId, now = new Date() } = {}) {
  const premium = new Set(gateway.premium ?? []);
  const standard = new Set(gateway.standard ?? []);
  const units = gateway.businessUnits ?? {};
  const gwTier = (oid) => (premium.has(oid) ? 'premium' : standard.has(oid) ? 'standard' : 'denied');
  const byOid = new Map();
  for (const r of records) {
    if (isControlRecord(r)) continue;
    if (!toEntitlement(r, { tenantId, now }).ok) continue;
    byOid.set(r.oid ?? r.id, r);
  }
  const all = new Set([...premium, ...standard, ...byOid.keys()]);
  const differences = [];
  for (const oid of all) {
    const now = gwTier(oid);
    const rec = byOid.get(oid);
    const next = rec && TIERS_BY_PRECEDENCE.includes(rec.tier) ? rec.tier : 'denied';
    if (now !== next) {
      const kind = next === 'denied' ? 'would-lose-access' : now === 'denied' ? 'would-gain-access' : 'tier-drift';
      differences.push({ oid, kind, gateway: now, projection: next });
      continue;
    }

    if (now !== 'denied') {
      const gu = units[oid] ?? '';
      const pu = rec?.businessUnit ?? '';
      if (gu !== pu) differences.push({ oid, kind: 'unit-drift', gateway: gu || '(unassigned)', projection: pu || '(unassigned)' });
    }
  }
  return { compared: all.size, differences };
}

export function compareWithSnapshot(snapshot, records, { tenantId, now = new Date() } = {}) {
  const problems = validateSnapshot(snapshot, { tenantId, now });
  if (snapshot?.scope && snapshot.scope !== 'full') problems.push("--compare-snapshot expects a full snapshot");
  if (problems.length) return { refused: true, problems };
  const expected = new Map((snapshot.records ?? []).map((r) => [r.oid, { tier: r.tier, businessUnit: r.businessUnit ?? '' }]));
  const live = new Map();
  for (const r of records ?? []) {
    if (isControlRecord(r)) continue;
    if (!toEntitlement(r, { tenantId, now }).ok) continue;
    live.set(r.oid ?? r.id, { tier: r.tier, businessUnit: r.businessUnit ?? '' });
  }
  const all = new Set([...expected.keys(), ...live.keys()]);
  const differences = [];
  for (const oid of all) {
    const want = expected.get(oid);
    const got = live.get(oid);
    if (!want && got) differences.push({ oid, kind: 'would-delete-record', snapshot: 'absent', projection: got.tier });
    else if (want && !got) differences.push({ oid, kind: 'missing-record', snapshot: want.tier, projection: 'absent' });
    else if (want.tier !== got.tier) differences.push({ oid, kind: 'tier-drift', snapshot: want.tier, projection: got.tier });
    else if ((want.businessUnit ?? '') !== (got.businessUnit ?? '')) {
      differences.push({ oid, kind: 'unit-drift', snapshot: want.businessUnit || '(unassigned)', projection: got.businessUnit || '(unassigned)' });
    }
  }
  return { refused: false, compared: all.size, differences };
}

export function validateTargetedSnapshot(snap, userOid, { tenantId, now = new Date() } = {}) {
  const problems = validateSnapshot(snap, { tenantId, now });
  if (!GUID.test(userOid ?? '')) problems.push('--user is not a guid');
  if (snap?.scope !== 'user') problems.push("targeted apply requires snapshot scope 'user'");
  if (snap?.user !== userOid) problems.push('snapshot user does not match --user');
  if ((snap?.records?.length ?? 0) > 1) problems.push('targeted snapshot carries more than one record');
  for (const r of snap?.records ?? []) {
    if (r.oid !== userOid) { problems.push('targeted snapshot contains a record for another user'); break; }
  }
  return problems;
}

export function evaluateProjectionAdmission({
  statuses = [],
  entitlementRecords,
  entitlementEvidence,
  expected = {},
  now = new Date(),
  maxEvidenceAgeSeconds = 86400,
} = {}) {
  const cutoff = now.getTime() - maxEvidenceAgeSeconds * 1000;
  const valid = statuses
    .filter(isStatusRecord)
    .filter((s) => s.tenantId === expected.tenantId &&
      lower(s.accountResourceId) === lower(expected.accountResourceId) &&
      s.databaseName === expected.databaseName &&
      s.containerName === expected.containerName)
    .filter((s) => s.mode === 'full' && s.ok === true)
    .filter((s) => Date.parse(s.finishedAt) >= cutoff)
    .sort((a, b) => Date.parse(a.finishedAt) - Date.parse(b.finishedAt));
  if (!valid.length) {
    return switchEvidence(false, null, 0, 'no successful full sync evidence for this tenant and container within the allowed age');
  }
  const newest = valid.at(-1);
  const evidence = entitlementEvidence ?? summarizeEntitlementEvidence(entitlementRecords, {
    tenantId: expected.tenantId,
    now,
  });
  if (!evidence) return switchEvidence(false, newestFullSync(newest), 0, 'admission must read live entitlement records, not only status history');
  if (evidence.invalidCount > 0) {
    const samples = (evidence.invalidSamples ?? []).map((s) => s.oidHash).filter(Boolean).join(', ');
    return switchEvidence(false, newestFullSync(newest), evidence.invalidCount, `${evidence.invalidCount} live entitlement record(s) would be refused by the resolver${samples ? `; oid-sha256 samples: ${samples}` : ''}`);
  }
  return switchEvidence(true, newestFullSync(newest), 0);
}

export function summarizeEntitlementEvidence(records, { tenantId, now = new Date() } = {}) {
  if (!Array.isArray(records)) return null;
  const live = records.filter((r) => !isControlRecord(r));
  const invalid = [];
  for (const record of live) {
    const verdict = toEntitlement(record, { tenantId, now });
    if (!verdict.ok) {
      invalid.push({ oid: record.oid ?? record.id ?? '', status: verdict.status, reason: verdict.reason });
    }
  }
  return {
    total: live.length,
    invalidCount: invalid.length,
    invalidSamples: invalid.slice(0, 3).map((r) => ({ oidHash: digest(r.oid), status: r.status })),
  };
}

function newestFullSync(status) {
  if (!status) return null;
  return {
    finishedAt: status.finishedAt,
    executor: status.executor ?? null,
    generation: status.reconciliationGeneration ?? null,
  };
}

function switchEvidence(ok, newestFullSync, invalidCount, reason) {
  return { ok, mode: 'switch-evidence', newestFullSync, invalidCount, ...(reason ? { reason } : {}) };
}

function digest(value) {
  return createHash('sha256').update(String(value)).digest('hex').slice(0, 12);
}

function lower(value) {
  return typeof value === 'string' ? value.toLowerCase() : value;
}

/**
 * A snapshot resolved outside the network and applied inside it. Checked before
 * anything is written: a snapshot for another tenant would be written and then
 * never honoured by the resolver, and a malformed record would become a
 * document the resolver refuses at request time instead of here.
 */
export function validateSnapshot(snap, { tenantId, now = new Date() } = {}) {
  const problems = [];
  if (!snap || typeof snap !== 'object') return ['snapshot is not an object'];
  if (snap.kind !== 'claude-entitlement-snapshot') problems.push("kind is not 'claude-entitlement-snapshot'");
  if (!GUID.test(snap.tenantId ?? '')) problems.push('tenantId is not a guid');
  if (tenantId && snap.tenantId !== tenantId) problems.push(`snapshot is for tenant ${snap.tenantId}, not ${tenantId}`);
  problems.push(...freshnessProblems(snap, now));
  if (!Array.isArray(snap.records)) problems.push('records is not an array');
  for (const r of snap.records ?? []) {
    if (!GUID.test(r.oid ?? '')) { problems.push(`record oid '${r.oid}' is not a guid`); break; }
    if (!TIERS_BY_PRECEDENCE.includes(r.tier)) { problems.push(`record ${r.oid} names tier '${r.tier}'`); break; }
  }
  const seen = new Set();
  for (const r of snap.records ?? []) {
    if (seen.has(r.oid)) { problems.push(`record ${r.oid} appears twice`); break; }
    seen.add(r.oid);
  }
  return problems;
}

function freshnessProblems(snap, now) {
  const problems = [];
  const verified = Date.parse(snap.lastVerifiedAt);
  if (!GUID.test(snap.reconciliationGeneration ?? '') || !Number.isFinite(verified) ||
      verified > now.getTime() || !Number.isInteger(snap.expiresAt) ||
      snap.expiresAt > Math.floor(verified / 1000) + MAX_PROJECTION_AGE_SECONDS) problems.push('invalid snapshot freshness');
  if (!Number.isInteger(snap.expiresAt) || snap.expiresAt <= Math.floor(now.getTime() / 1000)) problems.push('snapshot expired; resolve the directory again');
  return problems;
}
