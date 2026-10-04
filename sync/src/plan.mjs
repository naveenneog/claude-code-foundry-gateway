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
export const STATUS_TTL_SECONDS = 21600;

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
      unchanged++;
      if (!refresh) continue;
    }
    toWrite.push(r);
  }
  const orphans = [...existing.entries()]
    .filter(([oid, doc]) => !wanted.has(oid) && !isStatusRecord({ id: oid, oid, ...doc }))
    .map(([oid]) => oid);
  return {
    refused: false,
    toWrite,
    toDelete: keepOrphans ? [] : orphans,
    keptOrphans: keepOrphans ? orphans : [],
    unchanged,
  };
}

/**
 * The earliest expiry among the records a run leaves behind: every record it wrote, which expire
 * with this run's lease, and every orphan it kept. With neither, the run's own lease.
 */
export function oldestRetainedExpiry({ toWrite = [], keptOrphans = [] } = {}, existing = new Map(), expiresAt) {
  // A loop, not Math.min(...list): spreading one argument per record overflows the stack near
  // 125,000 records, and a run writes every entitled identity.
  let oldest = toWrite.length ? expiresAt : Infinity;
  for (const oid of keptOrphans) {
    const kept = existing.get(oid)?.expiresAt;
    if (Number.isFinite(kept) && kept < oldest) oldest = kept;
  }
  return Number.isFinite(oldest) ? oldest : expiresAt;
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
    ...reconciliation,
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
  oldestExpiresAt,
  reconciliation,
  startedAt,
  finishedAt,
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
    memberCounts,
    writeCounts,
    oldestExpiresAt,
    startedAt,
    finishedAt,
    reconciliationGeneration: reconciliation.reconciliationGeneration,
    lastVerifiedAt: reconciliation.lastVerifiedAt,
    expiresAt: reconciliation.expiresAt,
  };
}

const GUID = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

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
    if (isStatusRecord(r)) continue;
    if (!tenantId || r.tenantId !== tenantId || freshnessProblems(r, now).length) continue;
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

