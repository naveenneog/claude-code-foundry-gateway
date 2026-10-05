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
const graphPreload = fileURLToPath(new URL('./fake-graph-preload.mjs', import.meta.url));
const graphPreloadUrl = pathToFileURL(graphPreload).href;
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

function runApplyWithFake({ name, docs = {}, snapshot, args = [] }) {
  const dir = join(work, name.replace(/[^a-z0-9]+/gi, '-'));
  rmSync(dir, { recursive: true, force: true });
  mkdirSync(dir, { recursive: true });
  const store = join(dir, 'cosmos.json');
  const log = join(dir, 'cosmos.log');
  const snapshotPath = join(dir, 'snapshot.json');
  writeFileSync(store, JSON.stringify({ docs }));
  writeFileSync(log, '');
  writeFileSync(snapshotPath, JSON.stringify(snapshot));
  const result = spawnSync(process.execPath, [
    '--loader', loaderUrl, script,
    '--cosmos', cosmos, '--tenant', tenant, '--account-resource-id', account,
    '--snapshot', snapshotPath, ...args,
  ], {
    encoding: 'utf8',
    env: { ...process.env, FAKE_COSMOS_STORE: store, FAKE_COSMOS_LOG: log, PROJECTION_ACCOUNT_RESOURCE_ID: '' },
  });
  const summary = JSON.parse(result.stdout.trim().split(/\r?\n/).filter((line) => line.startsWith('{')).at(-1));
  return { result, summary, store, log };
}

function fullSnapshot({ verifiedAt, records }) {
  return {
    kind: 'claude-entitlement-snapshot',
    tenantId: tenant,
    generatedAt: new Date(verifiedAt).toISOString(),
    reconciliationGeneration: '66666666-6666-4666-8666-666666666666',
    lastVerifiedAt: new Date(verifiedAt).toISOString(),
    expiresAt: Math.floor(new Date(verifiedAt).getTime() / 1000) + 7200,
    mappingVersion: Math.floor(new Date(verifiedAt).getTime() / 1000),
    records,
  };
}

function statusDoc({ generation, mode, user, finishedAt }) {
  return {
    id: `projection-status::${tenant}::${generation}`,
    oid: `projection-status::${tenant}`,
    type: 'projection-reconciliation-status',
    ttl: 604800,
    tenantId: tenant,
    accountResourceId: account,
    databaseName: 'claude',
    containerName: 'entitlement',
    ok: true,
    mode,
    executor: 'runner',
    user,
    reconciliationGeneration: generation,
    lastVerifiedAt: new Date(finishedAt).toISOString(),
    startedAt: new Date(finishedAt).toISOString(),
    finishedAt: new Date(finishedAt).toISOString(),
  };
}

test('a newer targeted status makes a stale full snapshot exclude that user from its plan', () => {
  const target = '33333333-3333-4333-8333-333333333333';
  const otherUser = '44444444-4444-4444-8444-444444444444';
  const snapshotTime = new Date(Date.now() - 120_000).toISOString();
  const newerTime = new Date(Date.now() - 60_000).toISOString();
  const snap = fullSnapshot({
    verifiedAt: snapshotTime,
    records: [
      { oid: target, tier: 'standard', businessUnit: '' },
      { oid: otherUser, tier: 'standard', businessUnit: '' },
    ],
  });
  const newerUserStatus = statusDoc({
    generation: '77777777-7777-4777-8777-777777777777',
    mode: 'user',
    user: target,
    finishedAt: newerTime,
  });
  const { result, summary, store } = runApplyWithFake({
    name: 'stale full excludes newer targeted user',
    docs: { [`${newerUserStatus.id}|${newerUserStatus.oid}`]: newerUserStatus },
    snapshot: snap,
  });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.equal(summary.excludedByNewerTargetedSync, 1);
  const docs = Object.values(JSON.parse(readFileSync(store, 'utf8')).docs);
  assert.equal(docs.some((d) => d.oid === target && d.type !== 'projection-reconciliation-status'), false);
  assert.equal(docs.find((d) => d.oid === otherUser).tier, 'standard');
});

test('a newer full status refuses a stale full snapshot before it writes', () => {
  const target = '33333333-3333-4333-8333-333333333333';
  const snapshotTime = new Date(Date.now() - 120_000).toISOString();
  const newerTime = new Date(Date.now() - 60_000).toISOString();
  const snap = fullSnapshot({
    verifiedAt: snapshotTime,
    records: [{ oid: target, tier: 'standard', businessUnit: '' }],
  });
  const newerFullStatus = statusDoc({
    generation: '88888888-8888-4888-8888-888888888888',
    mode: 'full',
    finishedAt: newerTime,
  });
  const { result, summary, store } = runApplyWithFake({
    name: 'stale full refused by newer full',
    docs: { [`${newerFullStatus.id}|${newerFullStatus.oid}`]: newerFullStatus },
    snapshot: snap,
  });
  assert.equal(result.status, 2, result.stdout + result.stderr);
  assert.match(summary.error, /newer full sync finished after this snapshot was taken/);
  const docs = Object.values(JSON.parse(readFileSync(store, 'utf8')).docs);
  assert.equal(docs.some((d) => d.oid === target && d.type !== 'projection-reconciliation-status'), false);
});

