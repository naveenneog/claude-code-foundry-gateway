import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  prepareAccessCatalogDocument,
  publishAccessCatalog,
} from '../src/access-catalog-administration.mjs';

const TENANT = '11111111-2222-4333-8444-555555555555';
const OTHER_TENANT = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
const GENERATED_AT = '2026-10-14T17:00:00.000Z';

function catalog(overrides = {}) {
  return {
    schemaVersion: 1,
    tenantId: TENANT,
    plans: [{
      id: 'developer',
      name: 'Developer',
      enabled: true,
      nominalCredit: { amount: 100, currency: 'USD', period: 'month', scope: 'user' },
      compatibilityTier: 'standard',
    }],
    profiles: [{
      id: 'developer-code',
      name: 'Developer Code',
      planId: 'developer',
      groupObjectId: '99999999-8888-4777-8666-555555555555',
      priority: 10,
      capabilities: ['code'],
      modelFamilies: ['sonnet', 'haiku'],
      connectors: [],
      enabled: true,
    }],
    ...overrides,
  };
}

function cosmosError(statusCode) {
  return Object.assign(new Error(`fixture ${statusCode}`), { statusCode });
}

function memoryContainer(initial, { replaceConflict = false, readbackMutation = false } = {}) {
  const documents = new Map();
  if (initial) documents.set(initial.id, structuredClone(initial));
  const calls = [];
  let etag = 1;

  function response(resource) {
    const saved = structuredClone(resource);
    saved._etag = `"${etag++}"`;
    documents.set(saved.id, saved);
    return { resource: structuredClone(saved), etag: saved._etag };
  }

  return {
    calls,
    documents,
    items: {
      async create(document) {
        calls.push({ operation: 'create', document: structuredClone(document) });
        if (documents.has(document.id)) throw cosmosError(409);
        return response(document);
      },
    },
    item(id, partitionKey) {
      return {
        async read() {
          calls.push({ operation: 'read', id, partitionKey });
          const found = documents.get(id);
          if (!found) throw cosmosError(404);
          const value = structuredClone(found);
          if (readbackMutation && id.startsWith('access-catalog::')) value.catalogVersion = 'sha256:' + '0'.repeat(64);
          return { resource: value, etag: value._etag };
        },
        async replace(document, options) {
          calls.push({
            operation: 'replace',
            id,
            partitionKey,
            document: structuredClone(document),
            options: structuredClone(options),
          });
          if (replaceConflict) throw cosmosError(412);
          const found = documents.get(id);
          if (!found) throw cosmosError(404);
          if (options?.accessCondition?.condition !== found._etag) throw cosmosError(412);
          return response(document);
        },
      };
    },
  };
}

test('preparation binds the tenant and emits the canonical control document', () => {
  const input = catalog();
  input.tenantId = TENANT.toUpperCase();
  input.profiles[0].modelFamilies = ['SONNET', 'HAIKU'];

  const document = prepareAccessCatalogDocument(input, {
    tenantId: TENANT,
    now: () => new Date(GENERATED_AT),
  });

  assert.equal(document.id, `access-catalog::${TENANT}`);
  assert.equal(document.oid, document.id);
  assert.equal(document.type, 'access-catalog');
  assert.equal(document.generatedAt, GENERATED_AT);
  assert.match(document.catalogVersion, /^sha256:[0-9a-f]{64}$/);
  assert.deepEqual(document.profiles[0].modelFamilies, ['haiku', 'sonnet']);
  assert.deepEqual(
    Object.keys(document),
    ['id', 'oid', 'type', 'schemaVersion', 'tenantId', 'plans', 'profiles', 'catalogVersion', 'generatedAt'],
  );
});

test('tenant mismatch and malformed catalogs fail before a document exists without echoing tenant ids', () => {
  for (const input of [
    catalog({ tenantId: OTHER_TENANT }),
    catalog({ profiles: [] }),
  ]) {
    assert.throws(
      () => prepareAccessCatalogDocument(input, { tenantId: TENANT }),
      (error) => {
        assert.match(error.message, /tenant|profile|catalog/i);
        assert.doesNotMatch(error.message, new RegExp(TENANT, 'i'));
        assert.doesNotMatch(error.message, new RegExp(OTHER_TENANT, 'i'));
        return true;
      },
    );
  }
});

