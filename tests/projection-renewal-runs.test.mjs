// The projection renewal job, run as the scheduled job runs it (image command `--graph`, settings
// from the job's environment), against stand-in Graph, ARM and Cosmos and a controlled clock.
// Started by tests/Test-ProjectionRenewalRuns.ps1, which stages the sync package with the
// stand-in Azure SDK modules and passes PROJECTION_PACKAGE and PROJECTION_FAKES.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync, existsSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { randomUUID } from 'node:crypto';

const pkg = process.env.PROJECTION_PACKAGE;
const preload = pathToFileURL(join(process.env.PROJECTION_FAKES, 'preload.mjs')).href;
const work = process.env.PROJECTION_TEST_WORK;
if (!work) throw new Error('PROJECTION_TEST_WORK is required');
rmSync(work, { recursive: true, force: true });
mkdirSync(work, { recursive: true });
process.on('exit', () => rmSync(work, { recursive: true, force: true }));

const TENANT = '00000000-0000-4000-8000-000000000094';
const SUB = '00000000-0000-4000-8000-000000000001';
const ACCOUNT = `/subscriptions/${SUB}/resourceGroups/rg-p94/providers/Microsoft.DocumentDB/databaseAccounts/cosmos-p94fixture`;
const GATEWAY = `/subscriptions/${SUB}/resourceGroups/rg-p94/providers/Microsoft.ApiManagement/service/apim-p94`;
const ACTION_GROUP = `/subscriptions/${SUB}/resourceGroups/rg-p94/providers/Microsoft.Insights/actionGroups/ag-projection-renewal-p94fixture`;
const ENDPOINT = 'https://cosmos-p94fixture.documents.azure.com:443/';
const DIGEST = `sha256:${'b'.repeat(64)}`;
const ENTRYPOINT = 'node /app/sync/src/apply-projection.mjs';
const STANDARD = '10000000-0000-4000-8000-000000000001';
const PREMIUM = '10000000-0000-4000-8000-000000000002';
const ENG = '20000000-0000-4000-8000-000000000001';
const PLATFORM = '20000000-0000-4000-8000-000000000002';
const FINANCE = '20000000-0000-4000-8000-000000000003';
const USERS = {
  ada: '30000000-0000-4000-8000-000000000001',
  bo: '30000000-0000-4000-8000-000000000002',
  cy: '30000000-0000-4000-8000-000000000003',
  di: '30000000-0000-4000-8000-000000000004',
  build: '30000000-0000-4000-8000-000000000005',
};
const REGISTRY_UNITS = ',eng=Claude Engineering:1000,fin=Claude Finance:1000,';
const REGISTRY_TEAMS = ',eng=Claude Engineering:1000,fin=Claude Finance:1000,platform=Claude Platform:1000,';

function fixture({ registry = REGISTRY_UNITS, parents = ',,', deny = [], missing = [], armStatus = 200, secretRegistry = false } = {}) {
  const member = (oid, cast = 'user') => ({ oid, upn: `${oid.slice(-4)}@example.invalid`, cast });
  return {
    graph: {
      groupsByName: { 'Claude Engineering': [ENG], 'Claude Platform': [PLATFORM], 'Claude Finance': [FINANCE] },
      members: {
        [STANDARD]: [member(USERS.ada), member(USERS.bo), member(USERS.build, 'servicePrincipal')],
        [PREMIUM]: [member(USERS.cy), member(USERS.di)],
        [ENG]: [member(USERS.ada), member(USERS.bo)],
        [PLATFORM]: [member(USERS.bo)],
        [FINANCE]: [member(USERS.cy)],
      },
      deny,
      missing,
    },
    arm: {
      status: armStatus,
      namedValues: { 'bu-registry': { value: registry, secret: secretRegistry }, 'bu-parents': { value: parents } },
    },
  };
}

function scenario(name) {
  const dir = join(work, name.replace(/[^a-z0-9]+/gi, '-'));
  rmSync(dir, { recursive: true, force: true });
  mkdirSync(dir, { recursive: true });
  return { dir, store: join(dir, 'cosmos.json'), log: join(dir, 'fetch.log') };
}

function cleanEnvironment() {
  const env = { ...process.env };
  for (const key of Object.keys(env)) {
    if (/^(COSMOS_|PROJECTION_|AZURE_|CONTAINER_APP_|FAKE_)/.test(key)) delete env[key];
  }
  return env;
}

