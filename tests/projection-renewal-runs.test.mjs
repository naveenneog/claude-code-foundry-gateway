// The projection renewal job, run as the scheduled job runs it (image command `--graph`, settings
// from the job's environment), against stand-in Graph, ARM and Cosmos and a controlled clock.
// Started by tests/Test-ProjectionRenewalRuns.ps1, which stages the sync package with the
// stand-in Azure SDK modules and passes PROJECTION_PACKAGE and PROJECTION_FAKES.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { randomUUID } from 'node:crypto';

const pkg = process.env.PROJECTION_PACKAGE;
const preload = pathToFileURL(join(process.env.PROJECTION_FAKES, 'preload.mjs')).href;
const work = mkdtempSync(join(tmpdir(), 'projection-runs-'));
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

function fixture({ registry = REGISTRY_UNITS, parents = ',,', deny = [], armStatus = 200, secretRegistry = false } = {}) {
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
  const childEnv = { ...cleanEnvironment(), FAKE_NOW: now, FAKE_COSMOS_STORE: where.store, FAKE_FETCH_FIXTURE: fixturePath, FAKE_FETCH_LOG: where.log, ...env };
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
function snapshotRun(where, now, records) {
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
  return run(where, 'apply-projection.mjs', ['--cosmos', ENDPOINT, '--tenant', TENANT, '--snapshot', path], { now });
}

function admission(where, now) {
  return run(where, 'check-admission.mjs', [
    '--cosmos', ENDPOINT, '--tenant', TENANT, '--account-resource-id', ACCOUNT, '--database', 'claude',
    '--container', 'entitlement', '--image-digest', DIGEST, '--entrypoint', ENTRYPOINT, '--action-group-resource-id', ACTION_GROUP,
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

test('a snapshot population and three scheduled runs pass admission; two runs do not', () => {
  const where = scenario('three runs');
  const populated = snapshotRun(where, '2026-10-04T09:50:00.000Z', SNAPSHOT_RECORDS);
  assert.equal(populated.code, 0, populated.stdout + populated.stderr);
  for (const now of ['2026-10-04T10:00:00.000Z', '2026-10-04T10:30:00.000Z']) {
    const ran = jobRun(where, now);
    assert.equal(ran.code, 0, ran.stdout + ran.stderr);
    assert.equal(ran.json.event, 'projection-renewal-succeeded');
  }
  const early = admission(where, '2026-10-04T10:31:00.000Z');
  assert.equal(early.code, 4, early.stdout + early.stderr);
  assert.match(early.json.reason, /advanced at least twice/);

  const third = jobRun(where, '2026-10-04T11:00:00.000Z');
  assert.equal(third.code, 0, third.stdout + third.stderr);
  assert.equal(third.json.event, 'projection-renewal-succeeded');
  assert.equal(third.json.oldestExpiresAt, Math.floor(Date.parse('2026-10-04T11:00:00.000Z') / 1000) + 7200);
  const admitted = admission(where, '2026-10-04T11:01:00.000Z');
  assert.equal(admitted.code, 0, admitted.stdout + admitted.stderr);
  assert.equal(admitted.json.ok, true);
  assert.equal(admitted.json.generations, 3);
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

test('a snapshot applied after scheduled runs leaves admission refusing until the next run', () => {
  const where = scenario('snapshot after runs');
  for (const now of ['2026-10-04T10:00:00.000Z', '2026-10-04T10:30:00.000Z', '2026-10-04T11:00:00.000Z']) {
    assert.equal(jobRun(where, now).code, 0);
  }
  assert.equal(admission(where, '2026-10-04T11:01:00.000Z').code, 0);
  assert.equal(snapshotRun(where, '2026-10-04T11:02:00.000Z', SNAPSHOT_RECORDS).code, 0);
  const refused = admission(where, '2026-10-04T11:03:00.000Z');
  assert.equal(refused.code, 4, refused.stdout + refused.stderr);
  assert.match(refused.json.reason, /older generation/);
});

// The alerts in infra/projection-renewal.bicep search the job's console lines for quoted event
// strings and read the expiry with a regular expression; both are checked against real lines here.
test("the alert queries match the job's own last lines", () => {
  const bicep = readFileSync(join(process.env.PROJECTION_REPO, 'infra', 'projection-renewal.bicep'), 'utf8');
  const events = [...bicep.matchAll(/'"event":"([a-z-]+)"'/g)].map((m) => m[1]);
  assert.deepEqual([...new Set(events)].sort(), ['projection-renewal-failed', 'projection-renewal-succeeded']);
  const pattern = /extract\('(.+?)', 1, Log\)/.exec(bicep)?.[1];
  assert.ok(pattern, 'the expiry rule extracts the expiry from the line');

  const where = scenario('alert contract');
  const ok = jobRun(where, '2026-10-04T10:00:00.000Z');
  const okLine = ok.stdout.split(/\r?\n/).filter((line) => line.startsWith('{')).at(-1);
  assert.ok(okLine.includes('"event":"projection-renewal-succeeded"'), okLine);
  assert.equal(Number(new RegExp(pattern).exec(okLine)?.[1]), ok.json.oldestExpiresAt);

  const denied = jobRun(where, '2026-10-04T10:30:00.000Z', { fetch: fixture({ deny: [PREMIUM] }) });
  const deniedLine = denied.stdout.split(/\r?\n/).filter((line) => line.startsWith('{')).at(-1);
  assert.ok(deniedLine.includes('"event":"projection-renewal-failed"'), deniedLine);
  assert.ok(!deniedLine.includes('"event":"projection-renewal-succeeded"'), deniedLine);
});
