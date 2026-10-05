#!/usr/bin/env node
import { CosmosClient } from '@azure/cosmos';
import { DefaultAzureCredential } from '@azure/identity';
import { evaluateProjectionAdmission } from './plan.mjs';

const argv = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = argv.indexOf(name);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : fallback;
};

const endpoint = opt('--cosmos', process.env.COSMOS_ENDPOINT);
const tenantId = opt('--tenant', process.env.PROJECTION_TENANT_ID);
const accountResourceId = opt('--account-resource-id', process.env.PROJECTION_ACCOUNT_RESOURCE_ID);
const databaseName = opt('--database', 'claude');
const containerName = opt('--container', 'entitlement');
const maxEvidenceAgeSeconds = Number(opt('--max-evidence-age-seconds', '86400'));

function fail(error, code = 1) {
  console.log(JSON.stringify({ ok: false, mode: 'switch-evidence', error }));
  process.exit(code);
}

if (!endpoint) fail('--cosmos is required');
if (!tenantId) fail('--tenant is required');
if (!accountResourceId) fail('--account-resource-id is required');
if (!isCosmosEndpoint(endpoint)) fail('--cosmos must be an https Cosmos DB endpoint URL');
if (!isGuid(tenantId)) fail('--tenant must be a guid');
if (!isCosmosAccountResourceId(accountResourceId)) fail('--account-resource-id must be a Cosmos DB database account resource id');
if (!Number.isFinite(maxEvidenceAgeSeconds) || maxEvidenceAgeSeconds <= 0) fail('--max-evidence-age-seconds must be positive');

const credential = new DefaultAzureCredential();
const container = new CosmosClient({ endpoint, aadCredentials: credential })
  .database(databaseName)
  .container(containerName);

const query = {
  query: "SELECT * FROM c WHERE c.type = 'projection-reconciliation-status' AND c.tenantId = @tenantId AND c.accountResourceId = @accountResourceId AND c.databaseName = @databaseName AND c.containerName = @containerName",
  parameters: [
    { name: '@tenantId', value: tenantId },
    { name: '@accountResourceId', value: accountResourceId },
    { name: '@databaseName', value: databaseName },
    { name: '@containerName', value: containerName },
  ],
};

const statuses = [];
const it = container.items.query(query, { maxItemCount: 1000 });
while (it.hasMoreResults()) {
  const { resources } = await it.fetchNext();
  statuses.push(...(resources ?? []));
}

const entitlementQuery = {
  query: "SELECT c.id, c.oid, c.tenantId, c.tier, c.businessUnit, c.mappingVersion, c.effectiveFrom, c.reconciliationGeneration, c.lastVerifiedAt, c.expiresAt FROM c WHERE NOT IS_DEFINED(c.type) OR c.type != 'projection-reconciliation-status'",
  parameters: [],
};
const entitlementRecords = [];
const entitlementIterator = container.items.query(entitlementQuery, { maxItemCount: 1000 });
while (entitlementIterator.hasMoreResults()) {
  const { resources } = await entitlementIterator.fetchNext();
  entitlementRecords.push(...(resources ?? []));
}

const result = evaluateProjectionAdmission({
  statuses,
  entitlementRecords,
  expected: { tenantId, accountResourceId, databaseName, containerName },
  maxEvidenceAgeSeconds,
});
console.log(JSON.stringify(result));
process.exit(result.ok ? 0 : 4);

function isGuid(value) {
  return typeof value === 'string' &&
    /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(value);
}

function isCosmosEndpoint(value) {
  try {
    const url = new URL(value);
    return url.protocol === 'https:' && /\.documents\.azure\.com$/i.test(url.hostname);
  } catch {
    return false;
  }
}

function isCosmosAccountResourceId(value) {
  return typeof value === 'string' &&
    /^\/subscriptions\/[^/]+\/resourceGroups\/[^/]+\/providers\/Microsoft\.DocumentDB\/databaseAccounts\/[^/]+$/i.test(value);
}