function run(where, script, args, { now, env = {}, fetch = fixture() } = {}) {
  const fixturePath = join(where.dir, `fetch-${randomUUID()}.json`);
  writeFileSync(fixturePath, JSON.stringify(fetch));
  const childEnv = { ...cleanEnvironment(), FAKE_NOW: now, FAKE_COSMOS_STORE: where.store, FAKE_COSMOS_LOG: join(where.dir, 'cosmos.log'), FAKE_FETCH_FIXTURE: fixturePath, FAKE_FETCH_LOG: where.log, ...env };
  for (const key of Object.keys(childEnv)) if (childEnv[key] === undefined) delete childEnv[key];
  const result = spawnSync(process.execPath, ['--import', preload, join(pkg, 'sync', 'src', script), ...args], {
    env: childEnv,
    encoding: 'utf8',
    timeout: 60000,
  });
  const last = result.stdout.split(/\r?\n/).filter((line) => line.startsWith('{')).at(-1);
  return { code: result.status, json: last ? JSON.parse(last) : null, stdout: result.stdout, stderr: result.stderr };
}

// The job: the image's command (--graph) and the environment infra/projection-renewal.bicep sets.
function jobRun(where, now, { fetch, env = {} } = {}) {
  return run(where, 'apply-projection.mjs', ['--graph'], {
    now,
    fetch,
    env: {
      COSMOS_ENDPOINT: ENDPOINT,
      PROJECTION_TENANT_ID: TENANT,
      PROJECTION_ACCOUNT_RESOURCE_ID: ACCOUNT,
      PROJECTION_IMAGE_DIGEST: DIGEST,
      PROJECTION_ENTRYPOINT: ENTRYPOINT,
      PROJECTION_STANDARD_GROUP_ID: STANDARD,
      PROJECTION_PREMIUM_GROUP_ID: PREMIUM,
      PROJECTION_GATEWAY_RESOURCE_ID: GATEWAY,
      AZURE_CLIENT_ID: '40000000-0000-4000-8000-000000000001',
      CONTAINER_APP_JOB_EXECUTION_NAME: `caj-projection-renewal-p94fixture-${randomUUID().slice(0, 8)}`,
      ...env,
    },
  });
}

// The runner's population: a snapshot resolved outside the network (scripts/Sync-ClaudeProjection.ps1).
function snapshotRun(where, now, records, { args = [], env = {} } = {}) {
  const verified = new Date(Date.parse(now) - 60 * 1000);
  const snapshot = {
    kind: 'claude-entitlement-snapshot',
    tenantId: TENANT,
    generatedAt: now,
    reconciliationGeneration: randomUUID(),
    lastVerifiedAt: verified.toISOString(),
    expiresAt: Math.floor(verified.getTime() / 1000) + 7200,
    mappingVersion: Math.floor(verified.getTime() / 1000),
    groups: { standard: 'claude-code-standard', premium: 'claude-code-premium', businessUnits: [] },
    records,
  };
  const path = join(where.dir, `snapshot-${randomUUID()}.json`);
  writeFileSync(path, JSON.stringify(snapshot));
  return run(where, 'apply-projection.mjs', ['--cosmos', ENDPOINT, '--tenant', TENANT, ...args, '--snapshot', path], { now, env });
}

function admission(where, now, args = []) {
  return run(where, 'check-admission.mjs', [
    '--cosmos', ENDPOINT, '--tenant', TENANT, '--account-resource-id', ACCOUNT, '--database', 'claude',
    '--container', 'entitlement', ...args,
  ], { now });
}

function records(where) {
  const docs = existsSync(where.store) ? Object.values(JSON.parse(readFileSync(where.store, 'utf8')).docs) : [];
  return Object.fromEntries(docs.filter((d) => d.type !== 'projection-reconciliation-status').map((d) => [d.oid, d]));
}

const SNAPSHOT_RECORDS = [
  { oid: USERS.ada, tier: 'standard', businessUnit: 'eng' },
  { oid: USERS.bo, tier: 'standard', businessUnit: 'eng' },
  { oid: USERS.build, tier: 'standard', businessUnit: '' },
  { oid: USERS.cy, tier: 'premium', businessUnit: 'fin' },
  { oid: USERS.di, tier: 'premium', businessUnit: '' },
];