export function evaluateProjectionAdmission({
  statuses = [],
  entitlementRecords,
  entitlementEvidence,
  expected = {},
  job = {},
  now = new Date(),
  minExpiryMarginSeconds = 3600,
  maxNewestAgeSeconds = 2700,
  historyWindowSeconds = 7200,
} = {}) {
  if (!expected.actionGroupResourceId && expected.actionGroupResourceId !== undefined) {
    return refuse('missing action group; deploy alerts with email receivers before switching');
  }
  const image = job.image ?? '';
  if (expected.imageDigest && image !== expected.imageDigest) {
    return refuse('job image is not the tested pinned digest');
  }
  if ((job.command?.length ?? 0) || (job.args?.length ?? 0)) {
    const text = [...(job.command ?? []), ...(job.args ?? [])].join(' ');
    return refuse(/--whatif|--dry-run|whatif/i.test(text)
      ? 'job definition contains a dry-run override'
      : 'job definition contains a command or args override');
  }
  const expectedEntry = expected.entrypoint ?? '';
  const cutoff = now.getTime() - historyWindowSeconds * 1000;
  const valid = statuses
    .filter(isStatusRecord)
    .filter((s) => s.tenantId === expected.tenantId &&
      s.accountResourceId === expected.accountResourceId &&
      s.databaseName === expected.databaseName &&
      s.containerName === expected.containerName)
    .filter((s) => !s.dryRun && !s.commandOverride)
    .filter((s) => !expected.imageDigest || s.imageDigest === expected.imageDigest)
    .filter((s) => !expectedEntry || s.entrypoint === expectedEntry)
    .filter((s) => Date.parse(s.finishedAt) >= cutoff)
    .sort((a, b) => Date.parse(a.finishedAt) - Date.parse(b.finishedAt));
  if (!valid.length) return refuse('no destination-bound Cosmos renewal evidence for this tenant and container');
  const newest = valid.at(-1);
  const newestAge = (now.getTime() - Date.parse(newest.finishedAt)) / 1000;
  if (!Number.isFinite(newestAge) || newestAge > maxNewestAgeSeconds) {
    return refuse('newest successful renewal is older than 45 minutes');
  }
  const evidence = entitlementEvidence ?? summarizeEntitlementEvidence(entitlementRecords, {
    tenantId: expected.tenantId,
    latestGeneration: newest.reconciliationGeneration,
    now,
  });
  if (!evidence) return refuse('admission must read live entitlement records, not only status history');
  if (evidence.invalidCount > 0) {
    const samples = (evidence.invalidSamples ?? []).map((s) => s.oidHash).filter(Boolean).join(', ');
    return refuse(`${evidence.invalidCount} live entitlement record(s) would be refused by the resolver${samples ? `; oid-sha256 samples: ${samples}` : ''}`);
  }
  if (evidence.olderActiveCount > 0) {
    return refuse(`${evidence.olderActiveCount} live entitlement record(s) still carry an older generation`);
  }
  if (evidence.latestGeneration !== newest.reconciliationGeneration) {
    return refuse('status generation does not match the live entitlement records');
  }
  const statusOldest = Number(newest.oldestExpiresAt);
  if (Number.isFinite(statusOldest) && Number.isFinite(evidence.oldestExpiresAt) && statusOldest !== evidence.oldestExpiresAt) {
    return refuse('status oldest expiry mismatch with live entitlement records');
  }
  const statusCounts = normalizeCounts(newest.memberCounts ?? {});
  const liveCounts = normalizeCounts(evidence.memberCounts ?? {});
  if (JSON.stringify(statusCounts) !== JSON.stringify(liveCounts)) {
    return refuse('status member count mismatch with live entitlement records');
  }
  if (Number.isFinite(evidence.total) && evidence.total !== Object.values(liveCounts).reduce((a, b) => a + b, 0)) {
    return refuse('live entitlement total does not match member counts');
  }
  const oldestExpiry = Number(evidence.oldestExpiresAt);
  if (!Number.isFinite(oldestExpiry) || oldestExpiry - Math.floor(now.getTime() / 1000) < minExpiryMarginSeconds) {
    return refuse('oldest entitlement expiry has less than 60 minutes of margin');
  }
  const generations = [...new Set(valid.map((s) => s.reconciliationGeneration).filter(Boolean))];
  if (generations.length < 3) {
    return refuse('reconciliation generation has not advanced at least twice within two hours; wait about 60-90 minutes on the 30-minute schedule');
  }
  return { ok: true, newestFinishedAt: newest.finishedAt, oldestExpiresAt: oldestExpiry, generations: generations.length };
}

export function summarizeEntitlementEvidence(records, { tenantId, latestGeneration, now = new Date() } = {}) {
  if (!Array.isArray(records)) return null;
  const nowSeconds = Math.floor(now.getTime() / 1000);
  const live = records.filter((r) => !isStatusRecord(r) &&
    (Number.isInteger(r.expiresAt) ? r.expiresAt > nowSeconds : r.expiresAt !== undefined));
  const memberCounts = {};
  let olderActiveCount = 0;
  let oldestExpiresAt = Infinity;
  const invalid = [];
  for (const record of live) {
    const verdict = toEntitlement(record, { tenantId, now });
    if (!verdict.ok) {
      invalid.push({ oid: record.oid ?? record.id ?? '', status: verdict.status, reason: verdict.reason });
      continue;
    }
    memberCounts[record.tier] = (memberCounts[record.tier] ?? 0) + 1;
    if (record.reconciliationGeneration !== latestGeneration) olderActiveCount++;
    if (record.expiresAt < oldestExpiresAt) oldestExpiresAt = record.expiresAt;
  }
  return {
    total: live.length,
    oldestExpiresAt: Number.isFinite(oldestExpiresAt) ? oldestExpiresAt : null,
    latestGeneration,
    olderActiveCount,
    invalidCount: invalid.length,
    invalidSamples: invalid.slice(0, 3).map((r) => ({ oidHash: digest(r.oid), status: r.status })),
    memberCounts: normalizeCounts(memberCounts),
  };
}

function digest(value) {
  return createHash('sha256').update(String(value)).digest('hex').slice(0, 12);
}

function normalizeCounts(counts) {
  return Object.fromEntries(Object.entries(counts)
    .filter(([, value]) => Number(value) > 0)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([key, value]) => [key, Number(value)]));
}

function refuse(reason) {
  return { ok: false, reason, remedy: reason };
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
