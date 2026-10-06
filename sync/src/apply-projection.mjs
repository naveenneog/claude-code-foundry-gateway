#!/usr/bin/env node
/**
 * Applies entitlement to the projection from inside the network.
 *
 * The projection's Cosmos account has no public endpoint, so whatever writes it
 * runs where the private endpoint is: a job in the VNet, or a machine on a
 * network that reaches it. That job authenticates as its own managed identity,
 * which holds Cosmos DB Built-in Data Contributor on this one container and
 * nothing else. The resolver has a different identity with read only, so a
 * compromised resolver cannot change who is entitled.
 *
 * Two ways to get the membership:
 *
 *   --snapshot <file>  resolved outside by
 *                      `Sync-ClaudeProjection.ps1 -ExportPath <file>`, where the
 *                      operator's own sign-in reads Graph. No credential enters
 *                      the network - only object ids and tiers.
 *   --graph            read Graph here with this job's identity. Needs the
 *                      Microsoft Graph application permission
 *                      GroupMember.Read.All, granted once by a tenant
 *                      administrator. The enterprise default for a scheduled
 *                      sync; not available to an operator without that consent.
 *
 * As the scheduled job (infra/projection-renewal.bicep), the image runs --graph
 * and reads PROJECTION_STANDARD_GROUP_ID and PROJECTION_PREMIUM_GROUP_ID (object
 * ids; the premium one may be `none`) and PROJECTION_GATEWAY_RESOURCE_ID, whose
 * bu-registry and bu-parents give the business units on every run (ADR-0049).
 * Its last line carries an event that the renewal alerts match.
 *
 * Usage:
 *   node src/apply-projection.mjs --cosmos https://<acct>.documents.azure.com:443/
 *        --tenant <guid> (--snapshot file | --graph --standard g --premium g [--bu id=g ...])
 *        [--whatif] [--allow-empty] [--keep-orphans]
 */
import { readFileSync } from 'node:fs';
import { mergeMembership, planChanges, toDocument, toStatusDocument, validateSnapshot, validateTargetedSnapshot, compareWithGateway, compareWithSnapshot, createReconciliation, normalizeJobSettings, validateJobSettings } from './plan.mjs';
import { acquireApplyLock, validateLockWait } from './apply-lock.mjs';
import { resolveGroupId, getTransitiveMembers } from './graph.mjs';
import { readGatewayUnits, sortUnitsByDepth } from './business-units.mjs';
import { RENEWAL_SUCCEEDED, RENEWAL_FAILED } from './events.mjs';

const argv = process.argv.slice(2);
const flag = (n) => argv.includes(n);
const opt = (n, d) => { const i = argv.indexOf(n); return i >= 0 && argv[i + 1] ? argv[i + 1] : d; };
const opts = (n) => argv.flatMap((a, i) => (a === n && argv[i + 1] ? [argv[i + 1]] : []));