test('runner snapshot apply requires an account resource id that matches the Cosmos endpoint for switch evidence', () => {
  const missing = scenario('missing account id');
  const refusedMissing = snapshotRun(missing, '2026-10-04T09:50:00.000Z', SNAPSHOT_RECORDS);
  assert.equal(refusedMissing.code, 1, refusedMissing.stdout + refusedMissing.stderr);
  assert.match(refusedMissing.json.error, /--account-resource-id is required/);
  assert.match(refusedMissing.json.error, /Remedy:/);

  const mismatch = scenario('mismatched account id');
  const wrongAccount = ACCOUNT.replace('cosmos-p94fixture', 'cosmos-other');
  const failed = snapshotRun(mismatch, '2026-10-04T09:50:00.000Z', SNAPSHOT_RECORDS, { args: ['--account-resource-id', wrongAccount] });
  assert.equal(failed.code, 1, failed.stdout + failed.stderr);
  assert.match(failed.json.error, /cosmos-other.*cosmos-p94fixture/);

  const envMismatch = scenario('env mismatched account id');
  const envFailed = snapshotRun(envMismatch, '2026-10-04T09:50:00.000Z', SNAPSHOT_RECORDS, {
    args: ['--account-resource-id', ACCOUNT],
    env: { PROJECTION_ACCOUNT_RESOURCE_ID: wrongAccount },
  });
  assert.equal(envFailed.code, 1, envFailed.stdout + envFailed.stderr);
  assert.match(envFailed.json.error, /differs from PROJECTION_ACCOUNT_RESOURCE_ID/);
});

test('a recent full runner snapshot with account evidence admits immediately and keeps records persistent', () => {
  const where = scenario('runner full sync evidence');
  const populated = snapshotRun(where, '2026-10-04T09:50:00.000Z', SNAPSHOT_RECORDS, { args: ['--account-resource-id', ACCOUNT] });
  assert.equal(populated.code, 0, populated.stdout + populated.stderr);
  const admitted = admission(where, '2026-10-04T11:01:00.000Z');
  assert.equal(admitted.code, 0, admitted.stdout + admitted.stderr);
  assert.equal(admitted.json.ok, true);
  assert.equal(admitted.json.newestFullSync.executor, 'runner');
  assert.equal(admitted.json.invalidCount, 0);
  for (const record of Object.values(records(where))) assert.equal('expiresAt' in record, false);
});

test('switch evidence is scoped to this account and only full syncs count', () => {
  const where = scenario('evidence scope');
  assert.equal(snapshotRun(where, '2026-10-04T09:50:00.000Z', SNAPSHOT_RECORDS, { args: ['--account-resource-id', ACCOUNT.toUpperCase()] }).code, 0);
  assert.equal(jobRun(where, '2026-10-04T10:00:00.000Z').code, 0);
  const status = JSON.parse(readFileSync(where.store, 'utf8'));
  const recorded = Object.values(status.docs).filter((d) => d.type === 'projection-reconciliation-status');
  assert.equal(recorded.length, 2, 'the runner and job each record status');
  assert.equal(recorded.every((d) => d.ttl === 604800), true, 'status records retain seven days');
  assert.equal(recorded.some((d) => d.mode === 'full' && d.executor === 'job' && d.accountResourceId.toLowerCase() === ACCOUNT.toLowerCase()), true);
  assert.equal(admission(where, '2026-10-04T11:01:00.000Z').json.ok, true);
  assert.match(readFileSync(join(where.dir, 'cosmos.log'), 'utf8'), new RegExp(`partition=projection-status::${TENANT}`), 'switch evidence reads statuses from the status partition only');
  const otherAccount = run(where, 'check-admission.mjs', ['--cosmos', ENDPOINT, '--tenant', TENANT, '--account-resource-id', ACCOUNT.replace('cosmos-p94fixture', 'cosmos-other')], { now: '2026-10-04T11:01:00.000Z' });
  assert.equal(otherAccount.code, 4, otherAccount.stdout + otherAccount.stderr);
  assert.match(otherAccount.json.reason, /full sync evidence/);
  for (const userStatus of Object.values(status.docs).filter((d) => d.type === 'projection-reconciliation-status')) {
    userStatus.mode = 'user';
  }
  writeFileSync(where.store, JSON.stringify(status));
  const userOnly = admission(where, '2026-10-04T11:01:00.000Z');
  assert.equal(userOnly.code, 4, userOnly.stdout + userOnly.stderr);
  assert.match(userOnly.json.reason, /full sync evidence/);
});