test('a targeted status older than the full snapshot excludes nothing', () => {
  const target = '33333333-3333-4333-8333-333333333333';
  const snapshotTime = new Date(Date.now() - 120_000).toISOString();
  const olderTime = new Date(Date.now() - 180_000).toISOString();
  const snap = fullSnapshot({
    verifiedAt: snapshotTime,
    records: [{ oid: target, tier: 'standard', businessUnit: '' }],
  });
  const olderUserStatus = statusDoc({
    generation: '99999999-9999-4999-8999-999999999999',
    mode: 'user',
    user: target,
    finishedAt: olderTime,
  });
  const { result, summary, store } = runApplyWithFake({
    name: 'older target status ignored',
    docs: { [`${olderUserStatus.id}|${olderUserStatus.oid}`]: olderUserStatus },
    snapshot: snap,
  });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.equal(summary.excludedByNewerTargetedSync, 0);
  const docs = Object.values(JSON.parse(readFileSync(store, 'utf8')).docs);
  assert.equal(docs.find((d) => d.oid === target).tier, 'standard');
});

function runGraphWithConcurrentStatus({ name, mode }) {
  const dir = join(work, name.replace(/[^a-z0-9]+/gi, '-'));
  rmSync(dir, { recursive: true, force: true });
  mkdirSync(dir, { recursive: true });
  const store = join(dir, 'cosmos.json');
  const log = join(dir, 'cosmos.log');
  writeFileSync(store, JSON.stringify({ docs: {} }));
  writeFileSync(log, '');
  const target = '33333333-3333-4333-8333-333333333333';
  const otherUser = '44444444-4444-4444-8444-444444444444';
  const group = '11111111-1111-4111-8111-111111111111';
  const result = spawnSync(process.execPath, [
    '--import', graphPreloadUrl, '--loader', loaderUrl, script,
    '--cosmos', cosmos, '--tenant', tenant, '--account-resource-id', account,
    '--graph', '--standard', group, '--premium', 'none',
  ], {
    encoding: 'utf8',
    env: {
      ...process.env,
      FAKE_COSMOS_STORE: store,
      FAKE_COSMOS_LOG: log,
      FAKE_GRAPH_TENANT: tenant,
      FAKE_GRAPH_ACCOUNT_RESOURCE_ID: account,
      FAKE_GRAPH_GROUP_ID: group,
      FAKE_GRAPH_TARGET_USER: target,
      FAKE_GRAPH_USERS: `${target},${otherUser}`,
      FAKE_GRAPH_CONCURRENT_STATUS_MODE: mode,
      PROJECTION_ACCOUNT_RESOURCE_ID: '',
      PROJECTION_STANDARD_GROUP_ID: '',
      PROJECTION_PREMIUM_GROUP_ID: '',
      PROJECTION_GATEWAY_RESOURCE_ID: '',
    },
  });
  const summary = JSON.parse(result.stdout.trim().split(/\r?\n/).filter((line) => line.startsWith('{')).at(-1));
  return { result, summary, store, target, otherUser };
}

test('a concurrent targeted sync during graph full apply excludes that user from writes and deletes', () => {
  const { result, summary, store, target, otherUser } = runGraphWithConcurrentStatus({ name: 'graph concurrent user', mode: 'user' });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.equal(summary.excludedByNewerTargetedSync, 1);
  const docs = Object.values(JSON.parse(readFileSync(store, 'utf8')).docs);
  assert.equal(docs.some((d) => d.oid === target && d.type !== 'projection-reconciliation-status'), false);
  assert.equal(docs.find((d) => d.oid === otherUser).tier, 'standard');
});

test('a concurrent full sync during graph full apply refuses before writing users', () => {
  const { result, summary, store, target, otherUser } = runGraphWithConcurrentStatus({ name: 'graph concurrent full', mode: 'full' });
  assert.equal(result.status, 2, result.stdout + result.stderr);
  assert.match(summary.error, /newer full sync finished after this snapshot was taken/);
  const docs = Object.values(JSON.parse(readFileSync(store, 'utf8')).docs);
  assert.equal(docs.some((d) => [target, otherUser].includes(d.oid) && d.type !== 'projection-reconciliation-status'), false);
});
