/**
 * Microsoft Graph membership, read the way scripts/ClaudeGraphMembership.ps1
 * reads it. Every rule here was measured there and is repeated because the two
 * must agree: Compare-ClaudeEntitlement.ps1 reads the named-value path through
 * the PowerShell module and the projection through this.
 *
 *   transitive membership, so nested groups work the way admins expect
 *   two casts - users and service principals - because a build agent or a
 *     scheduled job authenticates as a service principal and needs the same
 *     entitlement a developer does; the uncast call returns nested groups too
 *   ConsistencyLevel: eventual AND $count=true, without which Graph returns
 *     200 with no service principals rather than an error (measured 2026-09-16)
 *   @odata.nextLink followed, because a page is capped at 999
 *
 * fetch is injected so paging and throttling are tested without Graph.
 */

const GRAPH = 'https://graph.microsoft.com/v1.0';
const GUID = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

async function getJson(url, token, fetchImpl, { maxRetries = 6 } = {}) {
  for (let attempt = 0; ; attempt++) {
    const res = await fetchImpl(url, {
      headers: { Authorization: `Bearer ${token}`, ConsistencyLevel: 'eventual' },
    });
    // Graph throttles a full read of a large directory. Retry-After is the
    // server's own answer to "how long"; guessing shorter only earns another 429.
    if ((res.status === 429 || res.status === 503) && attempt < maxRetries) {
      const after = Number(res.headers?.get?.('retry-after')) || 2 ** attempt;
      await new Promise((r) => setTimeout(r, after * 1000));
      continue;
    }
    if (!res.ok) {
      const body = await res.text().catch(() => '');
      throw new Error(`Graph ${res.status} for ${url.split('?')[0]}: ${body.slice(0, 200)}`);
    }
    return res.json();
  }
}

/**
 * A group by display name or object id. Refuses an ambiguous name rather than
 * picking one: two groups with the same name and different members would make
 * entitlement depend on which one Graph listed first.
 */
export async function resolveGroupId(nameOrId, token, fetchImpl = fetch) {
  if (GUID.test(nameOrId)) return nameOrId;
  const esc = nameOrId.replace(/'/g, "''");
  const page = await getJson(`${GRAPH}/groups?$filter=displayName eq '${encodeURIComponent(esc)}'&$select=id,displayName`, token, fetchImpl);
  const hits = page.value ?? [];
  if (hits.length === 0) return null;
  if (hits.length > 1) throw new Error(`${hits.length} groups are named '${nameOrId}'; pass the object id instead`);
  return hits[0].id;
}

export async function getTransitiveMembers(groupId, token, fetchImpl = fetch) {
  const casts = [
    { type: 'microsoft.graph.user', select: 'id,displayName,userPrincipalName' },
    { type: 'microsoft.graph.servicePrincipal', select: 'id,displayName' },
  ];
  const members = [];
  for (const cast of casts) {
    let url = `${GRAPH}/groups/${groupId}/transitiveMembers/${cast.type}?$select=${cast.select}&$top=999&$count=true`;
    while (url) {
      const page = await getJson(url, token, fetchImpl);
      for (const m of page.value ?? []) {
        members.push({ oid: m.id, name: m.userPrincipalName ?? m.displayName ?? '' });
      }
      url = page['@odata.nextLink'] ?? null;
    }
  }
  return members;
}
