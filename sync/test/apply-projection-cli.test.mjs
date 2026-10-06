import { after, test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
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
const work = mkdtempSync(join(tmpdir(), 'apply-cli-'));
const cleanupWork = () => rmSync(work, { recursive: true, force: true });
after(cleanupWork);
process.on('exit', cleanupWork);

test('apply CLI tests keep their scratch directory outside the repository', () => {
  assert.equal(work.toLowerCase().includes(`${'sync'}\\.test-work`), false);
});

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
  const badFormat = run([...base, '--account-resource-id', '/subscriptions/not-an-arm-id']).json;
  assert.match(badFormat.error, /--account-resource-id must be an ARM id/);
  assert.match(badFormat.error, /Remedy: .*Sync-ClaudeAccess\.ps1 -ResourceGroup <rg> -ApimName <apim>/);

  const wrongName = run([...base, '--account-resource-id', other]);
  assert.equal(wrongName.code, 1);
  assert.match(wrongName.json.error, /other.*cosmos/);
  assert.match(wrongName.json.error, /Remedy: .*--cosmos https:\/\/<account>\.documents\.azure\.com:443\//);

  const envMismatch = run([...base, '--account-resource-id', account], { PROJECTION_ACCOUNT_RESOURCE_ID: other });
  assert.equal(envMismatch.code, 1);
  assert.match(envMismatch.json.error, /differs from PROJECTION_ACCOUNT_RESOURCE_ID/);
  assert.match(envMismatch.json.error, /Remedy: .*Sync-ClaudeAccess\.ps1 -ResourceGroup <rg> -ApimName <apim>/);
});

test('mutating applies require an account resource id, while what-if remains read-only', () => {
  const dir = join(work, 'missing-account-id');
  rmSync(dir, { recursive: true, force: true });
  mkdirSync(dir, { recursive: true });
  const snapshot = join(dir, 'snapshot.json');
  const verifiedAt = new Date(Date.now() - 60_000);
  writeFileSync(snapshot, JSON.stringify(fullSnapshot({
    verifiedAt,
    records: [{ oid: '33333333-3333-4333-8333-333333333333', tier: 'standard', businessUnit: '' }],
  })));

  const refused = run(['--cosmos', cosmos, '--tenant', tenant, '--snapshot', snapshot]);
  assert.equal(refused.code, 1);
  assert.match(refused.json.error, /--account-resource-id is required/);
  assert.match(refused.json.error, /Remedy: .*Sync-ClaudeAccess\.ps1 -ResourceGroup <rg> -ApimName <apim>/);

  const store = join(dir, 'cosmos.json');
  const log = join(dir, 'cosmos.log');
  writeFileSync(store, JSON.stringify({ docs: {} }));
  writeFileSync(log, '');
  const whatIf = spawnSync(process.execPath, [
    '--loader', loaderUrl, script,
    '--cosmos', cosmos, '--tenant', tenant, '--snapshot', snapshot, '--whatif',
  ], {
    encoding: 'utf8',
    env: { ...process.env, FAKE_COSMOS_STORE: store, FAKE_COSMOS_LOG: log, PROJECTION_ACCOUNT_RESOURCE_ID: '' },
  });
  const summary = JSON.parse(whatIf.stdout.trim().split(/\r?\n/).filter((line) => line.startsWith('{')).at(-1));
  assert.equal(whatIf.status, 0, whatIf.stdout + whatIf.stderr);
  assert.equal(summary.whatIf, true);
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
  assert.equal(status.accountResourceId, account.toLowerCase());
  assert.equal(docs.find((d) => d.oid === otherUser).tier, 'standard');
});

test('a targeted apply rewrites a same-tier legacy record to remove expiresAt', () => {
  const target = '33333333-3333-4333-8333-333333333333';
  const verifiedAt = new Date(Date.now() - 60_000).toISOString();
  const snap = {
    ...fullSnapshot({ verifiedAt, records: [{ oid: target, tier: 'standard', businessUnit: '' }] }),
    scope: 'user',
    user: target,
  };
  const { result, summary, store, log } = runApplyWithFake({
    name: 'targeted legacy expiry rewrite',
    docs: {
      [`${target}|${target}`]: {
        id: target,
        oid: target,
        tenantId: tenant,
        tier: 'standard',
        businessUnit: '',
        expiresAt: Math.floor(Date.now() / 1000) - 3600,
      },
    },
    snapshot: snap,
    args: ['--user', target],
  });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.equal(summary.toWrite, 1);
  assert.match(readFileSync(log, 'utf8'), new RegExp(`bulk Upsert ${target}`));
  const written = JSON.parse(readFileSync(store, 'utf8')).docs[`${target}|${target}`];
  assert.equal(written.tier, 'standard');
  assert.equal('expiresAt' in written, false);
});

