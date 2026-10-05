import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const script = fileURLToPath(new URL('../src/apply-projection.mjs', import.meta.url));
const tenant = '22222222-2222-4222-8222-222222222222';
const account = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg/providers/Microsoft.DocumentDB/databaseAccounts/cosmos';
const other = account.replace('databaseAccounts/cosmos', 'databaseAccounts/other');
const cosmos = 'https://cosmos.documents.azure.com:443/';
const loader = fileURLToPath(new URL('./fake-azure-loader.mjs', import.meta.url));
const loaderUrl = pathToFileURL(loader).href;
const work = fileURLToPath(new URL('../.test-work/apply-cli/', import.meta.url));

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

test('targeted snapshots must name one matching user record or no record; status records use a non-guid partition and retain seven days of switch evidence', () => {
  rmSync(work, { recursive: true, force: true });
  mkdirSync(work, { recursive: true });
  const target = '33333333-3333-4333-8333-333333333333';
  const otherUser = '44444444-4444-4444-8444-444444444444';
  const store = join(work, 'cosmos.json');
  const log = join(work, 'cosmos.log');
  writeFileSync(store, JSON.stringify({ docs: {
    [`${target}|${target}`]: { id: target, oid: target, tenantId: tenant, tier: 'standard', businessUnit: '' },
    [`${otherUser}|${otherUser}`]: { id: otherUser, oid: otherUser, tenantId: tenant, tier: 'standard', businessUnit: '' },
  } }));
  writeFileSync(log, '');
  const snapshot = join(work, 'target.json');
  const verifiedAt = new Date(Date.now() - 60_000);
  writeFileSync(snapshot, JSON.stringify({
    kind: 'claude-entitlement-snapshot',
    tenantId: tenant,
    generatedAt: new Date().toISOString(),
    reconciliationGeneration: '55555555-5555-4555-8555-555555555555',
    lastVerifiedAt: verifiedAt.toISOString(),
    expiresAt: Math.floor(verifiedAt.getTime() / 1000) + 7200,
    mappingVersion: Math.floor(verifiedAt.getTime() / 1000),
    scope: 'user',
    user: target,
    records: [{ oid: target, tier: 'premium', businessUnit: '' }],
  }));
  const result = spawnSync(process.execPath, [
    '--loader', loaderUrl, script,
    '--cosmos', cosmos, '--tenant', tenant, '--account-resource-id', account,
    '--snapshot', snapshot, '--user', target,
  ], {
    encoding: 'utf8',
    env: { ...process.env, FAKE_COSMOS_STORE: store, FAKE_COSMOS_LOG: log, PROJECTION_ACCOUNT_RESOURCE_ID: '' },
  });
  const summary = JSON.parse(result.stdout.trim().split(/\r?\n/).filter((line) => line.startsWith('{')).at(-1));
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.equal(summary.executor, 'runner');
  assert.equal(summary.mode, 'user');
  const calls = readFileSync(log, 'utf8');
  assert.match(calls, new RegExp(`point-read ${target}\\|${target}`));
  assert.doesNotMatch(calls, /WHERE NOT IS_DEFINED\(c\.type\)/);
  assert.doesNotMatch(calls, new RegExp(`bulk (Upsert|Delete) ${otherUser}`));
  const docs = Object.values(JSON.parse(readFileSync(store, 'utf8')).docs);
  const status = docs.find((d) => d.type === 'projection-reconciliation-status');
  assert.equal(status.executor, 'runner');
  assert.equal(status.accountResourceId, account);
  assert.equal(docs.find((d) => d.oid === otherUser).tier, 'standard');
});
