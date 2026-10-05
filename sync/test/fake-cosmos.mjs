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
    log(`query ${text}`);
    const docs = Object.values(load().docs);
    const rows = text.includes("projection-reconciliation-status")
      ? docs.filter((d) => d.type === 'projection-reconciliation-status')
      : docs.filter((d) => d.type !== 'projection-reconciliation-status');
    let done = false;
    return {
      hasMoreResults: () => !done,
      fetchNext: async () => {
        done = true;
        return { resources: rows };
      },
    };
  }

  async executeBulkOperations(operations) {
    const store = load();
    const results = operations.map((op) => {
      const id = op.id ?? op.resourceBody?.id ?? '';
      log(`bulk ${op.operationType} ${id}`);
      if (op.operationType === 'Upsert') store.docs[`${op.resourceBody.id}|${op.partitionKey}`] = op.resourceBody;
      if (op.operationType === 'Delete') delete store.docs[`${op.id}|${op.partitionKey}`];
      return { statusCode: op.operationType === 'Delete' ? 204 : 200 };
    });
    save(store);
    return results;
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
            return { resource };
          },
        }),
      }),
    };
  }
}
