import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const script = fileURLToPath(new URL('../src/apply-projection.mjs', import.meta.url));
const tenant = '22222222-2222-4222-8222-222222222222';
const account = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg/providers/Microsoft.DocumentDB/databaseAccounts/cosmos';
const other = account.replace('databaseAccounts/cosmos', 'databaseAccounts/other');
const cosmos = 'https://cosmos.documents.azure.com:443/';

function run(args = [], env = {}) {
  const result = spawnSync(process.execPath, [script, ...args], {
    encoding: 'utf8',
    env: { ...process.env, COSMOS_ENDPOINT: '', PROJECTION_TENANT_ID: '', PROJECTION_ACCOUNT_RESOURCE_ID: '', ...env },
  });
  assert.equal(result.stderr, '');
  const line = result.stdout.trim().split(/\r?\n/).filter((l) => l.startsWith('{')).at(-1);
  assert.ok(line, result.stdout);
  return { code: result.status, json: JSON.parse(line) };
}

test('apply-projection validates account resource id against the Cosmos endpoint before Cosmos work', () => {
  const base = ['--cosmos', cosmos, '--tenant', tenant, '--snapshot', 'missing.json'];
  assert.deepEqual(
    run([...base, '--account-resource-id', '/subscriptions/not-an-arm-id']).json,
    { ok: false, error: '--account-resource-id must be an ARM id: /subscriptions/<guid>/resourceGroups/<rg>/providers/Microsoft.DocumentDB/databaseAccounts/<name>' });

  const wrongName = run([...base, '--account-resource-id', other]);
  assert.equal(wrongName.code, 1);
  assert.match(wrongName.json.error, /other.*cosmos/);

  const envMismatch = run([...base, '--account-resource-id', account], { PROJECTION_ACCOUNT_RESOURCE_ID: other });
  assert.equal(envMismatch.code, 1);
  assert.match(envMismatch.json.error, /differs from PROJECTION_ACCOUNT_RESOURCE_ID/);
});
