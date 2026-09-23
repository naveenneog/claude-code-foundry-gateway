import { test } from 'node:test';
import assert from 'node:assert/strict';
import { resolveGroupId, getTransitiveMembers } from '../src/graph.mjs';

function fakeGraph(routes) {
  const calls = [];
  const impl = async (url, init) => {
    calls.push({ url, headers: init?.headers ?? {} });
    const route = routes.find((r) => r.match(url, calls.length));
    if (!route) return { ok: false, status: 404, text: async () => 'no route', headers: { get: () => null } };
    const { status = 200, body = {}, retryAfter = null } = route.reply(url, calls.length);
    return {
      ok: status >= 200 && status < 300, status,
      json: async () => body, text: async () => JSON.stringify(body),
      headers: { get: (h) => (h.toLowerCase() === 'retry-after' ? retryAfter : null) },
    };
  };
  return { impl, calls };
}

test('both casts are read, with the header and $count that service principals need', async () => {
  const g = fakeGraph([
    { match: (u) => u.includes('microsoft.graph.user'), reply: () => ({ body: { value: [{ id: 'u1', userPrincipalName: 'a@x' }] } }) },
    { match: (u) => u.includes('microsoft.graph.servicePrincipal'), reply: () => ({ body: { value: [{ id: 's1', displayName: 'agent' }] } }) },
  ]);
  const members = await getTransitiveMembers('gid', 'tok', g.impl);
  assert.deepEqual(members.map((m) => m.oid), ['u1', 's1']);
  for (const c of g.calls) {
    assert.equal(c.headers.ConsistencyLevel, 'eventual');
    assert.match(c.url, /\$count=true/);
    assert.match(c.url, /\/transitiveMembers\//);
  }
});

test('pages past 999 are followed, not dropped', async () => {
  const g = fakeGraph([
    { match: (u) => u.includes('page=2'), reply: () => ({ body: { value: [{ id: 'u2' }] } }) },
    { match: (u) => u.includes('microsoft.graph.user'), reply: () => ({ body: { value: [{ id: 'u1' }], '@odata.nextLink': 'https://graph.microsoft.com/v1.0/next?page=2' } }) },
    { match: (u) => u.includes('microsoft.graph.servicePrincipal'), reply: () => ({ body: { value: [] } }) },
  ]);
  const members = await getTransitiveMembers('gid', 'tok', g.impl);
  assert.deepEqual(members.map((m) => m.oid), ['u1', 'u2']);
});

test('a throttled read waits and retries rather than failing the sync', async () => {
  let n = 0;
  const g = fakeGraph([
    { match: (u) => u.includes('microsoft.graph.user'), reply: () => (++n === 1 ? { status: 429, retryAfter: '0' } : { body: { value: [{ id: 'u1' }] } }) },
    { match: (u) => u.includes('microsoft.graph.servicePrincipal'), reply: () => ({ body: { value: [] } }) },
  ]);
  const members = await getTransitiveMembers('gid', 'tok', g.impl);
  assert.deepEqual(members.map((m) => m.oid), ['u1']);
  assert.equal(n, 2);
});

test('an ambiguous group name is refused, not guessed', async () => {
  const g = fakeGraph([{ match: () => true, reply: () => ({ body: { value: [{ id: 'a' }, { id: 'b' }] } }) }]);
  await assert.rejects(resolveGroupId('claude-code-standard', 'tok', g.impl), /2 groups are named/);
});

test('an object id is used as given; a missing name is null', async () => {
  assert.equal(await resolveGroupId('11111111-1111-1111-1111-111111111111', 'tok', async () => { throw new Error('should not call'); }), '11111111-1111-1111-1111-111111111111');
  const g = fakeGraph([{ match: () => true, reply: () => ({ body: { value: [] } }) }]);
  assert.equal(await resolveGroupId('nope', 'tok', g.impl), null);
});

test('a Graph failure other than throttling is an error, not an empty group', async () => {
  const g = fakeGraph([{ match: () => true, reply: () => ({ status: 403, body: { error: { code: 'Authorization_RequestDenied' } } }) }]);
  await assert.rejects(getTransitiveMembers('gid', 'tok', g.impl), /Graph 403/);
});
