/**
 * Business units as the gateway's named values hold them, read the way
 * scripts/ClaudeBusinessUnit.ps1 reads them. The renewal job reads them on every
 * run (ADR-0049), so a unit added by a script, AUM or Turnstile reaches the
 * projection without redeploying the job. The two parsers must agree:
 * tests/Test-ProjectionRenewalRuns.ps1 runs both on the same registries.
 *
 *   bu-registry   ,<id>=<group>:<tokens>,...   the group may contain a colon;
 *                                              the budget is the last field
 *   bu-parents    ,<team>=<unit>,...           a team names its unit
 *
 * Units are applied deepest first, then in registry order, and the first match
 * wins: the order Sync-ClaudeAccess.ps1 writes bu-members in.
 */

const GATEWAY_ID = /^\/subscriptions\/[0-9a-fA-F-]{36}\/resourceGroups\/[A-Za-z0-9._()-]{1,90}\/providers\/Microsoft\.ApiManagement\/service\/[A-Za-z0-9-]{1,50}$/;

function entries(value) {
  if (typeof value !== 'string' || !value.trim()) return [];
  return value.replace(/^,+|,+$/g, '').split(',').filter(Boolean);
}

export function parseBuRegistry(value) {
  const units = [];
  for (const entry of entries(value)) {
    const eq = entry.indexOf('=');
    if (eq < 1) continue;
    const rest = entry.slice(eq + 1);
    const colon = rest.lastIndexOf(':');
    if (colon < 0) continue;
    const tokens = rest.slice(colon + 1);
    if (!/^\d+$/.test(tokens)) continue;
    units.push({ id: entry.slice(0, eq), group: rest.slice(0, colon), tokensPerMonth: Number(tokens) });
  }
  return units;
}

export function parseBuParents(value) {
  const parents = new Map();
  for (const pair of entries(value)) {
    const eq = pair.indexOf('=');
    if (eq < 0) continue;
    const child = pair.slice(0, eq);
    const parent = pair.slice(eq + 1);
    if (child && parent) parents.set(child, parent);
  }
  return parents;
}

/** Hops above a unit; a cycle reports the largest depth instead of looping. */
export function resolveDepth(id, parents, limit = 10) {
  let depth = 0;
  let cursor = id;
  const seen = new Set([id]);
  while (parents.get(cursor) && depth < limit) {
    cursor = parents.get(cursor);
    depth++;
    if (seen.has(cursor)) return Number.MAX_SAFE_INTEGER;
    seen.add(cursor);
  }
  return depth;
}

/** Deepest first; units at one depth keep registry order (an explicit second key, not sort stability). */
export function sortUnitsByDepth(units, parents) {
  return units
    .map((unit, position) => ({ unit, position, depth: resolveDepth(unit.id, parents) }))
    .sort((a, b) => (b.depth - a.depth) || (a.position - b.position))
    .map((keyed) => keyed.unit);
}

/**
 * Reads bu-registry and bu-parents from the gateway through Azure Resource
 * Manager. A named value that does not exist is an empty list, as
 * Get-ApimNamedValue -FailOnError treats it; any other failure, including a
 * missing gateway, throws, because reading it as "no units" would move every
 * developer out of their unit.
 */
export async function readGatewayUnits(gatewayResourceId, token, fetchImpl = fetch) {
  if (!GATEWAY_ID.test(gatewayResourceId ?? '')) {
    throw new Error('the gateway id is not an API Management resource id');
  }
  const read = async (name) => {
    const url = `https://management.azure.com${gatewayResourceId}/namedValues/${name}?api-version=2024-05-01`;
    const res = await fetchImpl(url, { headers: { Authorization: `Bearer ${token}` } });
    if (res.status === 404) {
      const body = await res.json().catch(() => ({}));
      if (body?.error?.code === 'ResourceNotFound' && /NamedValue not found/i.test(body?.error?.message ?? '')) return null;
      throw new Error(`ARM 404 reading named value ${name}: ${body?.error?.code ?? 'not found'}`);
    }
    if (!res.ok) {
      const body = await res.text().catch(() => '');
      throw new Error(`ARM ${res.status} reading named value ${name}: ${body.slice(0, 200)}`);
    }
    const body = await res.json();
    if (body?.properties?.secret) throw new Error(`named value ${name} is secret; the job reads non-secret values only`);
    return body?.properties?.value ?? null;
  };
  return { registry: parseBuRegistry(await read('bu-registry')), parents: parseBuParents(await read('bu-parents')) };
}
