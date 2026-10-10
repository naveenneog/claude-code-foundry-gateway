import { readFileSync, writeFileSync } from 'node:fs';

let injected = false;

function loadStore() {
  return JSON.parse(readFileSync(process.env.FAKE_COSMOS_STORE, 'utf8'));
}

function saveStore(store) {
  writeFileSync(process.env.FAKE_COSMOS_STORE, JSON.stringify(store, null, 1));
}

function maybeInjectConcurrentStatus() {
  if (injected || !process.env.FAKE_GRAPH_CONCURRENT_STATUS_MODE) return;
  injected = true;
  const mode = process.env.FAKE_GRAPH_CONCURRENT_STATUS_MODE;
  const generation = mode === 'full'
    ? 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    : 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
  const tenant = process.env.FAKE_GRAPH_TENANT;
  const oid = `projection-status::${tenant}`;
  const status = {
    id: `${oid}::${generation}`,
    oid,
    type: 'projection-reconciliation-status',
    ttl: 604800,
    tenantId: tenant,
    accountResourceId: process.env.FAKE_GRAPH_ACCOUNT_RESOURCE_ID,
    databaseName: 'claude',
    containerName: 'entitlement',
    ok: true,
    mode,
    executor: 'runner',
    user: mode === 'user' ? process.env.FAKE_GRAPH_TARGET_USER : undefined,
    reconciliationGeneration: generation,
    lastVerifiedAt: new Date().toISOString(),
    startedAt: new Date().toISOString(),
    finishedAt: new Date().toISOString(),
  };
  const store = loadStore();
  store.docs[`${status.id}|${status.oid}`] = status;
  saveStore(store);
}

function response(status, body) {
  return {
    ok: status >= 200 && status < 300,
    status,
    headers: { get: () => null },
    json: async () => body,
    text: async () => JSON.stringify(body),
  };
}

globalThis.fetch = async (input) => {
  const url = new URL(String(input));
  if (url.host !== 'graph.microsoft.com') throw new Error(`fake graph refuses ${url.host}`);
  const members = /^\/v1\.0\/groups\/([^/]+)\/transitiveMembers\/microsoft\.graph\.(user|servicePrincipal)$/.exec(url.pathname);
  if (members) {
    const [, , cast] = members;
    if (cast === 'servicePrincipal') return response(200, { value: [] });
    maybeInjectConcurrentStatus();
    return response(200, {
      value: (process.env.FAKE_GRAPH_USERS ?? '')
        .split(',')
        .filter(Boolean)
        .map((id) => ({ id, userPrincipalName: `${id.slice(0, 8)}@example.invalid`, displayName: id })),
    });
  }
  if (url.pathname === '/v1.0/groups') {
    return response(200, { value: [{ id: process.env.FAKE_GRAPH_GROUP_ID, displayName: 'standard' }] });
  }
  return response(404, { error: { message: `no fake graph route for ${url.pathname}` } });
};
