import { appendFileSync, existsSync, readFileSync, writeFileSync } from 'node:fs';

function load() {
  return existsSync(process.env.FAKE_COSMOS_STORE) ? JSON.parse(readFileSync(process.env.FAKE_COSMOS_STORE, 'utf8')) : { docs: {} };
}

function save(store) {
  writeFileSync(process.env.FAKE_COSMOS_STORE, JSON.stringify(store, null, 1));
}

function log(line) {
  appendFileSync(process.env.FAKE_COSMOS_LOG, `${line}\n`);
}

class Items {
  query(query) {
    const text = typeof query === 'string' ? query : query.query;
    const params = Object.fromEntries((query.parameters ?? []).map((p) => [p.name, p.value]));
    log(`query ${text}`);
    const docs = Object.values(load().docs);
    let rows = docs;
    if (text.includes("c.type = 'projection-reconciliation-status'")) {
      rows = rows.filter((d) => d.type === 'projection-reconciliation-status');
    } else if (text.includes('NOT IS_DEFINED(c.type)')) {
      rows = rows.filter((d) => d.type === undefined);
    }
    if (params['@tenantId']) rows = rows.filter((d) => d.tenantId === params['@tenantId']);
    if (params['@accountResourceId']) rows = rows.filter((d) => d.accountResourceId === params['@accountResourceId']);
    if (params['@databaseName']) rows = rows.filter((d) => d.databaseName === params['@databaseName']);
    if (params['@containerName']) rows = rows.filter((d) => d.containerName === params['@containerName']);
    const pages = paginate(rows);
    let page = 0;
    return {
      hasMoreResults: () => page < pages.length,
      fetchNext: async () => {
        const resources = pages[page] ?? [];
        log(`fetch-page ${page} rows=${resources.length}`);
        page++;
        return { resources };
      },
    };
  }

  async executeBulkOperations(operations) {
    const store = load();
    store.bulkBatches = (store.bulkBatches ?? 0) + 1;
    const results = operations.map((op) => {
      const id = op.id ?? op.resourceBody?.id ?? '';
      log(`bulk ${op.operationType} ${id}`);
      if (op.operationType === 'Upsert') store.docs[`${op.resourceBody.id}|${op.partitionKey}`] = withEtag(op.resourceBody, store);
      if (op.operationType === 'Delete') delete store.docs[`${op.id}|${op.partitionKey}`];
      return { statusCode: op.operationType === 'Delete' ? 204 : 200 };
    });
    save(store);
    return results;
  }

  async create(body) {
    const store = load();
    const key = `${body.id}|${body.oid}`;
    log(`create ${key}`);
    if (store.docs[key]) {
      const error = new Error('conflict');
      error.code = 409;
      error.statusCode = 409;
      throw error;
    }
    const resource = withEtag(body, store);
    store.docs[key] = resource;
    save(store);
    return { resource, etag: resource._etag };
  }
}

export class CosmosClient {
  database() {
    return {
      container: () => ({
        items: new Items(),
        item: (id, partitionKey) => ({
          read: async () => {
            log(`point-read ${id}|${partitionKey}`);
            const resource = load().docs[`${id}|${partitionKey}`];
            if (!resource) {
              const error = new Error('not found');
              error.code = 404;
              error.statusCode = 404;
              throw error;
            }
            return { resource, etag: resource._etag };
          },
          replace: async (body, options = {}) => {
            const store = load();
            const key = `${id}|${partitionKey}`;
            const current = store.docs[key];
            const expected = options.accessCondition?.condition;
            log(`replace ${key}${expected ? ' if-match' : ''}`);
            if (!current) {
              const error = new Error('not found');
              error.code = 404;
              error.statusCode = 404;
              throw error;
            }
            if (expected && current._etag !== expected) {
              const error = new Error('precondition failed');
              error.code = 412;
              error.statusCode = 412;
              throw error;
            }
            if (process.env.FAKE_COSMOS_FAIL_RENEW_AFTER_BULK && current.type === 'projection-apply-lock' && (store.bulkBatches ?? 0) >= Number(process.env.FAKE_COSMOS_FAIL_RENEW_AFTER_BULK)) {
              const error = new Error('precondition failed');
              error.code = 412;
              error.statusCode = 412;
              throw error;
            }
            const resource = withEtag(body, store);
            store.docs[key] = resource;
            save(store);
            return { resource, etag: resource._etag };
          },
          delete: async (options = {}) => {
            const store = load();
            const key = `${id}|${partitionKey}`;
            const current = store.docs[key];
            const expected = options.accessCondition?.condition;
            log(`delete ${key}${expected ? ' if-match' : ''}`);
            if (!current) {
              const error = new Error('not found');
              error.code = 404;
              error.statusCode = 404;
              throw error;
            }
            if (expected && current._etag !== expected) {
              const error = new Error('precondition failed');
              error.code = 412;
              error.statusCode = 412;
              throw error;
            }
            delete store.docs[key];
            save(store);
            return { resource: undefined };
          },
        }),
      }),
    };
  }
}

function withEtag(doc, store) {
  store.etagCounter = (store.etagCounter ?? 0) + 1;
  return { ...doc, _etag: `"${store.etagCounter}"` };
}

function paginate(rows) {
  const requested = Number(process.env.FAKE_COSMOS_PAGE_SIZE);
  const size = Number.isInteger(requested) && requested > 0 ? requested : Math.max(rows.length, 1);
  const pages = [];
  if (process.env.FAKE_COSMOS_EMPTY_FIRST_PAGE && rows.length) pages.push([]);
  for (let i = 0; i < rows.length; i += size) pages.push(rows.slice(i, i + size));
  if (!pages.length) pages.push([]);
  return pages;
}
