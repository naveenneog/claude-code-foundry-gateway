/**
 * What a sync would change, as pure functions of what the directory says and
 * what the projection holds. No Azure here, so every rule is tested without an
 * account, a network or a token - the same split the resolver makes.
 *
 * The rules are the ones scripts/Sync-ClaudeProjection.ps1 applies, and they
 * have to stay identical: Compare-ClaudeEntitlement.ps1 compares the named-value
 * path with the projection, and a difference in code would read as drift.
 */

import { randomUUID } from 'node:crypto';

export const TIERS_BY_PRECEDENCE = ['premium', 'standard'];
export const MAX_PROJECTION_AGE_SECONDS = 7200;

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
  const orphans = [...existing.keys()].filter((oid) => !wanted.has(oid));
  return {
    refused: false,
    toWrite,
    toDelete: keepOrphans ? [] : orphans,
    keptOrphans: keepOrphans ? orphans : [],
    unchanged,
  };
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
