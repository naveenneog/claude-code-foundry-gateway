#!/usr/bin/env node
import { CosmosClient } from '@azure/cosmos';
import { DefaultAzureCredential } from '@azure/identity';
import { evaluateProjectionAdmission, normalizeJobSettings } from './plan.mjs';

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
const imageDigest = opt('--image-digest', process.env.PROJECTION_IMAGE_DIGEST);
const entrypoint = opt('--entrypoint', process.env.PROJECTION_ENTRYPOINT);
const actionGroupResourceId = opt('--action-group-resource-id', process.env.PROJECTION_ACTION_GROUP_ID);
// The settings the job definition carries now; only evidence written under them counts (ADR-0050).
const settings = normalizeJobSettings({
  clientId: opt('--client-id'),
  standardGroupId: opt('--standard-group-id'),
  premiumGroupId: opt('--premium-group-id'),
  gatewayResourceId: opt('--gateway-resource-id'),
});

function fail(error, code = 1) {
  console.log(JSON.stringify({ ok: false, error }));
  process.exit(code);
}

if (!endpoint) fail('--cosmos is required');
if (!tenantId) fail('--tenant is required');
if (!accountResourceId) fail('--account-resource-id is required');
if (!imageDigest) fail('--image-digest is required');
if (!entrypoint) fail('--entrypoint is required');
if (!settings) fail('--client-id, --standard-group-id, --premium-group-id and --gateway-resource-id are required: admission counts only evidence written under the job settings');

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
  expected: { tenantId, accountResourceId, databaseName, containerName, imageDigest, entrypoint, actionGroupResourceId, settings },
  job: { image: imageDigest, command: [], args: [] },
});
console.log(JSON.stringify({ ...result, mode: 'projection-admission', statuses: statuses.length, entitlementRecords: entitlementRecords.length }));
process.exit(result.ok ? 0 : 4);