test('switch evidence uses max evidence age, not entry point or job receipt fields', () => {
  const where = scenario('evidence age');
  assert.equal(snapshotRun(where, '2026-10-04T09:50:00.000Z', SNAPSHOT_RECORDS, { args: ['--account-resource-id', ACCOUNT] }).code, 0);
  assert.equal(jobRun(where, '2026-10-04T10:00:00.000Z').code, 0);
  const current = admission(where, '2026-10-04T10:30:00.000Z', ['--max-evidence-age-seconds', '3600']);
  assert.equal(current.code, 0, current.stdout + current.stderr);
  const stale = admission(where, '2026-10-04T11:01:00.000Z', ['--max-evidence-age-seconds', '60']);
  assert.equal(stale.code, 4, stale.stdout + stale.stderr);
  assert.match(stale.json.reason, /full sync evidence/);
});

test('the job reads its tier groups from its environment and its units from the gateway', () => {
  const where = scenario('settings');
  const ran = jobRun(where, '2026-10-04T10:00:00.000Z');
  assert.equal(ran.code, 0, ran.stdout + ran.stderr);
  const now = records(where);
  assert.deepEqual(Object.keys(now).sort(), Object.values(USERS).sort());
  assert.equal(now[USERS.cy].tier, 'premium');
  assert.equal(now[USERS.build].tier, 'standard');
  assert.equal(now[USERS.ada].businessUnit, 'eng');
  assert.equal(now[USERS.bo].businessUnit, 'eng');
  assert.equal(now[USERS.cy].businessUnit, 'fin');
  assert.equal(now[USERS.di].businessUnit, '');
  const calls = readFileSync(where.log, 'utf8');
  assert.match(calls, /management\.azure\.com\/subscriptions\/[^\n]+\/namedValues\/bu-registry/);
  assert.match(calls, /management\.azure\.com\/subscriptions\/[^\n]+\/namedValues\/bu-parents/);
  assert.match(calls, new RegExp(`graph\\.microsoft\\.com/v1\\.0/groups/${STANDARD}/transitiveMembers`));
  assert.match(calls, new RegExp(`graph\\.microsoft\\.com/v1\\.0/groups/${PREMIUM}/transitiveMembers`));
  assert.doesNotMatch(calls, /claude-code-(standard|premium)/, 'tier groups given as object ids need no name lookup');
});

test('a business unit added at the gateway reaches the records on the next run, deepest unit first', () => {
  const where = scenario('registry change');
  assert.equal(jobRun(where, '2026-10-04T10:00:00.000Z').code, 0);
  assert.equal(records(where)[USERS.bo].businessUnit, 'eng');
  const changed = jobRun(where, '2026-10-04T10:30:00.000Z', { fetch: fixture({ registry: REGISTRY_TEAMS, parents: ',platform=eng,' }) });
  assert.equal(changed.code, 0, changed.stdout + changed.stderr);
  const after = records(where);
  assert.equal(after[USERS.bo].businessUnit, 'platform');
  assert.equal(after[USERS.ada].businessUnit, 'eng');
});

test('a Graph refusal writes no record and no status, and prints the failure event', () => {
  const where = scenario('graph denied');
  assert.equal(jobRun(where, '2026-10-04T10:00:00.000Z').code, 0);
  const before = readFileSync(where.store, 'utf8');
  const denied = jobRun(where, '2026-10-04T10:30:00.000Z', { fetch: fixture({ deny: [STANDARD] }) });
  assert.notEqual(denied.code, 0);
  assert.equal(denied.json.event, 'projection-renewal-failed');
  assert.equal(denied.json.stage, 'graph');
  assert.match(denied.json.error, /Authorization_RequestDenied/);
  assert.equal(readFileSync(where.store, 'utf8'), before);
});

