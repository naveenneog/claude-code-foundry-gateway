import { randomUUID } from 'node:crypto';
import { canonicalizeAccessCatalog, hashAccessCatalog } from './access-catalog.mjs';

const GUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export function prepareAccessCatalogDocument(catalog, {
  tenantId,
  now = () => new Date(),
} = {}) {
  const boundTenant = normalizeTenant(tenantId);
  let canonical;
  try {
    canonical = canonicalizeAccessCatalog(catalog);
  } catch (error) {
    throw stagedError('catalog', error?.message ?? 'access catalog validation failed');
  }
  if (canonical.tenantId !== boundTenant) {
    throw stagedError('tenant', 'access catalog tenant does not match the API Management managed-identity tenant');
  }
  const generatedAt = now().toISOString();
  const id = `access-catalog::${boundTenant}`;
  return {
    id,
    oid: id,
    type: 'access-catalog',
    schemaVersion: canonical.schemaVersion,
    tenantId: canonical.tenantId,
    plans: canonical.plans,
    profiles: canonical.profiles,
    catalogVersion: `sha256:${hashAccessCatalog(canonical)}`,
    generatedAt,
  };
}

export async function publishAccessCatalog(container, catalog, {
  tenantId,
  now = () => new Date(),
  randomId = () => randomUUID().replaceAll('-', '').slice(0, 8),
} = {}) {
  const document = prepareAccessCatalogDocument(catalog, { tenantId, now });
  const current = await readCurrent(container, document.id);
  let backupId = null;
  let status;

  if (current.resource) {
    backupId = backupDocumentId(now(), randomId());
    const backup = {
      id: backupId,
      oid: document.oid,
      type: 'access-catalog-backup',
      sourceId: document.id,
      backedUpAt: now().toISOString(),
      catalog: recoverableCatalog(current.resource),
    };
    try {
      await container.items.create(backup);
    } catch {
      throw stagedError('backup', 'access catalog backup could not be saved; the current catalog was not changed');
    }
    try {
      await container.item(document.id, document.oid).replace(document, {
        accessCondition: { type: 'IfMatch', condition: current.etag },
      });
      status = 'replaced';
    } catch (error) {
      if (isStatus(error, 412) || isStatus(error, 404)) {
        throw stagedError('conflict', 'access catalog changed during publication; the replacement was refused and the command must be rerun');
      }
      throw stagedError('write', 'access catalog replacement failed after its backup was saved');
    }
  } else {
    try {
      await container.items.create(document);
      status = 'created';
    } catch (error) {
      if (isStatus(error, 409)) {
        throw stagedError('conflict', 'access catalog appeared during publication; the create was refused and the command must be rerun');
      }
      throw stagedError('write', 'access catalog creation failed');
    }
  }

  let readback;
  try {
    ({ resource: readback } = await container.item(document.id, document.oid).read());
  } catch {
    throw stagedError('readback', 'access catalog readback failed after publication');
  }
  if (readback?.catalogVersion !== document.catalogVersion) {
    throw stagedError('readback', 'access catalog readback hash did not match the published catalog');
  }

  return {
    status,
    backupId,
    catalogVersion: document.catalogVersion,
    plans: document.plans.length,
    profiles: document.profiles.length,
  };
}

function normalizeTenant(value) {
  const normalized = typeof value === 'string' ? value.toLowerCase() : '';
  if (!GUID.test(normalized)) {
    throw stagedError('tenant', 'API Management managed-identity tenant is missing or malformed');
  }
  return normalized;
}

async function readCurrent(container, id) {
  try {
    const response = await container.item(id, id).read();
    return {
      resource: response.resource,
      etag: response.etag ?? response.resource?._etag ?? response.headers?.etag,
    };
  } catch (error) {
    if (isStatus(error, 404)) return { resource: null, etag: undefined };
    throw stagedError('read', 'current access catalog could not be read');
  }
}

function recoverableCatalog(document) {
  return {
    id: document.id,
    oid: document.oid,
    type: document.type,
    schemaVersion: document.schemaVersion,
    tenantId: document.tenantId,
    plans: document.plans,
    profiles: document.profiles,
    catalogVersion: document.catalogVersion,
    generatedAt: document.generatedAt,
  };
}

function backupDocumentId(at, suffix) {
  const timestamp = at.toISOString().replace(/[-:.]/g, '');
  const safeSuffix = String(suffix).toLowerCase();
  if (!/^[a-z0-9]{8}$/.test(safeSuffix)) {
    throw stagedError('backup', 'access catalog backup identifier generation failed');
  }
  return `access-catalog-backup::${timestamp}::${safeSuffix}`;
}

function stagedError(stage, message) {
  const error = new Error(message);
  error.stage = stage;
  return error;
}

function isStatus(error, code) {
  return (error?.code ?? error?.statusCode ?? error?.status) === code;
}
