import { readFileSync } from 'node:fs';
import {
  canonicalizeAccessCatalog,
  hashAccessCatalog,
} from './access-catalog.mjs';

const args = process.argv.slice(2);
const option = (name) => {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : undefined;
};

try {
  const catalogPath = option('--catalog');
  const profileId = option('--profile');
  if (!catalogPath) throw stagedError('path', '--catalog is required');
  if (!profileId || !/^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$/.test(profileId)) {
    throw stagedError('profile', '--profile must be a canonical lowercase profile id');
  }

  let raw;
  try {
    raw = JSON.parse(readFileSync(catalogPath, 'utf8').replace(/^\uFEFF/, ''));
  } catch {
    throw stagedError('catalog', 'catalog JSON could not be read or parsed');
  }

  let catalog;
  try {
    catalog = canonicalizeAccessCatalog(raw);
  } catch (error) {
    throw stagedError('catalog', error?.message ?? 'access catalog validation failed');
  }

  const profile = catalog.profiles.find((candidate) => candidate.enabled && candidate.id === profileId);
  if (!profile) throw stagedError('profile', `enabled profile '${profileId}' was not found`);
  const plan = catalog.plans.find((candidate) => candidate.enabled && candidate.id === profile.planId);
  if (!plan) throw stagedError('plan', `enabled plan '${profile.planId}' was not found`);

  print({
    ok: true,
    catalog: {
      schemaVersion: catalog.schemaVersion,
      tenantId: catalog.tenantId,
      hash: `sha256:${hashAccessCatalog(catalog)}`,
    },
    plan,
    profile,
  });
} catch (error) {
  print({
    ok: false,
    stage: /^[a-z][a-z-]{0,39}$/.test(error?.stage ?? '') ? error.stage : 'config',
    message: safeMessage(error?.message),
  });
  process.exit(3);
}

function stagedError(stage, message) {
  const error = new Error(message);
  error.stage = stage;
  return error;
}

function safeMessage(value) {
  return String(value ?? 'access profile could not be described')
    .replace(/[\u0000-\u001f\u007f]/g, ' ')
    .slice(0, 300);
}

function print(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}
