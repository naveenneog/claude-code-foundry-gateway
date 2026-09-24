/**
 * Entitlement resolver - the read side of ADR-0005.
 *
 * The gateway asks this for one identity at a time and caches the answer for
 * the revocation window, so it is called once per window per active developer
 * rather than once per request. That is why a point read is enough, and why
 * Measure-ClaudeProjectionCost.ps1 counts cache misses rather than requests.
 *
 * Kept separate from the Azure wiring so it can be tested without a Cosmos
 * account, a Function host or a network. Everything here is a pure function of
 * the document that came back.
 */

/**
 * The tiers the gateway policy implements. A record naming anything else is not
 * a licence to invent a tier - the policy has two branches, and a third would
 * be silently unenforced, so it is refused here where it is visible.
 */
export const KNOWN_TIERS = ['standard', 'premium'];

/**
 * Turn a stored document into the record the gateway caches.
 *
 * Returns { ok: true, record } or { ok: false, status, reason }. The caller
 * maps that onto HTTP; nothing here knows what a status code means beyond the
 * number, which is what keeps the decisions testable in isolation.
 */
export function toEntitlement(doc, { tenantId, now = new Date() } = {}) {
  if (!doc) {
    // Not an error. An identity with no record is simply not entitled, and the
    // gateway turns that into its own refusal. Answering 200 with an empty tier
    // would make an absent record indistinguishable from a resolver fault.
    return { ok: false, status: 404, reason: 'no record for this identity' };
  }

  // A record from another tenant must never be honoured. Object ids are unique
  // within a tenant and not across them, so without this check a lookup could
  // be satisfied by the wrong directory. projection.bicep stores tenantId on
  // every record precisely for this.
  if (!tenantId || doc.tenantId !== tenantId) {
    return { ok: false, status: 403, reason: 'record belongs to a different tenant' };
  }

  if (!KNOWN_TIERS.includes(doc.tier)) {
    return {
      ok: false,
      status: 409,
      reason: `record names tier '${doc.tier}', which the gateway policy does not implement`,
    };
  }

  const verified = Date.parse(doc.lastVerifiedAt);
  if (!isObjectId(doc.reconciliationGeneration) || !Number.isFinite(verified) ||
      verified > now.getTime() || !Number.isInteger(doc.expiresAt) ||
      doc.expiresAt > Math.floor(verified / 1000) + 7200) {
    return { ok: false, status: 503, reason: 'projection freshness is invalid; run a complete reconciliation' };
  }
  if (doc.expiresAt <= Math.floor(now.getTime() / 1000)) {
    return { ok: false, status: 503, reason: 'projection expired; its directory reconciliation must run again' };
  }

  // A record that has not taken effect is not yet entitlement. This is what
  // lets a population be staged ahead of a cutover without granting anybody
  // access early - ADR-0009 phase 1 writes the schema, not the authorisation.
  if (doc.effectiveFrom) {
    const from = new Date(doc.effectiveFrom);
    if (!Number.isNaN(from.getTime()) && from > now) {
      return { ok: false, status: 404, reason: 'record is not effective yet' };
    }
  }

  return {
    ok: true,
    record: {
      oid: doc.oid ?? doc.id,
      tier: doc.tier,
      // Empty rather than absent, so an unassigned developer reads the same
      // from either entitlement source and the policy's coalesce has something
      // to work with.
      businessUnit: doc.businessUnit ?? '',
      // Carried so a cached answer can be reasoned about afterwards: which
      // generation of the mapping produced it, and when it became true.
      mappingVersion: doc.mappingVersion ?? 0,
      effectiveFrom: doc.effectiveFrom ?? null,
      reconciliationGeneration: doc.reconciliationGeneration,
      expiresAt: doc.expiresAt,
    },
  };
}

/**
 * An object id is a guid. Checked before it reaches the data layer, because an
 * unchecked value becomes part of a resource path.
 */
export function isObjectId(value) {
  return typeof value === 'string' &&
    /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(value);
}
