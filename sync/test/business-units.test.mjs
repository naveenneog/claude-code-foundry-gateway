import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseBuRegistry, parseBuParents, resolveDepth, sortUnitsByDepth, readGatewayUnits } from '../src/business-units.mjs';

const GATEWAY = '/subscriptions/00000000-0000-4000-8000-000000000001/resourceGroups/rg-p94/providers/Microsoft.ApiManagement/service/apim-p94';

test('the registry parses id, group and budget, and the budget is the last field', () => {
  assert.deepEqual(parseBuRegistry(',eng=Claude Engineering:5000000,fin=Finance: EMEA:1,'), [
    { id: 'eng', group: 'Claude Engineering', tokensPerMonth: 5000000 },
    { id: 'fin', group: 'Finance: EMEA', tokensPerMonth: 1 },
  ]);
});

test('malformed registry entries are skipped as the PowerShell parser skips them', () => {
  assert.deepEqual(parseBuRegistry(',=nobody:1,eng,nobudget=Group,bad=Group:12x,ok=Group:7,'), [
    { id: 'ok', group: 'Group', tokensPerMonth: 7 },
  ]);
  assert.deepEqual(parseBuRegistry(''), []);
  assert.deepEqual(parseBuRegistry(',,'), []);
  assert.deepEqual(parseBuRegistry(null), []);
});

test('the parent map keeps entries with both sides', () => {
  const parents = parseBuParents(',platform=eng,=eng,orphan=,api=eng,');
  assert.deepEqual([...parents.entries()], [['platform', 'eng'], ['api', 'eng']]);
  assert.equal(parseBuParents(',,').size, 0);
});

test('depth follows the parent chain and reports a cycle as the largest depth', () => {
  const parents = parseBuParents(',team=eng,squad=team,a=b,b=a,');
  assert.equal(resolveDepth('eng', parents), 0);
  assert.equal(resolveDepth('team', parents), 1);
  assert.equal(resolveDepth('squad', parents), 2);
  assert.equal(resolveDepth('a', parents), Number.MAX_SAFE_INTEGER);
});

test('units sort deepest first and keep registry order at one depth', () => {
  const units = parseBuRegistry(',eng=G-eng:1,fin=G-fin:1,platform=G-platform:1,api=G-api:1,ops=G-ops:1,');
  const parents = parseBuParents(',platform=eng,api=eng,');
  assert.deepEqual(sortUnitsByDepth(units, parents).map((u) => u.id), ['platform', 'api', 'eng', 'fin', 'ops']);
});

test('the gateway registry is read through ARM, and a missing named value is no units', async () => {
  const seen = [];
  const fetchImpl = async (url, init) => {
    seen.push({ url, auth: init?.headers?.Authorization });
    if (url.includes('/namedValues/bu-registry?')) return reply(200, { properties: { value: ',eng=G-eng:1,platform=G-platform:1,', secret: false } });
    return reply(404, { error: { code: 'ResourceNotFound', message: 'NamedValue not found.' } });
  };
  const read = await readGatewayUnits(GATEWAY, 'arm-token', fetchImpl);
  assert.deepEqual(read.registry.map((u) => u.id), ['eng', 'platform']);
  assert.equal(read.parents.size, 0);
  assert.equal(seen[0].url, `https://management.azure.com${GATEWAY}/namedValues/bu-registry?api-version=2024-05-01`);
  assert.equal(seen[0].auth, 'Bearer arm-token');
});

test('a gateway read that is refused, or a missing gateway, fails instead of reading as no units', async () => {
  const denied = async () => reply(403, { error: { code: 'AuthorizationFailed', message: 'no' } });
  await assert.rejects(readGatewayUnits(GATEWAY, 't', denied), /403/);
  const noGateway = async () => reply(404, { error: { code: 'ResourceNotFound', message: "The Resource 'Microsoft.ApiManagement/service/apim-p94' was not found." } });
  await assert.rejects(readGatewayUnits(GATEWAY, 't', noGateway), /404/);
});

test('a secret registry value fails instead of reading as no units', async () => {
  const secret = async () => reply(200, { properties: { secret: true } });
  await assert.rejects(readGatewayUnits(GATEWAY, 't', secret), /secret/);
});

test('only an API Management resource id is read', async () => {
  const never = async () => { throw new Error('fetched'); };
  await assert.rejects(readGatewayUnits('/subscriptions/x/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/s', 't', never), /API Management resource id/);
  await assert.rejects(readGatewayUnits(`${GATEWAY}/../../other`, 't', never), /API Management resource id/);
});

function reply(status, body) {
  return { ok: status >= 200 && status < 300, status, json: async () => body, text: async () => JSON.stringify(body) };
}