test('a missing catalog is created once and verified by point read', async () => {
  const container = memoryContainer();
  const result = await publishAccessCatalog(container, catalog(), {
    tenantId: TENANT,
    now: () => new Date(GENERATED_AT),
  });

  assert.equal(result.status, 'created');
  assert.equal(result.backupId, null);
  assert.match(result.catalogVersion, /^sha256:[0-9a-f]{64}$/);
  assert.deepEqual(container.calls.map((call) => call.operation), ['read', 'create', 'read']);
  assert.equal(container.calls[1].document.type, 'access-catalog');
});

test('an existing catalog is backed up then conditionally replaced and verified', async () => {
  const previous = prepareAccessCatalogDocument(catalog(), {
    tenantId: TENANT,
    now: () => new Date('2026-10-13T17:00:00.000Z'),
  });
  previous._etag = '"old"';
  const container = memoryContainer(previous);
  const changed = catalog();
  changed.plans[0].name = 'Developer Plus';

  const result = await publishAccessCatalog(container, changed, {
    tenantId: TENANT,
    now: () => new Date(GENERATED_AT),
    randomId: () => '12345678',
  });

  assert.equal(result.status, 'replaced');
  assert.match(result.backupId, /^access-catalog-backup::20261014T170000000Z::12345678$/);
  assert.deepEqual(container.calls.map((call) => call.operation), ['read', 'create', 'replace', 'read']);
  const backup = container.calls[1].document;
  assert.equal(backup.type, 'access-catalog-backup');
  assert.equal(backup.oid, `access-catalog::${TENANT}`);
  assert.equal(backup.catalog.catalogVersion, previous.catalogVersion);
  assert.deepEqual(container.calls[2].options, {
    accessCondition: { type: 'IfMatch', condition: '"old"' },
  });
});

test('an ETag conflict fails closed after the recoverable backup', async () => {
  const previous = prepareAccessCatalogDocument(catalog(), { tenantId: TENANT });
  previous._etag = '"old"';
  const container = memoryContainer(previous, { replaceConflict: true });

  await assert.rejects(
    publishAccessCatalog(container, catalog(), { tenantId: TENANT }),
    (error) => {
      assert.equal(error.stage, 'conflict');
      assert.match(error.message, /changed.*rerun|conflict/i);
      assert.doesNotMatch(error.message, new RegExp(TENANT, 'i'));
      return true;
    },
  );
  assert.deepEqual(container.calls.map((call) => call.operation), ['read', 'create', 'replace']);
});

test('a readback hash mismatch is reported as verification failure', async () => {
  const container = memoryContainer(null, { readbackMutation: true });
  await assert.rejects(
    publishAccessCatalog(container, catalog(), { tenantId: TENANT }),
    (error) => error.stage === 'readback' && /readback.*hash/i.test(error.message),
  );
});

test('the validation CLI reports counts and hash without loading a Cosmos writer', () => {
  const result = runCli(catalog(), ['--tenant', TENANT, '--validate-only']);
  assert.equal(result.status, 0, result.stderr);
  const summary = JSON.parse(result.stdout);
  assert.deepEqual(
    { ok: summary.ok, mode: summary.mode, plans: summary.plans, profiles: summary.profiles },
    { ok: true, mode: 'validate', plans: 1, profiles: 1 },
  );
  assert.match(summary.catalogVersion, /^sha256:[0-9a-f]{64}$/);
});

test('CLI failures expose neither discovered tenant id nor a mismatched catalog tenant id', () => {
  const result = runCli(catalog({ tenantId: OTHER_TENANT }), ['--tenant', TENANT, '--validate-only']);
  assert.equal(result.status, 3);
  const summary = JSON.parse(result.stdout);
  assert.deepEqual(summary, {
    ok: false,
    stage: 'tenant',
    remedy: 'Remedy: correct the catalog or resolve the concurrent publication, then rerun scripts/Set-ClaudeAccessCatalog.ps1.',
  });
  assert.doesNotMatch(result.stdout + result.stderr, new RegExp(TENANT, 'i'));
  assert.doesNotMatch(result.stdout + result.stderr, new RegExp(OTHER_TENANT, 'i'));
});

function runCli(value, extraArguments) {
  const directory = mkdtempSync(join(tmpdir(), 'access-catalog-cli-'));
  const path = join(directory, 'catalog.json');
  writeFileSync(path, JSON.stringify(value));
  try {
    return spawnSync(process.execPath, [
      fileURLToPath(new URL('../src/administer-access-catalog.mjs', import.meta.url)),
      '--catalog',
      path,
      ...extraArguments,
    ], { encoding: 'utf8' });
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}