function runApplyWithFake({ name, docs = {}, snapshot, args = [], env = {} }) {
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
    env: { ...process.env, FAKE_COSMOS_STORE: store, FAKE_COSMOS_LOG: log, PROJECTION_ACCOUNT_RESOURCE_ID: '', ...env },
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
  assert.match(summary.error, /Remedy: rerun scripts\/Sync-ClaudeAccess\.ps1 -ResourceGroup <rg> -ApimName <apim>/);
  const docs = Object.values(JSON.parse(readFileSync(store, 'utf8')).docs);
  assert.equal(docs.some((d) => d.oid === target && d.type !== 'projection-reconciliation-status'), false);
});

test('a targeted apply refuses a snapshot older than a successful user or full apply', () => {
  const target = '33333333-3333-4333-8333-333333333333';
  const snapshotTime = new Date(Date.now() - 120_000).toISOString();
  const newerTime = new Date(Date.now() - 60_000).toISOString();
  const snap = {
    ...fullSnapshot({ verifiedAt: snapshotTime, records: [{ oid: target, tier: 'standard', businessUnit: '' }] }),
    scope: 'user',
    user: target,
  };
  const newerUserStatus = statusDoc({
    generation: 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa',
    mode: 'user',
    user: target,
    finishedAt: newerTime,
  });
  const { result, summary, store } = runApplyWithFake({
    name: 'stale targeted refused',
    docs: { [`${newerUserStatus.id}|${newerUserStatus.oid}`]: newerUserStatus },
    snapshot: snap,
    args: ['--user', target],
  });
  assert.equal(result.status, 2, result.stdout + result.stderr);
  assert.match(summary.error, /newer sync already finished for this user/);
  assert.match(summary.error, /Remedy: rerun scripts\/Sync-ClaudeAccess\.ps1 -ResourceGroup <rg> -ApimName <apim> -User <upn-or-oid>/);
  const docs = Object.values(JSON.parse(readFileSync(store, 'utf8')).docs);
  assert.equal(docs.some((d) => d.oid === target && d.type !== 'projection-reconciliation-status'), false);
});