test('an unreadable or secret registry writes nothing and reads no group', () => {
  for (const [name, fetch, reason] of [
    ['registry refused', fixture({ armStatus: 403 }), /403/],
    ['registry secret', fixture({ secretRegistry: true }), /secret/],
  ]) {
    const where = scenario(name);
    const failed = jobRun(where, '2026-10-04T10:00:00.000Z', { fetch });
    assert.notEqual(failed.code, 0, name);
    assert.equal(failed.json.event, 'projection-renewal-failed', name);
    assert.equal(failed.json.stage, 'business-units', name);
    assert.match(failed.json.error, reason, name);
    assert.equal(existsSync(where.store), false, `${name}: nothing was written`);
    assert.doesNotMatch(readFileSync(where.log, 'utf8'), /graph\.microsoft\.com/, `${name}: no group was read`);
  }
});

test('a unit whose group was deleted is an empty unit, as the PowerShell membership read treats it; a deleted tier group stops the run', () => {
  const gone = '20000000-0000-4000-8000-0000000000ff';
  const where = scenario('unit group deleted');
  const ran = jobRun(where, '2026-10-04T10:00:00.000Z', { fetch: fixture({ registry: `,gone=${gone}:1000,eng=Claude Engineering:1000,`, missing: [gone] }) });
  assert.equal(ran.code, 0, ran.stdout + ran.stderr);
  assert.equal(ran.json.event, 'projection-renewal-succeeded');
  assert.match(ran.stdout + ran.stderr, new RegExp(`warning: unit 'gone' group '${gone}' was not found - treating it as empty`));
  assert.equal(records(where)[USERS.ada].businessUnit, 'eng');
  const tier = scenario('tier group deleted');
  const failed = jobRun(tier, '2026-10-04T10:00:00.000Z', { fetch: fixture({ missing: [STANDARD] }) });
  assert.notEqual(failed.code, 0);
  assert.equal(failed.json.event, 'projection-renewal-failed');
  assert.equal(failed.json.stage, 'graph');
  assert.match(failed.json.error, /Request_ResourceNotFound/);
  assert.equal(existsSync(tier.store), false, 'nothing was written');
});

test('a job with no premium group projects the standard tier only', () => {
  const where = scenario('no premium');
  const ran = jobRun(where, '2026-10-04T10:00:00.000Z', { env: { PROJECTION_PREMIUM_GROUP_ID: 'none' } });
  assert.equal(ran.code, 0, ran.stdout + ran.stderr);
  const now = records(where);
  assert.deepEqual(Object.values(now).map((r) => r.tier).sort(), ['standard', 'standard', 'standard']);
  assert.doesNotMatch(readFileSync(where.log, 'utf8'), /claude-code-premium|10000000-0000-4000-8000-000000000002/);
});

test('a job whose group settings are missing or malformed writes nothing', () => {
  for (const [name, env] of [
    ['premium missing', { PROJECTION_PREMIUM_GROUP_ID: undefined }],
    ['premium empty', { PROJECTION_PREMIUM_GROUP_ID: '' }],
    ['standard malformed', { PROJECTION_STANDARD_GROUP_ID: 'claude-code-standard' }],
    ['premium malformed', { PROJECTION_PREMIUM_GROUP_ID: "x' or 1 eq 1" }],
  ]) {
    const where = scenario(name);
    const failed = jobRun(where, '2026-10-04T10:00:00.000Z', { env });
    assert.notEqual(failed.code, 0, name);
    assert.equal(failed.json.event, 'projection-renewal-failed', name);
    assert.equal(failed.json.stage, 'config', name);
    assert.equal(existsSync(where.store), false, `${name}: nothing was written`);
    assert.equal(existsSync(where.log), false, `${name}: nothing was read`);
  }
});

test('a targeted snapshot writes a user-mode status and does not replace full-sync switch evidence', () => {
  const where = scenario('targeted after full');
  assert.equal(jobRun(where, '2026-10-04T10:00:00.000Z').code, 0);
  assert.equal(admission(where, '2026-10-04T11:01:00.000Z').code, 0);
  const target = USERS.ada;
  const verified = new Date(Date.parse('2026-10-04T11:02:00.000Z') - 60 * 1000);
  const snapshot = {
    kind: 'claude-entitlement-snapshot', tenantId: TENANT, generatedAt: '2026-10-04T11:02:00.000Z',
    reconciliationGeneration: randomUUID(), lastVerifiedAt: verified.toISOString(),
    expiresAt: Math.floor(verified.getTime() / 1000) + 7200, mappingVersion: Math.floor(verified.getTime() / 1000),
    scope: 'user', user: target, records: [{ oid: target, tier: 'premium', businessUnit: 'eng' }],
  };
  const path = join(where.dir, 'targeted.json');
  writeFileSync(path, JSON.stringify(snapshot));
  const targeted = run(where, 'apply-projection.mjs', ['--cosmos', ENDPOINT, '--tenant', TENANT, '--account-resource-id', ACCOUNT, '--snapshot', path, '--user', target], { now: '2026-10-04T11:02:00.000Z' });
  assert.equal(targeted.code, 0, targeted.stdout + targeted.stderr);
  assert.equal(targeted.json.mode, 'user');
  const admitted = admission(where, '2026-10-04T11:03:00.000Z');
  assert.equal(admitted.code, 0, admitted.stdout + admitted.stderr);
  assert.equal(admitted.json.newestFullSync.executor, 'job');
});