const endpoint = opt('--cosmos', process.env.COSMOS_ENDPOINT);
const databaseName = opt('--database', 'claude');
const containerName = opt('--container', 'entitlement');
const tenantId = opt('--tenant', process.env.PROJECTION_TENANT_ID);
const accountResourceIdFlag = opt('--account-resource-id');
const whatIf = flag('--whatif');
const renewal = flag('--graph');
const userOid = opt('--user');
const compareMode = Boolean(opt('--compare') || opt('--compare-snapshot'));
const mutatingApply = !whatIf && !compareMode;
const lockWaitSeconds = Number(opt('--lock-wait-seconds', '900'));
const GUID = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
const COSMOS_ACCOUNT_RESOURCE_ID = /^\/subscriptions\/([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\/resourceGroups\/([^/]+)\/providers\/Microsoft\.DocumentDB\/databaseAccounts\/([^/]+)$/i;
const log = (m) => console.log(m);
const rerunRemedy = 'Remedy: rerun scripts/Sync-ClaudeAccess.ps1 -ResourceGroup <rg> -ApimName <apim> (or start the sync job again), then rerun the switch if one was in progress.';
const userRerunRemedy = 'Remedy: rerun scripts/Sync-ClaudeAccess.ps1 -ResourceGroup <rg> -ApimName <apim> -User <upn-or-oid>.';
const accountRemedy = 'Remedy: rerun scripts/Sync-ClaudeAccess.ps1 -ResourceGroup <rg> -ApimName <apim>, or rerun with a matching --cosmos https://<account>.documents.azure.com:443/ --account-resource-id $(az cosmosdb show -n <account> -g <rg> --query id -o tsv).';

function fail(message, code = 1, stage = 'config') {
  console.log(JSON.stringify({ ok: false, error: message, stage, ...(renewal ? { event: RENEWAL_FAILED } : {}) }));
  process.exit(code);
}

let activeLockForFailure = null;
async function releaseActiveLock() {
  if (!activeLockForFailure) return;
  const lock = activeLockForFailure;
  activeLockForFailure = null;
  try {
    await lock.release();
  } catch (error) {
    console.log(JSON.stringify({ ok: false, warning: `projection apply lock release failed: ${error?.message ?? error}` }));
  }
}

// One stage of a run. An error ends the run with the stage named, before anything after it is written.
async function step(stage, work) {
  try {
    return await work();
  } catch (error) {
    await releaseActiveLock();
    const failureStage = error?.stage ?? stage;
    return fail(`${failureStage} failed: ${error?.message ?? error}`, 3, failureStage);
  }
}

if (!endpoint) fail('--cosmos is required');
if (!tenantId) fail('--tenant is required: every record is stamped with it and the resolver refuses another');
try { validateLockWait(lockWaitSeconds); } catch (error) { fail(error.message, 1, 'config'); }
const standardOverride = opt('--standard');
const premiumOverride = opt('--premium');
if (renewal && Boolean(standardOverride) !== Boolean(premiumOverride)) {
  fail('partial tier override refused for --graph. Remedy: rerun with both --graph --standard <group-object-id> --premium <group-object-id-or-none>, or omit both tier overrides so the deployed job settings are used.', 1, 'config');
}
const jobSettingsRun = renewal && !standardOverride && !premiumOverride;
const accountResourceId = resolveAccountResourceId({ endpoint, flagValue: accountResourceIdFlag, envValue: process.env.PROJECTION_ACCOUNT_RESOURCE_ID, required: mutatingApply && !jobSettingsRun });
if (jobSettingsRun) {
  const problems = validateJobSettings(process.env);
  if (problems.length) fail(`job settings refused: ${problems.join('; ')}`, 1, 'config');
}

const { DefaultAzureCredential } = await import('@azure/identity');
const { CosmosClient } = await import('@azure/cosmos');
const credential = new DefaultAzureCredential();

// Tier groups: --standard/--premium for a manual graph run, else the job's PROJECTION_*_GROUP_ID
// settings (object ids, checked here before any read).
function tierGroups() {
  const fromJob = ['STANDARD', 'PREMIUM'].some((tier) => process.env[`PROJECTION_${tier}_GROUP_ID`] !== undefined);
  const standard = opt('--standard', fromJob ? process.env.PROJECTION_STANDARD_GROUP_ID : '');
  const premium = opt('--premium', fromJob ? process.env.PROJECTION_PREMIUM_GROUP_ID : '');
  if (fromJob && !opt('--standard') && !GUID.test(standard ?? '')) fail('PROJECTION_STANDARD_GROUP_ID must be the standard tier group object id');
  if (fromJob && !opt('--premium') && premium !== 'none' && !GUID.test(premium ?? '')) fail('PROJECTION_PREMIUM_GROUP_ID must be the premium tier group object id, or none');
  return { premium: premium === 'none' ? '' : premium, standard };
}

// Business units: --bu id=group in precedence order, else the gateway's bu-registry and bu-parents,
// read on this run and ordered deepest first as scripts/ClaudeBusinessUnit.ps1 orders them.
async function unitGroups() {
  const given = opts('--bu').map((spec) => { const [id, group] = spec.split('='); return { id, group }; });
  if (given.length || !process.env.PROJECTION_GATEWAY_RESOURCE_ID) return given;
  const token = (await credential.getToken('https://management.azure.com/.default')).token;
  const { registry, parents } = await readGatewayUnits(process.env.PROJECTION_GATEWAY_RESOURCE_ID, token);
  const ordered = sortUnitsByDepth(registry, parents);
  log(`units     ${ordered.length} from the gateway's bu-registry`);
  return ordered.map((u) => ({ id: u.id, group: u.group }));
}

async function resolveMembership() {
  if (opt('--snapshot')) {
    const snap = JSON.parse(readFileSync(opt('--snapshot'), 'utf8').replace(/^\uFEFF/, ''));
    const problems = userOid
      ? validateTargetedSnapshot(snap, userOid, { tenantId })
      : validateSnapshot(snap, { tenantId });
    if (!userOid && snap.scope === 'user') problems.push('pass --user <oid> to apply a targeted snapshot');
    if (problems.length) fail(`snapshot refused: ${problems.join('; ')}`);
    return { records: snap.records, mappingVersion: snap.mappingVersion, source: `snapshot ${snap.generatedAt}`,
      scope: userOid ? 'user' : 'full',
      reconciliation: { reconciliationGeneration: snap.reconciliationGeneration, lastVerifiedAt: snap.lastVerifiedAt, expiresAt: snap.expiresAt } };
  }
  if (userOid) fail('--user can only be used with --snapshot <file>');
  if (!flag('--graph')) fail('pass --snapshot <file> or --graph');
  const groups = tierGroups();
  const verifiedAt = new Date();
  const units = await step('business-units', unitGroups);
  const token = await step('graph', async () => (await credential.getToken('https://graph.microsoft.com/.default')).token);
  const tiers = {};
  await step('graph', async () => {
    for (const tier of ['premium', 'standard']) {
      const group = groups[tier];
      if (!group) { log(`${tier.padEnd(9)} no group configured - treated as empty`); tiers[tier] = []; continue; }
      const id = await resolveGroupId(group, token);
      if (!id) { log(`warning: group '${group}' not found - treating as empty`); tiers[tier] = []; continue; }
      tiers[tier] = await getTransitiveMembers(id, token);
      log(`${tier.padEnd(9)} ${group}  ${tiers[tier].length} member(s)`);
    }
  });
  const businessUnits = [];
  await step('graph', async () => {
    for (const { id: unit, group } of units) {
      const id = await resolveGroupId(group, token);
      let members = null;
      if (id) {
        try {
          members = await getTransitiveMembers(id, token);
        } catch (error) {
          // A deleted unit group is an empty unit, as Get-GroupMemberOids in
          // scripts/ClaudeGraphMembership.ps1 treats it, so one stale registry entry cannot stop every
          // renewal. Tier groups above stay strict.
          if (error?.status !== 404) throw error;
        }
      }
      if (!members) log(`warning: unit '${unit}' group '${group}' was not found - treating it as empty`);
      businessUnits.push({ id: unit, members: members ?? [] });
    }
  });
  const { records, unitWithoutTier } = mergeMembership({ tiers, businessUnits });
  for (const u of unitWithoutTier.slice(0, 10)) log(`note: ${u.oid} is in ${u.unit} but holds no tier - not projected`);
  const reconciliation = await step('lease', async () => createReconciliation({ verifiedAt, maxAgeSeconds: Number(opt('--max-age-seconds', 7200)) }));
  return { records, mappingVersion: Math.floor(Date.now() / 1000), source: 'graph', reconciliation };
}

async function readExisting(container) {
  const existing = new Map();
  const iterator = container.items.query("SELECT c.id, c.tier, c.businessUnit, c.expiresAt FROM c WHERE NOT IS_DEFINED(c.type)", { maxItemCount: 1000 });
  while (iterator.hasMoreResults()) {
    const { resources } = await iterator.fetchNext();
    for (const d of resources ?? []) {
      const current = { tier: d.tier, businessUnit: d.businessUnit ?? '' };
      if (Object.hasOwn(d, 'expiresAt')) current.expiresAt = d.expiresAt;
      existing.set(d.id, current);
    }
  }
  return existing;
}

async function readExistingUser(container, oid) {
  const existing = new Map();
  let resource = null;
  try {
    ({ resource } = await container.item(oid, oid).read());
  } catch (error) {
    if (error?.code !== 404 && error?.statusCode !== 404) throw error;
  }
  if (resource && !resource.type) {
    const current = { tier: resource.tier, businessUnit: resource.businessUnit ?? '' };
    if (Object.hasOwn(resource, 'expiresAt')) current.expiresAt = resource.expiresAt;
    existing.set(resource.id, current);
  }
  return existing;
}

async function readSuccessfulStatuses(container) {
  const query = {
    query: "SELECT c.id, c.oid, c.type, c.tenantId, c.accountResourceId, c.databaseName, c.containerName, c.ok, c.mode, c.user, c.finishedAt FROM c WHERE c.type = 'projection-reconciliation-status' AND c.tenantId = @tenantId",
    parameters: [
      { name: '@tenantId', value: tenantId },
    ],
  };
  const statuses = [];
  const iterator = container.items.query(query, { maxItemCount: 1000 });
  while (iterator.hasMoreResults()) {
    const { resources } = await iterator.fetchNext();
    statuses.push(...(resources ?? []));
  }
  return statuses.filter((s) => s.ok === true);
}

async function bulk(container, operations, lock) {
  let ok = 0, failed = 0;
  for (let i = 0; i < operations.length; i += 1000) {
    if (lock) await lock.renewIfNeeded();
    const results = await container.items.executeBulkOperations(operations.slice(i, i + 1000));
    for (const r of results) {
      const status = r.response?.statusCode ?? r.statusCode;
      if (status >= 200 && status < 300) ok++; else failed++;
    }
  }
  return { ok, failed };
}

const started = Date.now();
const containerRef = () => new CosmosClient({ endpoint, aadCredentials: credential }).database(databaseName).container(containerName);

// --compare <gateway-decisions.json>: read-only. What each identity would
// experience at the flip, from the records the resolver would actually serve.
if (opt('--compare')) {
  const gw = JSON.parse(readFileSync(opt('--compare'), 'utf8').replace(/^\uFEFF/, ''));
  if (gw.kind !== 'claude-gateway-decisions') fail("--compare expects a file written by Compare-ClaudeEntitlement.ps1 -ExportGatewayPath");
  const records = [];
  const it = containerRef().items.query('SELECT c.id, c.oid, c.tier, c.businessUnit, c.tenantId, c.reconciliationGeneration, c.lastVerifiedAt, c.expiresAt FROM c WHERE NOT IS_DEFINED(c.type)', { maxItemCount: 1000 });
  while (it.hasMoreResults()) { const { resources } = await it.fetchNext(); records.push(...(resources ?? [])); }
  const { compared, differences } = compareWithGateway(gw, records, { tenantId });
  const byKind = differences.reduce((a, d) => ({ ...a, [d.kind]: (a[d.kind] ?? 0) + 1 }), {});
  console.log(JSON.stringify({ ok: differences.length === 0, mode: 'compare', gateway: gw.apim, compared, projectionRecords: records.length, differences: differences.length, byKind, sample: differences.slice(0, 20), seconds: (Date.now() - started) / 1000 }));
  process.exit(differences.length ? 4 : 0);
}

// --compare-snapshot <full-snapshot.json>: read-only. Used when a new gateway has no named values
// to compare against; the full snapshot is the fresh Entra decision set.
if (opt('--compare-snapshot')) {
  const snap = JSON.parse(readFileSync(opt('--compare-snapshot'), 'utf8').replace(/^\uFEFF/, ''));
  const records = [];
  const it = containerRef().items.query('SELECT c.id, c.oid, c.tier, c.businessUnit, c.tenantId, c.reconciliationGeneration, c.lastVerifiedAt, c.expiresAt, c.type FROM c WHERE NOT IS_DEFINED(c.type)', { maxItemCount: 1000 });
  while (it.hasMoreResults()) { const { resources } = await it.fetchNext(); records.push(...(resources ?? [])); }
  const comparison = compareWithSnapshot(snap, records, { tenantId });
  if (comparison.refused) fail(`snapshot refused: ${comparison.problems.join('; ')}`, 2);
  const byKind = comparison.differences.reduce((a, d) => ({ ...a, [d.kind]: (a[d.kind] ?? 0) + 1 }), {});
  console.log(JSON.stringify({ ok: comparison.differences.length === 0, mode: 'compare-snapshot', compared: comparison.compared, projectionRecords: records.length, differences: comparison.differences.length, byKind, sample: comparison.differences.slice(0, 20), seconds: (Date.now() - started) / 1000 }));
  process.exit(comparison.differences.length ? 4 : 0);
}

let { records, mappingVersion, source, reconciliation, scope = 'full' } = await resolveMembership();
const container = containerRef();
const runId = process.env.CONTAINER_APP_JOB_EXECUTION_NAME ?? process.env.PROJECTION_RUN_ID ?? `local-${started}`;
const lockClock = createLockClock();
let lock = null;
try {
  if (mutatingApply) {
    lock = await step('lock', () => acquireApplyLock(container, { runId, mode: scope === 'user' ? 'user' : 'full', waitSeconds: lockWaitSeconds, now: lockClock }));
    activeLockForFailure = lock;
  }
  let existing = await step('cosmos-read', () => userOid ? readExistingUser(container, userOid) : readExisting(container));
  let excludedByNewerTargetedSync = 0;
  const statuses = await step('status-read', () => readSuccessfulStatuses(container));
  const snapshotCutoff = Date.parse(reconciliation.lastVerifiedAt);
  const targetedCutoff = snapshotCutoff - 300_000;
  if (!Number.isFinite(snapshotCutoff)) fail('invalid snapshot freshness', 2, 'plan');
  if (!userOid && scope === 'full') {
    if (statuses.some((s) => s.mode === 'full' && Date.parse(s.finishedAt) > snapshotCutoff)) {
      await releaseActiveLock();
      fail(`a newer full sync finished after this snapshot was taken; export a fresh snapshot. ${rerunRemedy}`, 2, 'plan');
    }
    const excluded = new Set(statuses
      .filter((s) => s.mode === 'user' && GUID.test(s.user ?? '') && Date.parse(s.finishedAt) > targetedCutoff)
      .map((s) => s.user));
    excludedByNewerTargetedSync = excluded.size;
    if (excluded.size) {
      records = records.filter((r) => !excluded.has(r.oid));
      existing = new Map([...existing.entries()].filter(([oid]) => !excluded.has(oid)));
    }
  }
  if (userOid) {
    const staleForUser = statuses.some((s) =>
      Date.parse(s.finishedAt) > snapshotCutoff &&
      (s.mode === 'full' || (s.mode === 'user' && s.user === userOid)));
    if (staleForUser) {
      await releaseActiveLock();
      fail(`a newer sync already finished for this user after this snapshot was taken. ${userRerunRemedy}`, 2, 'plan');
    }
  }
  const plan = planChanges(records, existing, { allowEmpty: userOid ? true : flag('--allow-empty'), keepOrphans: userOid ? false : flag('--keep-orphans'), refresh: false });
  if (plan.refused) {
    await releaseActiveLock();
    fail(`${plan.reason}. ${rerunRemedy}`, 2, 'plan');
  }

  const summary = {
    ok: true, source, whatIf, resolved: records.length, existing: existing.size,
    toWrite: plan.toWrite.length, toDelete: plan.toDelete.length, keptOrphans: plan.keptOrphans.length, unchanged: plan.unchanged,
    excludedByNewerTargetedSync,
  };
  if (whatIf) { console.log(JSON.stringify(summary)); process.exit(0); }

  const writes = await step('cosmos-write', () => bulk(container, plan.toWrite.map((r) => ({
    operationType: 'Upsert', partitionKey: r.oid, resourceBody: toDocument(r, { tenantId, mappingVersion, reconciliation }),
  })), lock));
  const deletes = await step('cosmos-write', () => bulk(container, plan.toDelete.map((oid) => ({ operationType: 'Delete', id: oid, partitionKey: oid })), lock));
  const writeCounts = { written: writes.ok, writeFailed: writes.failed, deleted: deletes.ok, deleteFailed: deletes.failed };
  Object.assign(summary, { ok: !(writes.failed || deletes.failed), ...writeCounts, mappingVersion, reconciliationGeneration: reconciliation.reconciliationGeneration, lastVerifiedAt: reconciliation.lastVerifiedAt, seconds: (Date.now() - started) / 1000 });
  if (summary.ok) {
    const memberCounts = records.reduce((counts, r) => ({ ...counts, [r.tier]: (counts[r.tier] ?? 0) + 1 }), {});
    const explicitExecutor = opt('--executor');
    if (explicitExecutor && !['job', 'runner'].includes(explicitExecutor)) {
      await releaseActiveLock();
      fail('--executor must be job or runner. Remedy: rerun with --executor job or --executor runner.', 2, 'config');
    }
    const status = toStatusDocument({
      tenantId,
      accountResourceId,
      databaseName,
      containerName,
      runId,
      imageDigest: process.env.PROJECTION_IMAGE_DIGEST ?? '',
      entrypoint: process.env.PROJECTION_ENTRYPOINT ?? 'node /app/sync/src/apply-projection.mjs',
      command: process.argv.slice(1),
      dryRun: whatIf,
      commandOverride: Boolean(process.env.PROJECTION_COMMAND_OVERRIDE),
      memberCounts,
      writeCounts,
      reconciliation,
      startedAt: new Date(started).toISOString(),
      finishedAt: new Date().toISOString(),
      mode: scope === 'user' ? 'user' : 'full',
      executor: explicitExecutor ?? (renewal ? 'job' : 'runner'),
      user: userOid || null,
      settings: renewal ? normalizeJobSettings({
        clientId: process.env.AZURE_CLIENT_ID,
        standardGroupId: process.env.PROJECTION_STANDARD_GROUP_ID,
        premiumGroupId: process.env.PROJECTION_PREMIUM_GROUP_ID,
        gatewayResourceId: process.env.PROJECTION_GATEWAY_RESOURCE_ID,
      }) : null,
    });
    await step('lock', () => lock?.renewIfNeeded({ force: true }));
    const statusWrite = await step('status', () => bulk(container, [{ operationType: 'Upsert', partitionKey: status.oid, resourceBody: status }], null));
    Object.assign(summary, { statusWritten: statusWrite.ok, statusWriteFailed: statusWrite.failed, mode: status.mode, executor: status.executor });
    summary.ok = statusWrite.failed === 0;
  }
  if (renewal) {
    const stage = (writes.failed || deletes.failed) ? 'cosmos-write' : 'status';
    Object.assign(summary, summary.ok ? { event: RENEWAL_SUCCEEDED } : { event: RENEWAL_FAILED, stage });
  }
  await releaseActiveLock();
  if (lock?.warnings?.length) summary.warnings = lock.warnings;
  console.log(JSON.stringify(summary));
  if (!summary.ok) process.exit(3);
  process.exit(writes.failed || deletes.failed ? 3 : 0);
} finally {
  await releaseActiveLock();
}

function resolveAccountResourceId({ endpoint, flagValue, envValue, required }) {
  const chosen = flagValue ?? envValue ?? '';
  if (flagValue && envValue && flagValue.toLowerCase() !== envValue.toLowerCase()) {
    fail(`--account-resource-id differs from PROJECTION_ACCOUNT_RESOURCE_ID. ${accountRemedy}`);
  }
  if (!chosen) {
    if (required) fail(`--account-resource-id is required for mutating applies. ${accountRemedy}`);
    return '';
  }
  const match = COSMOS_ACCOUNT_RESOURCE_ID.exec(chosen);
  if (!match) fail(`--account-resource-id must be an ARM id: /subscriptions/<guid>/resourceGroups/<rg>/providers/Microsoft.DocumentDB/databaseAccounts/<name>. ${accountRemedy}`);
  let accountName = '';
  try {
    const url = new URL(endpoint);
    const hostMatch = /^([a-z0-9-]+)\.documents\.azure\.com$/i.exec(url.hostname);
    if (url.protocol !== 'https:' || !hostMatch) fail('--cosmos must be an https Cosmos DB endpoint URL');
    accountName = hostMatch[1];
  } catch {
    fail('--cosmos must be an https Cosmos DB endpoint URL');
  }
  if (match[3].toLowerCase() !== accountName.toLowerCase()) {
    fail(`--account-resource-id names Cosmos account '${match[3]}', but --cosmos is for '${accountName}'. ${accountRemedy}`);
  }
  return chosen.toLowerCase();
}

function createLockClock() {
  const stepMs = Number(process.env.FAKE_APPLY_LOCK_ADVANCE_MS ?? 0);
  if (!Number.isFinite(stepMs) || stepMs <= 0) return () => new Date();
  let current = Date.now();
  return () => {
    current += stepMs;
    return new Date(current);
  };
}