test('a targeted status older than the full snapshot excludes nothing', () => {
  const target = '33333333-3333-4333-8333-333333333333';
  const snapshotTime = new Date(Date.now() - 120_000).toISOString();
  const olderTime = new Date(Date.now() - 600_000).toISOString();
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

test('a targeted status up to 300 seconds older than the full snapshot still excludes that user (clock skew margin)', () => {
  const target = '33333333-3333-4333-8333-333333333333';
  const snapshotTime = new Date(Date.now() - 120_000).toISOString();
  const withinMargin = new Date(Date.now() - 240_000).toISOString();
  const snap = fullSnapshot({
    verifiedAt: snapshotTime,
    records: [{ oid: target, tier: 'standard', businessUnit: '' }],
  });
  const skewedUserStatus = statusDoc({
    generation: '99999999-9999-4999-8999-99999999999a',
    mode: 'user',
    user: target,
    finishedAt: withinMargin,
  });
  const { result, summary, store } = runApplyWithFake({
    name: 'targeted status within the skew margin',
    docs: { [`${skewedUserStatus.id}|${skewedUserStatus.oid}`]: skewedUserStatus },
    snapshot: snap,
  });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.equal(summary.excludedByNewerTargetedSync, 1);
  const docs = Object.values(JSON.parse(readFileSync(store, 'utf8')).docs);
  assert.equal(docs.some((d) => d.oid === target && d.type !== 'projection-reconciliation-status'), false);
});

test('a full apply reads every existing-record page and deletes an orphan on the last page', () => {
  const target = '33333333-3333-4333-8333-333333333333';
  const orphan = '55555555-5555-4555-8555-555555555555';
  const snap = fullSnapshot({
    verifiedAt: new Date(Date.now() - 60_000).toISOString(),
    records: [{ oid: target, tier: 'standard', businessUnit: '' }],
  });
  const { result, summary, store, log } = runApplyWithFake({
    name: 'multipage existing deletes last orphan',
    docs: {
      [`${target}|${target}`]: { id: target, oid: target, tenantId: tenant, tier: 'standard', businessUnit: '' },
      [`${orphan}|${orphan}`]: { id: orphan, oid: orphan, tenantId: tenant, tier: 'premium', businessUnit: '' },
    },
    snapshot: snap,
    env: { FAKE_COSMOS_PAGE_SIZE: '1' },
  });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.equal(summary.deleted, 1);
  assert.equal(summary.existing, 2);
  assert.match(readFileSync(log, 'utf8'), /fetch-page 0 rows=1/);
  assert.match(readFileSync(log, 'utf8'), /fetch-page 1 rows=1/);
  assert.match(readFileSync(log, 'utf8'), new RegExp(`bulk Delete ${orphan}`));
  const docs = Object.values(JSON.parse(readFileSync(store, 'utf8')).docs);
  assert.equal(docs.some((d) => d.oid === orphan), false);
});

test('a long multi-page read renews the apply lease between pages, before any write', () => {
  const oids = ['33333333-3333-4333-8333-333333333331', '33333333-3333-4333-8333-333333333332', '33333333-3333-4333-8333-333333333333', '33333333-3333-4333-8333-333333333334'];
  const snap = fullSnapshot({
    verifiedAt: new Date(Date.now() - 60_000).toISOString(),
    records: oids.map((oid) => ({ oid, tier: 'standard', businessUnit: '' })),
  });
  const { result, log } = runApplyWithFake({
    name: 'lease renewed during a long read',
    docs: Object.fromEntries(oids.map((oid) => [`${oid}|${oid}`, { id: oid, oid, tenantId: tenant, tier: 'standard', businessUnit: '' }])),
    snapshot: snap,
    env: { FAKE_COSMOS_PAGE_SIZE: '1', FAKE_APPLY_LOCK_ADVANCE_MS: '60000' },
  });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  const lines = readFileSync(log, 'utf8').split('\n');
  const readStart = lines.findIndex((l) => l.startsWith('query SELECT c.id, c.tier'));
  const readEnd = lines.findIndex((l, i) => i > readStart && l.startsWith('query '));
  assert.ok(readStart >= 0 && readEnd > readStart, lines.join('\n'));
  const renewals = lines.slice(readStart, readEnd).filter((l) => l.startsWith('replace projection-apply-lock'));
  assert.ok(renewals.length >= 1, `no lease renewal while reading existing records:\n${lines.join('\n')}`);
});

test('an empty existing-record page with more results does not end the scan early', () => {
  const target = '33333333-3333-4333-8333-333333333333';
  const snap = fullSnapshot({
    verifiedAt: new Date(Date.now() - 60_000).toISOString(),
    records: [{ oid: target, tier: 'standard', businessUnit: '' }],
  });
  const { result, summary, log } = runApplyWithFake({
    name: 'empty page before existing record',
    docs: {
      [`${target}|${target}`]: { id: target, oid: target, tenantId: tenant, tier: 'standard', businessUnit: '' },
    },
    snapshot: snap,
    env: { FAKE_COSMOS_PAGE_SIZE: '1', FAKE_COSMOS_EMPTY_FIRST_PAGE: '1' },
  });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.equal(summary.existing, 1);
  assert.equal(summary.unchanged, 1);
  assert.equal(summary.toWrite, 0);
  assert.equal(summary.toDelete, 0);
  const calls = readFileSync(log, 'utf8');
  assert.match(calls, /fetch-page 0 rows=0/);
  assert.match(calls, /fetch-page 1 rows=1/);
  assert.doesNotMatch(calls, new RegExp(`bulk (Upsert|Delete) ${target}`));
});

test('the stale-change guard reads every status page before planning a full apply', () => {
  const target = '33333333-3333-4333-8333-333333333333';
  const otherUser = '44444444-4444-4444-8444-444444444444';
  const snapshotTime = new Date(Date.now() - 120_000).toISOString();
  const olderTime = new Date(Date.now() - 600_000).toISOString();
  const newerTime = new Date(Date.now() - 60_000).toISOString();
  const snap = fullSnapshot({
    verifiedAt: snapshotTime,
    records: [
      { oid: target, tier: 'standard', businessUnit: '' },
      { oid: otherUser, tier: 'standard', businessUnit: '' },
    ],
  });
  const olderStatus = statusDoc({
    generation: 'bbbbbbbb-1111-4111-8111-bbbbbbbbbbbb',
    mode: 'user',
    user: otherUser,
    finishedAt: olderTime,
  });
  const newerStatus = statusDoc({
    generation: 'cccccccc-1111-4111-8111-cccccccccccc',
    mode: 'user',
    user: target,
    finishedAt: newerTime,
  });
  const { result, summary, store, log } = runApplyWithFake({
    name: 'multipage status excludes newer target',
    docs: {
      [`${olderStatus.id}|${olderStatus.oid}`]: olderStatus,
      [`${newerStatus.id}|${newerStatus.oid}`]: newerStatus,
    },
    snapshot: snap,
    env: { FAKE_COSMOS_PAGE_SIZE: '1' },
  });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.equal(summary.excludedByNewerTargetedSync, 1);
  assert.match(readFileSync(log, 'utf8'), /fetch-page 1 rows=1/);
  const docs = Object.values(JSON.parse(readFileSync(store, 'utf8')).docs);
  assert.equal(docs.some((d) => d.oid === target && d.type !== 'projection-reconciliation-status'), false);
  assert.equal(docs.find((d) => d.oid === otherUser).tier, 'standard');
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

test('an unexpired apply lock times out without writes or status', () => {
  const target = '33333333-3333-4333-8333-333333333333';
  const lock = {
    id: 'projection-apply-lock',
    oid: 'projection-apply-lock',
    type: 'projection-apply-lock',
    holder: 'other-run',
    mode: 'user',
    acquiredAt: new Date().toISOString(),
    leaseExpiresAt: new Date(Date.now() + 300_000).toISOString(),
  };
  const snap = fullSnapshot({
    verifiedAt: new Date(Date.now() - 60_000).toISOString(),
    records: [{ oid: target, tier: 'standard', businessUnit: '' }],
  });
  const { result, summary, store } = runApplyWithFake({
    name: 'lock timeout',
    docs: { [`${lock.id}|${lock.oid}`]: lock },
    snapshot: snap,
    args: ['--lock-wait-seconds', '0'],
  });
  assert.equal(result.status, 3, result.stdout + result.stderr);
  assert.equal(summary.stage, 'lock');
  assert.match(summary.error, /other-run/);
  assert.match(summary.error, /Remedy: rerun the same command after/);
  const docs = Object.values(JSON.parse(readFileSync(store, 'utf8')).docs);
  assert.equal(docs.some((d) => d.oid === target), false);
  assert.equal(docs.some((d) => d.type === 'projection-reconciliation-status'), false);
});

test('an expired apply lock is taken over and released after success', () => {
  const target = '33333333-3333-4333-8333-333333333333';
  const lock = {
    id: 'projection-apply-lock',
    oid: 'projection-apply-lock',
    type: 'projection-apply-lock',
    holder: 'old-run',
    mode: 'full',
    acquiredAt: new Date(Date.now() - 600_000).toISOString(),
    leaseExpiresAt: new Date(Date.now() - 300_000).toISOString(),
  };
  const snap = fullSnapshot({
    verifiedAt: new Date(Date.now() - 60_000).toISOString(),
    records: [{ oid: target, tier: 'standard', businessUnit: '' }],
  });
  const { result, summary, store, log } = runApplyWithFake({
    name: 'expired lock takeover',
    docs: { [`${lock.id}|${lock.oid}`]: lock },
    snapshot: snap,
  });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.equal(summary.written, 1);
  const docs = Object.values(JSON.parse(readFileSync(store, 'utf8')).docs);
  assert.equal(docs.some((d) => d.type === 'projection-apply-lock'), false);
  assert.match(readFileSync(log, 'utf8'), /replace projection-apply-lock\|projection-apply-lock if-match/);
  assert.match(readFileSync(log, 'utf8'), /delete projection-apply-lock\|projection-apply-lock if-match/);
});

test('lock documents are skipped as entitlement records and never deleted as orphans', () => {
  const lock = {
    id: 'projection-apply-lock',
    oid: 'projection-apply-lock',
    type: 'projection-apply-lock',
    holder: 'old-run',
    mode: 'full',
    acquiredAt: new Date(Date.now() - 600_000).toISOString(),
    leaseExpiresAt: new Date(Date.now() - 300_000).toISOString(),
  };
  const snap = fullSnapshot({
    verifiedAt: new Date(Date.now() - 60_000).toISOString(),
    records: [],
  });
  const { result, summary, store, log } = runApplyWithFake({
    name: 'lock not orphan',
    docs: { [`${lock.id}|${lock.oid}`]: lock },
    snapshot: snap,
    args: ['--allow-empty'],
  });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.equal(summary.existing, 0);
  assert.doesNotMatch(readFileSync(log, 'utf8'), /bulk Delete projection-apply-lock/);
  const docs = Object.values(JSON.parse(readFileSync(store, 'utf8')).docs);
  assert.equal(docs.some((d) => d.type === 'projection-apply-lock'), false);
});

test('a renewal failure aborts before the next write and writes no status', () => {
  const records = Array.from({ length: 1001 }, (_, i) => ({
    oid: `${String(i + 1).padStart(8, '0')}-3333-4333-8333-333333333333`,
    tier: 'standard',
    businessUnit: '',
  }));
  const snap = fullSnapshot({
    verifiedAt: new Date(Date.now() - 60_000).toISOString(),
    records,
  });
  const { result, summary, store } = runApplyWithFake({
    name: 'renewal failure stops second batch',
    snapshot: snap,
    args: ['--lock-wait-seconds', '0'],
    env: { FAKE_COSMOS_FAIL_RENEW_AFTER_BULK: '1', FAKE_APPLY_LOCK_ADVANCE_MS: '120000' },
  });
  // The fake advances the lock clock and makes the first renewal fail for this directory.
  assert.equal(result.status, 3, result.stdout + result.stderr);
  assert.equal(summary.stage, 'lock');
  assert.match(summary.error, /lost the projection apply lock/);
  assert.match(summary.error, /Remedy:/);
  const docs = Object.values(JSON.parse(readFileSync(store, 'utf8')).docs);
  assert.equal(docs.filter((d) => d.type !== 'projection-reconciliation-status' && d.type !== 'projection-apply-lock').length, 1000);
  assert.equal(docs.some((d) => d.type === 'projection-reconciliation-status'), false);
});

test('graph mode refuses missing or partial job settings before Azure work', () => {
  const group = '11111111-1111-4111-8111-111111111111';
  const missing = run(['--cosmos', cosmos, '--tenant', tenant, '--account-resource-id', account, '--graph']);
  assert.equal(missing.code, 1);
  assert.match(missing.json.error, /job settings refused/);
  assert.match(missing.json.error, /PROJECTION_ACCOUNT_RESOURCE_ID/);
  assert.match(missing.json.error, /Remedy: .*Deploy-ClaudeProjectionRenewal\.ps1/);

  const partial = run(['--cosmos', cosmos, '--tenant', tenant, '--account-resource-id', account, '--graph', '--standard', group]);
  assert.equal(partial.code, 1);
  assert.match(partial.json.error, /partial tier override/);
  assert.match(partial.json.error, /Remedy: .*--graph --standard <group-object-id> --premium <group-object-id-or-none>/);

  const noAccount = run(['--cosmos', cosmos, '--tenant', tenant, '--graph'], {
    AZURE_CLIENT_ID: group,
    PROJECTION_STANDARD_GROUP_ID: group,
    PROJECTION_PREMIUM_GROUP_ID: 'none',
    PROJECTION_GATEWAY_RESOURCE_ID: '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg/providers/Microsoft.ApiManagement/service/apim',
  });
  assert.equal(noAccount.code, 1);
  assert.match(noAccount.json.error, /PROJECTION_ACCOUNT_RESOURCE_ID/);
  assert.match(noAccount.json.error, /Remedy:/);
});