test('a targeted snapshot point-reads and writes only the target user', () => {
  const where = scenario('targeted point read');
  assert.equal(snapshotRun(where, '2026-10-04T10:00:00.000Z', SNAPSHOT_RECORDS, { args: ['--account-resource-id', ACCOUNT] }).code, 0);
  const before = records(where);
  const target = USERS.ada;
  const other = USERS.bo;
  const verified = new Date(Date.parse('2026-10-04T10:10:00.000Z') - 60 * 1000);
  const snapshot = {
    kind: 'claude-entitlement-snapshot', tenantId: TENANT, generatedAt: '2026-10-04T10:10:00.000Z',
    reconciliationGeneration: randomUUID(), lastVerifiedAt: verified.toISOString(),
    expiresAt: Math.floor(verified.getTime() / 1000) + 7200, mappingVersion: Math.floor(verified.getTime() / 1000),
    scope: 'user', user: target, records: [{ oid: target, tier: 'premium', businessUnit: 'eng' }],
  };
  const path = join(where.dir, 'target-only.json');
  writeFileSync(path, JSON.stringify(snapshot));
  writeFileSync(join(where.dir, 'cosmos.log'), '');
  const applied = run(where, 'apply-projection.mjs', ['--cosmos', ENDPOINT, '--tenant', TENANT, '--account-resource-id', ACCOUNT, '--snapshot', path, '--user', target], { now: '2026-10-04T10:10:00.000Z' });
  assert.equal(applied.code, 0, applied.stdout + applied.stderr);
  const logText = readFileSync(join(where.dir, 'cosmos.log'), 'utf8');
  assert.match(logText, new RegExp(`point-read ${target}\\|${target}`));
  assert.doesNotMatch(logText, /WHERE NOT IS_DEFINED\(c\.type\)/);
  assert.doesNotMatch(logText, new RegExp(`bulk (Upsert|Delete) ${other}`));
  const after = records(where);
  assert.equal(after[target].tier, 'premium');
  assert.deepEqual(after[other], before[other]);
});

test("the optional job's alerts match event lines and do not require expiry-margin evidence", () => {
  const bicep = readFileSync(join(process.env.PROJECTION_REPO, 'infra', 'projection-renewal.bicep'), 'utf8');
  const events = [...bicep.matchAll(/'"event":"([a-z-]+)"'/g)].map((m) => m[1]);
  assert.deepEqual([...new Set(events)].sort(), ['projection-renewal-failed', 'projection-renewal-succeeded']);
  assert.doesNotMatch(bicep, /oldestExpiresAt|expiry-margin|expiresAt/);

  const where = scenario('alert contract');
  const ok = jobRun(where, '2026-10-04T10:00:00.000Z');
  const okLine = ok.stdout.split(/\r?\n/).filter((line) => line.startsWith('{')).at(-1);
  assert.ok(okLine.includes('"event":"projection-renewal-succeeded"'), okLine);
  assert.equal(ok.json.executor, 'job');
  assert.equal('oldestExpiresAt' in ok.json, false);

  const denied = jobRun(where, '2026-10-04T10:30:00.000Z', { fetch: fixture({ deny: [PREMIUM] }) });
  const deniedLine = denied.stdout.split(/\r?\n/).filter((line) => line.startsWith('{')).at(-1);
  assert.ok(deniedLine.includes('"event":"projection-renewal-failed"'), deniedLine);
  assert.ok(!deniedLine.includes('"event":"projection-renewal-succeeded"'), deniedLine);
});
