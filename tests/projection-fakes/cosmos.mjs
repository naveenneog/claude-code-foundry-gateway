// Stand-in @azure/cosmos for the projection renewal simulation (tests/Test-ProjectionRenewalRuns.ps1).
// One container, kept in the JSON file FAKE_COSMOS_STORE so that separate runs share it. It answers
// only the queries the sync entry points send, and refuses any other query instead of guessing.
import { appendFileSync, existsSync, readFileSync, writeFileSync } from 'node:fs';

const STATUS = 'projection-reconciliation-status';

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

function select(query, docs) {
  const text = typeof query === 'string' ? query : query.query;
  const params = Object.fromEntries((query.parameters ?? []).map((p) => [p.name, p.value]));
  const all = Object.values(docs);
  if (text.includes("WHERE c.type = 'projection-reconciliation-status'")) {
    return all.filter((d) => d.type === STATUS && d.tenantId === params['@tenantId'] &&
      d.accountResourceId === params['@accountResourceId'] && d.databaseName === params['@databaseName'] &&
      d.containerName === params['@containerName']);
  }
  if (text.includes("WHERE NOT IS_DEFINED(c.type) OR c.type != 'projection-reconciliation-status'")) {
    return all.filter((d) => d.type !== STATUS);
  }
  if (/^SELECT c\.id, c\.oid, c\.tier, c\.businessUnit, c\.tenantId, c\.reconciliationGeneration, c\.lastVerifiedAt, c\.expiresAt FROM c$/.test(text)) {
    return all;
  }
  throw new Error(`stand-in Cosmos does not answer this query: ${text}`);
}

class Items {
  query(query, { maxItemCount = 1000 } = {}) {
    if (process.env.FAKE_COSMOS_FAIL === 'read') throw new Error('stand-in Cosmos read failure');
    log(`query ${typeof query === 'string' ? query : query.query}`);
    const rows = select(query, load().docs);
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
        store.docs[`${op.resourceBody.id}|${op.partitionKey}`] = op.resourceBody;
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
          return { resource };
        },
      }),
    }) };
  }
}
