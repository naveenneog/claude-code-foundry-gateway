// Stand-in @azure/cosmos for the projection renewal simulation (tests/Test-ProjectionRenewalRuns.ps1).
// One container, kept in the JSON file FAKE_COSMOS_STORE so that separate runs share it. It answers
// only the queries the sync entry points send, and refuses any other query instead of guessing.
import { appendFileSync, existsSync, readFileSync, writeFileSync } from 'node:fs';

const STATUS = 'projection-reconciliation-status';
const LOCK = 'projection-apply-lock';

function load() {
  const path = process.env.FAKE_COSMOS_STORE;
  return existsSync(path) ? JSON.parse(readFileSync(path, 'utf8')) : { docs: {} };
}

function save(store) {
  writeFileSync(process.env.FAKE_COSMOS_STORE, JSON.stringify(store, null, 1));
}

function log(line) {
  if (process.env.FAKE_COSMOS_LOG) appendFileSync(process.env.FAKE_COSMOS_LOG, `${line}\n`);
}

// The container indexes only /oid (infra/projection.bicep): a WHERE clause would scan every record, so
// the code sends none and filters in the client; status reads are scoped to their own partition.
function select(query, docs, partitionKey) {
  const text = typeof query === 'string' ? query : query.query;
  if (/\bWHERE\b/i.test(text)) throw new Error(`stand-in Cosmos: the container indexes only /oid; a WHERE clause scans every record: ${text}`);
  const all = Object.values(docs);
  return partitionKey !== undefined ? all.filter((d) => d.oid === partitionKey) : all;
}

class Items {
  query(query, { maxItemCount = 1000, partitionKey } = {}) {
    if (process.env.FAKE_COSMOS_FAIL === 'read') throw new Error('stand-in Cosmos read failure');
    log(`query ${typeof query === 'string' ? query : query.query}${partitionKey !== undefined ? ` partition=${partitionKey}` : ''}`);
    const rows = select(query, load().docs, partitionKey);
    let offset = 0;
    return {
      hasMoreResults: () => offset === 0 || offset < rows.length,
      fetchNext: async () => {
        const resources = rows.slice(offset, offset + maxItemCount);
        offset += maxItemCount;
        return { resources };
      },
    };
  }

  async executeBulkOperations(operations) {
    const store = load();
    const results = operations.map((op) => {
      log(`bulk ${op.operationType} ${op.id ?? op.resourceBody?.id ?? ''}`);
      if (process.env.FAKE_COSMOS_FAIL === 'write') return { statusCode: 503 };
      if (op.operationType === 'Upsert') {
        store.docs[`${op.resourceBody.id}|${op.partitionKey}`] = withEtag(op.resourceBody, store);
        return { statusCode: 200 };
      }
      if (op.operationType === 'Delete') {
        delete store.docs[`${op.id}|${op.partitionKey}`];
        return { statusCode: 204 };
      }
      return { statusCode: 400 };
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
  constructor(options) {
    this.options = options;
  }

  database() {
    return { container: () => ({
      items: new Items(),
      item: (id, partitionKey) => ({
        read: async () => {
          log(`point-read ${id}|${partitionKey}`);
          const store = load();
          const resource = store.docs[`${id}|${partitionKey}`];
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
          log(`replace ${key}${options.accessCondition ? ' if-match' : ''}`);
          if (!current) {
            const error = new Error('not found');
            error.code = 404;
            error.statusCode = 404;
            throw error;
          }
          if (options.accessCondition?.condition && current._etag !== options.accessCondition.condition) {
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
          log(`delete ${key}${options.accessCondition ? ' if-match' : ''}`);
          if (!current) {
            const error = new Error('not found');
            error.code = 404;
            error.statusCode = 404;
            throw error;
          }
          if (options.accessCondition?.condition && current._etag !== options.accessCondition.condition) {
            const error = new Error('precondition failed');
            error.code = 412;
            error.statusCode = 412;
            throw error;
          }
          delete store.docs[key];
          save(store);
          return {};
        },
      }),
    }) };
  }
}

function withEtag(doc, store) {
  store.etagCounter = (store.etagCounter ?? 0) + 1;
  return { ...doc, _etag: `"${store.etagCounter}"` };
}
