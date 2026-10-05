import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { validateJobSettings } from '../src/plan.mjs';

const apply = fileURLToPath(new URL('../src/apply-projection.mjs', import.meta.url));
const endpoint = 'https://cosmos-p97.documents.azure.com:443/';
const tenant = '22222222-2222-4222-8222-222222222222';
const account = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg/providers/Microsoft.DocumentDB/databaseAccounts/cosmos-p97';
const good = {
  AZURE_CLIENT_ID: '40000000-0000-4000-8000-000000000001',
  PROJECTION_STANDARD_GROUP_ID: '10000000-0000-4000-8000-000000000001',
  PROJECTION_PREMIUM_GROUP_ID: 'none',
  PROJECTION_GATEWAY_RESOURCE_ID: '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg/providers/Microsoft.ApiManagement/service/apim-p97',
};

test('a job with its client id, tier groups and gateway is accepted', () => {
  assert.deepEqual(validateJobSettings(good), []);
});

for (const { label, change, setting } of [
  { label: 'admission refuses a job with no client id', change: { AZURE_CLIENT_ID: undefined }, setting: 'AZURE_CLIENT_ID' },
  { label: 'admission refuses a job with no standard group', change: { PROJECTION_STANDARD_GROUP_ID: undefined }, setting: 'PROJECTION_STANDARD_GROUP_ID' },
  { label: 'admission refuses a job with a standard group name instead of an id', change: { PROJECTION_STANDARD_GROUP_ID: 'claude-code-standard' }, setting: 'PROJECTION_STANDARD_GROUP_ID' },
  { label: 'admission refuses a job with no premium setting', change: { PROJECTION_PREMIUM_GROUP_ID: undefined }, setting: 'PROJECTION_PREMIUM_GROUP_ID' },
  { label: 'admission refuses a job with an empty premium setting', change: { PROJECTION_PREMIUM_GROUP_ID: '' }, setting: 'PROJECTION_PREMIUM_GROUP_ID' },
  { label: 'admission refuses a job with no gateway', change: { PROJECTION_GATEWAY_RESOURCE_ID: undefined }, setting: 'PROJECTION_GATEWAY_RESOURCE_ID' },
  { label: 'admission refuses a job with a gateway that is not API Management', change: { PROJECTION_GATEWAY_RESOURCE_ID: '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/stp97' }, setting: 'PROJECTION_GATEWAY_RESOURCE_ID' },
  { label: 'admission refuses a job with one group for both tiers', change: { PROJECTION_PREMIUM_GROUP_ID: good.PROJECTION_STANDARD_GROUP_ID }, setting: 'PROJECTION_PREMIUM_GROUP_ID' },
]) {
  test(label, () => {
    const env = { ...good, ...change };
    for (const key of Object.keys(env)) if (env[key] === undefined) delete env[key];
    const problems = validateJobSettings(env);
    assert.equal(problems.some((p) => p.includes(setting) && p.includes('Deploy-ClaudeProjectionRenewal.ps1')), true, problems.join('\n'));

    const result = spawnSync(process.execPath, [apply, '--cosmos', endpoint, '--tenant', tenant, '--account-resource-id', account, '--graph'], {
      encoding: 'utf8',
      env: { ...process.env, COSMOS_ENDPOINT: '', PROJECTION_TENANT_ID: '', PROJECTION_ACCOUNT_RESOURCE_ID: '', ...env },
    });
    const line = result.stdout.trim().split(/\r?\n/).filter((l) => l.startsWith('{')).at(-1);
    assert.ok(line, result.stdout + result.stderr);
    const json = JSON.parse(line);
    assert.notEqual(result.status, 0);
    assert.match(json.error, new RegExp(setting));
    assert.match(json.error, /Deploy-ClaudeProjectionRenewal\.ps1/);
  });
}
