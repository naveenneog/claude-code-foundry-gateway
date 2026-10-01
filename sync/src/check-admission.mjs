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
const imageDigest = opt('--image-digest', process.env.PROJECTION_IMAGE_DIGEST);
const entrypoint = opt('--entrypoint', process.env.PROJECTION_ENTRYPOINT);
const actionGroupResourceId = opt('--action-group-resource-id', process.env.PROJECTION_ACTION_GROUP_ID);

function fail(error, code = 1) {
  console.log(JSON.stringify({ ok: false, error }));
  process.exit(code);
}

if (!endpoint) fail('--cosmos is required');
if (!tenantId) fail('--tenant is required');
if (!accountResourceId) fail('--account-resource-id is required');
if (!imageDigest) fail('--image-digest is required');
if (!entrypoint) fail('--entrypoint is required');

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
  query: "SELECT c.oid, c.tenantId, c.tier, c.reconciliationGeneration, c.expiresAt FROM c WHERE (NOT IS_DEFINED(c.type) OR c.type != 'projection-reconciliation-status') AND c.tenantId = @tenantId",
  parameters: [
    { name: '@tenantId', value: tenantId },
  ],
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
  expected: { tenantId, accountResourceId, databaseName, containerName, imageDigest, entrypoint, actionGroupResourceId },
  job: { image: imageDigest, command: [], args: [] },
});
console.log(JSON.stringify({ ...result, mode: 'projection-admission', statuses: statuses.length, entitlementRecords: entitlementRecords.length }));
process.exit(result.ok ? 0 : 4);
