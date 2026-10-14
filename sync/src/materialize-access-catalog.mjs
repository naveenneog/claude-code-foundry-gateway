import { readFileSync } from 'node:fs';
import { canonicalizeAccessCatalog } from './access-catalog.mjs';
import { mergeCatalogMembership } from './plan.mjs';

const args = process.argv.slice(2);
const opt = (name) => {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : undefined;
};

try {
  const catalogPath = opt('--catalog');
  const resolutionPath = opt('--resolution');
  const tenantId = (opt('--tenant') ?? '').toLowerCase();
  if (!catalogPath || !resolutionPath || !tenantId) {
    throw new Error('--catalog, --resolution and --tenant are required');
  }
  const catalog = canonicalizeAccessCatalog(readJson(catalogPath));
  if (catalog.tenantId !== tenantId) {
    throw new Error('access catalog tenant does not match the requested tenant');
  }
  const resolution = readJson(resolutionPath);
  if (!resolution || !Array.isArray(resolution.profileGroups) || !Array.isArray(resolution.businessUnits)) {
    throw new Error('catalog resolution must contain profileGroups and businessUnits arrays');
  }
  const { records } = mergeCatalogMembership({
    catalog,
    profileGroups: resolution.profileGroups,
    businessUnits: resolution.businessUnits,
  });
  print({ ok: true, records });
} catch (error) {
  print({
    ok: false,
    stage: 'catalog',
    error: error?.message ?? String(error),
  });
  process.exit(3);
}

function readJson(path) {
  return JSON.parse(readFileSync(path, 'utf8').replace(/^\uFEFF/, ''));
}

function print(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}
