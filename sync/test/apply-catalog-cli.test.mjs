import { after, test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { prepareAccessCatalogDocument } from '../src/access-catalog-administration.mjs';
import { canonicalizeAccessCatalog } from '../src/access-catalog.mjs';

const script = fileURLToPath(new URL('../src/apply-projection.mjs', import.meta.url));
const loaderUrl = pathToFileURL(fileURLToPath(new URL('./fake-azure-loader.mjs', import.meta.url))).href;
const graphPreloadUrl = pathToFileURL(fileURLToPath(new URL('./fake-graph-preload.mjs', import.meta.url))).href;
const tenant = '22222222-2222-4222-8222-222222222222';
const account = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg/providers/Microsoft.DocumentDB/databaseAccounts/cosmos';
const cosmos = 'https://cosmos.documents.azure.com:443/';
const catalogKey = `access-catalog::${tenant}`;
const work = mkdtempSync(join(tmpdir(), 'apply-catalog-cli-'));
after(() => rmSync(work, { recursive: true, force: true }));

function guid(number) {
  return `aaaaaaaa-bbbb-4ccc-8ddd-${number.toString(16).padStart(12, '0')}`;
}

function makeCatalog() {
  const plans = Array.from({ length: 9 }, (_, index) => ({
    id: `plan-${index + 1}`,
    name: `Plan ${index + 1}`,
    enabled: true,
    nominalCredit: { amount: (index + 1) * 10, currency: 'USD', period: 'month', scope: 'user' },
    compatibilityTier: index % 2 === 0 ? 'standard' : 'premium',
  }));
  const profiles = Array.from({ length: 47 }, (_, index) => ({
    id: `profile-${index + 1}`,
    name: `Profile ${index + 1}`,
    planId: plans[index % plans.length].id,
    groupObjectId: guid(index + 1),
    priority: index + 1,
    capabilities: index === 46 ? ['design'] : ['code'],
    modelFamilies: index === 46 ? ['opus'] : ['haiku'],
    connectors: index === 46 ? ['m365'] : [],
    enabled: true,
  }));
  return { schemaVersion: 1, tenantId: tenant, plans, profiles };
}

function runCatalog({ name, catalog = makeCatalog(), memberships, absentGroup = '', args = [] }) {
  const storePath = join(work, `${name}-store.json`);
  const logPath = join(work, `${name}-cosmos.log`);
  const catalogDocument = prepareAccessCatalogDocument(catalog, { tenantId: tenant });
  writeFileSync(storePath, JSON.stringify({ docs: { [`${catalogKey}|${catalogKey}`]: catalogDocument } }));
  writeFileSync(logPath, '');
  const result = spawnSync(process.execPath, [
    '--import', graphPreloadUrl,
    '--loader', loaderUrl,
    script,
    '--cosmos', cosmos,
    '--tenant', tenant,
    '--account-resource-id', account,
    '--graph',
    '--standard', guid(60),
    '--premium', 'none',
    ...args,
  ], {
    encoding: 'utf8',
    env: {
      ...process.env,
      FAKE_COSMOS_STORE: storePath,
      FAKE_COSMOS_LOG: logPath,
      FAKE_GRAPH_GROUP_MEMBERS: JSON.stringify(memberships),
      FAKE_GRAPH_ABSENT_GROUP: absentGroup,
      PROJECTION_ACCOUNT_RESOURCE_ID: '',
      PROJECTION_STANDARD_GROUP_ID: '',
      PROJECTION_PREMIUM_GROUP_ID: '',
      PROJECTION_GATEWAY_RESOURCE_ID: '',
    },
  });
  const jsonLine = result.stdout.trim().split(/\r?\n/).filter((line) => line.startsWith('{')).at(-1);
  return {
    result,
    summary: JSON.parse(jsonLine),
    store: JSON.parse(readFileSync(storePath, 'utf8')),
    log: readFileSync(logPath, 'utf8'),
  };
}

function runCatalogRead({ name, document }) {
  const storePath = join(work, `${name}-store.json`);
  const logPath = join(work, `${name}-cosmos.log`);
  writeFileSync(storePath, JSON.stringify({
    docs: document ? { [`${catalogKey}|${catalogKey}`]: document } : {},
  }));
  writeFileSync(logPath, '');
  const result = spawnSync(process.execPath, [
    '--loader', loaderUrl,
    script,
    '--cosmos', cosmos,
    '--tenant', tenant,
    '--read-access-catalog',
  ], {
    encoding: 'utf8',
    env: {
      ...process.env,
      FAKE_COSMOS_STORE: storePath,
      FAKE_COSMOS_LOG: logPath,
      PROJECTION_ACCOUNT_RESOURCE_ID: '',
    },
  });
  const jsonLine = result.stdout.trim().split(/\r?\n/).filter((line) => line.startsWith('{')).at(-1);
  return {
    result,
    summary: JSON.parse(jsonLine),
    log: readFileSync(logPath, 'utf8'),
  };
}

test('catalog discovery is one read-only point read and returns the validated non-secret catalog', () => {
  const catalog = makeCatalog();
  const document = prepareAccessCatalogDocument(catalog, { tenantId: tenant });
  const found = runCatalogRead({ name: 'read-published-catalog', document });
  assert.equal(found.result.status, 0, found.result.stdout + found.result.stderr);
  assert.equal(found.summary.mode, 'access-catalog');
  assert.equal(found.summary.found, true);
  assert.deepEqual(found.summary.catalog, canonicalizeAccessCatalog(catalog));
  assert.match(found.log, new RegExp(`^point-read ${catalogKey}\\|${catalogKey}`, 'm'));
  assert.doesNotMatch(found.log, /query |bulk |create |replace |delete /);

  const missing = runCatalogRead({ name: 'read-missing-catalog', document: null });
  assert.equal(missing.result.status, 0, missing.result.stdout + missing.result.stderr);
  assert.deepEqual(missing.summary, {
    ok: true,
    mode: 'access-catalog',
    found: false,
    catalog: null,
  });
});

test('catalog graph mode point-reads nine plans and 47 profiles and writes one whole highest-priority profile', () => {
  const catalog = makeCatalog();
  const user = '33333333-3333-4333-8333-333333333333';
  const memberships = Object.fromEntries(catalog.profiles.map((profile) => [profile.groupObjectId, []]));
  memberships[catalog.profiles[0].groupObjectId] = [user];
  memberships[catalog.profiles[46].groupObjectId] = [user];

  const { result, summary, store, log } = runCatalog({ name: 'nine-plans-47-profiles', catalog, memberships });

  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.equal(summary.resolved, 1);
  assert.match(log, new RegExp(`point-read ${catalogKey.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\|${catalogKey.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}`));
  const graphReads = log.split(/\r?\n/).filter((line) => line.startsWith('graph-members '));
  assert.equal(graphReads.length, 94, 'each of 47 groups is read for users and service principals');
  assert.equal(new Set(graphReads.map((line) => line.split(' ')[1])).size, 47);
  const record = store.docs[`${user}|${user}`];
  assert.deepEqual({
    schemaVersion: record.schemaVersion,
    tier: record.tier,
    planId: record.planId,
    profileId: record.profileId,
    capabilities: record.capabilities,
    modelFamilies: record.modelFamilies,
    connectors: record.connectors,
    businessUnit: record.businessUnit,
  }, {
    schemaVersion: 3,
    tier: 'premium',
    planId: 'plan-2',
    profileId: 'profile-47',
    capabilities: ['design'],
    modelFamilies: ['opus'],
    connectors: ['m365'],
    businessUnit: '',
  });
  assert.match(record.catalogVersion, /^sha256:[0-9a-f]{64}$/);
  assert.match(record.profileHash, /^sha256:[0-9a-f]{64}$/);
});

test('an absent configured catalog access group fails before any entitlement or status write', () => {
  const catalog = makeCatalog();
  const absentGroup = catalog.profiles[23].groupObjectId;
  const memberships = Object.fromEntries(catalog.profiles.map((profile) => [profile.groupObjectId, []]));

  const { result, summary, store, log } = runCatalog({
    name: 'absent-strict-group',
    catalog,
    memberships,
    absentGroup,
  });

  assert.equal(result.status, 3, result.stdout + result.stderr);
  assert.equal(summary.stage, 'graph');
  assert.match(summary.error, new RegExp(absentGroup));
  assert.match(summary.error, /configured access group.*absent|absent configured access group/i);
  assert.doesNotMatch(log, /bulk (Upsert|Delete)/);
  assert.equal(Object.values(store.docs).some((doc) => doc.type === 'projection-reconciliation-status'), false);
});

test('a catalog run prints chargeback membership for every unit member, including one without a profile (ADR-0066)', () => {
  const unitGroup = guid(70);
  const holder = guid(101);
  const noProfile = guid(102);
  const { result, summary } = runCatalog({
    name: 'catalog-membership',
    memberships: { [guid(1)]: [holder], [unitGroup]: [holder, noProfile] },
    args: ['--bu', `eng=${unitGroup}`],
  });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.equal(summary.membershipPrinted, true);
  const lines = result.stdout.split(/\r?\n/).filter((line) => line.includes('"event":"projection-membership"')).map((line) => JSON.parse(line));
  assert.equal(lines.length, 1);
  assert.deepEqual(lines[0].rows, [[holder, 'eng', ''], [noProfile, 'eng', '']]);
  const lastLine = result.stdout.trim().split(/\r?\n/).at(-1);
  assert.equal(JSON.parse(lastLine).membershipPrinted, true, 'the summary stays last');
});