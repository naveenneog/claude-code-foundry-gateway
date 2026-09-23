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
 * Usage:
 *   node src/apply-projection.mjs --cosmos https://<acct>.documents.azure.com:443/
 *        --tenant <guid> (--snapshot file | --graph --standard g --premium g [--bu id=g ...])
 *        [--whatif] [--allow-empty] [--keep-orphans]
 */
import { readFileSync } from 'node:fs';
import { CosmosClient } from '@azure/cosmos';
import { DefaultAzureCredential } from '@azure/identity';
import { mergeMembership, planChanges, toDocument, validateSnapshot, compareWithGateway } from './plan.mjs';
import { resolveGroupId, getTransitiveMembers } from './graph.mjs';

const argv = process.argv.slice(2);
const flag = (n) => argv.includes(n);
const opt = (n, d) => { const i = argv.indexOf(n); return i >= 0 && argv[i + 1] ? argv[i + 1] : d; };
const opts = (n) => argv.flatMap((a, i) => (a === n && argv[i + 1] ? [argv[i + 1]] : []));

const endpoint = opt('--cosmos', process.env.COSMOS_ENDPOINT);
const databaseName = opt('--database', 'claude');
const containerName = opt('--container', 'entitlement');
const tenantId = opt('--tenant', process.env.PROJECTION_TENANT_ID);
const whatIf = flag('--whatif');
const log = (m) => console.log(m);

function fail(message, code = 1) {
  console.log(JSON.stringify({ ok: false, error: message }));
  process.exit(code);
}

if (!endpoint) fail('--cosmos is required');
if (!tenantId) fail('--tenant is required: every record is stamped with it and the resolver refuses another');

const credential = new DefaultAzureCredential();

async function resolveMembership() {
  if (opt('--snapshot')) {
    const snap = JSON.parse(readFileSync(opt('--snapshot'), 'utf8').replace(/^\uFEFF/, ''));
    const problems = validateSnapshot(snap, { tenantId });
    if (problems.length) fail(`snapshot refused: ${problems.join('; ')}`);
    return { records: snap.records, mappingVersion: snap.mappingVersion, source: `snapshot ${snap.generatedAt}` };
  }
  if (!flag('--graph')) fail('pass --snapshot <file> or --graph');
  const token = (await credential.getToken('https://graph.microsoft.com/.default')).token;
  const tiers = {};
  for (const [tier, group] of [['premium', opt('--premium', 'claude-code-premium')], ['standard', opt('--standard', 'claude-code-standard')]]) {
    const id = await resolveGroupId(group, token);
    if (!id) { log(`warning: group '${group}' not found - treating as empty`); tiers[tier] = []; continue; }
    tiers[tier] = await getTransitiveMembers(id, token);
    log(`${tier.padEnd(9)} ${group}  ${tiers[tier].length} member(s)`);
  }
  const businessUnits = [];
  for (const spec of opts('--bu')) {
    const [unit, group] = spec.split('=');
    const id = await resolveGroupId(group, token);
    businessUnits.push({ id: unit, members: id ? await getTransitiveMembers(id, token) : [] });
  }
  const { records, unitWithoutTier } = mergeMembership({ tiers, businessUnits });
  for (const u of unitWithoutTier.slice(0, 10)) log(`note: ${u.oid} is in ${u.unit} but holds no tier - not projected`);
  return { records, mappingVersion: Math.floor(Date.now() / 1000), source: 'graph' };
}

async function readExisting(container) {
  const existing = new Map();
  const iterator = container.items.query('SELECT c.id, c.tier, c.businessUnit FROM c', { maxItemCount: 1000 });
  while (iterator.hasMoreResults()) {
    const { resources } = await iterator.fetchNext();
    for (const d of resources ?? []) existing.set(d.id, { tier: d.tier, businessUnit: d.businessUnit ?? '' });
  }
  return existing;
}

async function bulk(container, operations) {
  let ok = 0, failed = 0;
  for (let i = 0; i < operations.length; i += 1000) {
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
  const it = containerRef().items.query('SELECT c.id, c.oid, c.tier, c.businessUnit, c.tenantId FROM c', { maxItemCount: 1000 });
  while (it.hasMoreResults()) { const { resources } = await it.fetchNext(); records.push(...(resources ?? [])); }
  const { compared, differences } = compareWithGateway(gw, records, { tenantId });
  const byKind = differences.reduce((a, d) => ({ ...a, [d.kind]: (a[d.kind] ?? 0) + 1 }), {});
  console.log(JSON.stringify({ ok: differences.length === 0, mode: 'compare', gateway: gw.apim, compared, projectionRecords: records.length, differences: differences.length, byKind, sample: differences.slice(0, 20), seconds: (Date.now() - started) / 1000 }));
  process.exit(differences.length ? 4 : 0);
}

const { records, mappingVersion, source } = await resolveMembership();
const container = containerRef();
const existing = await readExisting(container);
const plan = planChanges(records, existing, { allowEmpty: flag('--allow-empty'), keepOrphans: flag('--keep-orphans') });
if (plan.refused) fail(plan.reason, 2);

const summary = {
  ok: true, source, whatIf, resolved: records.length, existing: existing.size,
  toWrite: plan.toWrite.length, toDelete: plan.toDelete.length, keptOrphans: plan.keptOrphans.length, unchanged: plan.unchanged,
};
if (whatIf) { console.log(JSON.stringify(summary)); process.exit(0); }

const writes = await bulk(container, plan.toWrite.map((r) => ({
  operationType: 'Upsert', partitionKey: r.oid, resourceBody: toDocument(r, { tenantId, mappingVersion }),
})));
const deletes = await bulk(container, plan.toDelete.map((oid) => ({ operationType: 'Delete', id: oid, partitionKey: oid })));
Object.assign(summary, { written: writes.ok, writeFailed: writes.failed, deleted: deletes.ok, deleteFailed: deletes.failed, mappingVersion, seconds: (Date.now() - started) / 1000 });
console.log(JSON.stringify(summary));
process.exit(writes.failed || deletes.failed ? 3 : 0);
