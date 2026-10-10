import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const script = fileURLToPath(new URL('../src/check-admission.mjs', import.meta.url));
const tenant = '22222222-2222-4222-8222-222222222222';
const account = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg/providers/Microsoft.DocumentDB/databaseAccounts/cosmos';
const cosmos = 'https://cosmos.documents.azure.com:443/';

function run(args = []) {
  const result = spawnSync(process.execPath, [script, ...args], {
    encoding: 'utf8',
    env: { ...process.env, COSMOS_ENDPOINT: '', PROJECTION_TENANT_ID: '', PROJECTION_ACCOUNT_RESOURCE_ID: '' },
  });
  assert.equal(result.stderr, '');
  const line = result.stdout.trim();
  assert.match(line, /^\{.*\}$/);
  return { code: result.status, json: JSON.parse(line) };
}

test('check-admission refuses missing required arguments before any Cosmos client is created', () => {
  assert.deepEqual(run().json, { ok: false, mode: 'switch-evidence', error: '--cosmos is required' });
  assert.equal(run().code, 1);

  assert.deepEqual(
    run(['--cosmos', cosmos]).json,
    { ok: false, mode: 'switch-evidence', error: '--tenant is required' });
  assert.deepEqual(
    run(['--cosmos', cosmos, '--tenant', tenant]).json,
    { ok: false, mode: 'switch-evidence', error: '--account-resource-id is required' });
});

test('check-admission validates required argument shapes before any Cosmos call', () => {
  assert.deepEqual(
    run(['--cosmos', 'not-a-url', '--tenant', tenant, '--account-resource-id', account]).json,
    { ok: false, mode: 'switch-evidence', error: '--cosmos must be an https Cosmos DB endpoint URL' });
  assert.deepEqual(
    run(['--cosmos', cosmos, '--tenant', 'not-a-guid', '--account-resource-id', account]).json,
    { ok: false, mode: 'switch-evidence', error: '--tenant must be a guid' });
  assert.deepEqual(
    run(['--cosmos', cosmos, '--tenant', tenant, '--account-resource-id', '/subscriptions/not-cosmos']).json,
    { ok: false, mode: 'switch-evidence', error: '--account-resource-id must be a Cosmos DB database account resource id' });
});
