import { readFileSync } from 'node:fs';
import {
  prepareAccessCatalogDocument,
  publishAccessCatalog,
} from './access-catalog-administration.mjs';

const args = process.argv.slice(2);
const opt = (name, fallback = undefined) => {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : fallback;
};
const flag = (name) => args.includes(name);

const path = opt('--catalog');
const tenantId = (opt('--tenant') ?? '').toLowerCase();
const endpoint = opt('--cosmos');
const databaseName = opt('--database', 'claude');
const containerName = opt('--container', 'entitlement');
const accountResourceId = opt('--account-resource-id');

try {
  if (!path) throw configError('--catalog is required');
  let catalog;
  try {
    catalog = JSON.parse(readFileSync(path, 'utf8').replace(/^\uFEFF/, ''));
  } catch {
    throw configError('catalog JSON could not be read or parsed');
  }
  const document = prepareAccessCatalogDocument(catalog, { tenantId });
  if (flag('--validate-only')) {
    print({
      ok: true,
      mode: 'validate',
      plans: document.plans.length,
      profiles: document.profiles.length,
      catalogVersion: document.catalogVersion,
    });
    process.exit(0);
  }
  if (!endpoint || !/^https:\/\/[a-z0-9-]+\.documents\.azure\.com:443\/$/.test(endpoint)) {
    throw configError('--cosmos must be the private projection Cosmos HTTPS endpoint');
  }
  if (databaseName !== 'claude' || containerName !== 'entitlement') {
    throw configError('catalog publication is restricted to the claude entitlement container');
  }
  if (!accountResourceId || !/^\/subscriptions\/[0-9a-f-]+\/resourceGroups\/[A-Za-z0-9._-]+\/providers\/Microsoft\.DocumentDB\/databaseAccounts\/[a-z0-9-]+$/i.test(accountResourceId)) {
    throw configError('--account-resource-id must name the discovered projection Cosmos account');
  }

  const { DefaultAzureCredential } = await import('@azure/identity');
  const { CosmosClient } = await import('@azure/cosmos');
  const credential = new DefaultAzureCredential();
  const container = new CosmosClient({ endpoint, aadCredentials: credential })
    .database(databaseName)
    .container(containerName);
  const result = await publishAccessCatalog(container, catalog, { tenantId });
  print({
    ok: true,
    mode: 'publish',
    status: result.status,
    plans: result.plans,
    profiles: result.profiles,
    catalogVersion: result.catalogVersion,
    backup: Boolean(result.backupId),
  });
} catch (error) {
  const stage = /^[a-z][a-z-]{0,39}$/.test(error?.stage ?? '') ? error.stage : 'config';
  // Catalog-stage messages come from the local validator and name only catalog ids and rules.
  const detail = stage === 'catalog' && typeof error?.message === 'string' ? error.message.slice(0, 300) : undefined;
  print({
    ok: false,
    stage,
    ...(detail ? { detail } : {}),
    remedy: 'Remedy: correct the catalog or resolve the concurrent publication, then rerun scripts/Set-ClaudeAccessCatalog.ps1.',
  });
  process.exit(3);
}

function configError(message) {
  const error = new Error(message);
  error.stage = 'config';
  return error;
}

function print(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}
