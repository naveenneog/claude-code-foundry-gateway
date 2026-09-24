/**
 * Isolated, bounded projection measurement. Run inside the private network.
 * Create an EMPTY /oid-partitioned container named loadtest and grant the runner
 * access only to it. This program never creates or deletes Azure resources.
 * Delete the container and its temporary grant after preserving the JSON lines.
 *
 * node loadtest-projection.mjs --endpoint https://<account>.documents.azure.com
 *      --container loadtest --count 500000 --concurrency 32
 *
 * Requires the same @azure/cosmos and @azure/identity packages as sync/.
 */
const args = process.argv.slice(2);
const opt = (key, fallback) => { const i = args.indexOf(key); return i < 0 ? fallback : args[i + 1]; };
const endpoint = opt('--endpoint');
const containerName = opt('--container');
const total = Number(opt('--count', 500000));
const concurrency = Number(opt('--concurrency', 32));
if (containerName !== 'loadtest' || !/^https:\/\/[a-z0-9-]+\.documents\.azure\.com(?::443)?\/?$/.test(endpoint ?? '')) {
  console.error('An explicit Cosmos --endpoint and --container loadtest are required; entitlement is forbidden.');
  process.exit(2);
}
if (!Number.isInteger(total) || total < 1 || total > 500000 ||
    !Number.isInteger(concurrency) || concurrency < 1 || concurrency > 128) {
  console.error('count must be 1..500000 and concurrency 1..128');
  process.exit(2);
}
const { CosmosClient } = await import('@azure/cosmos');
const { DefaultAzureCredential } = await import('@azure/identity');
const client = new CosmosClient({ endpoint, aadCredentials: new DefaultAzureCredential() });
const container = client.database('claude').container(containerName);
const emit = (data) => console.log(JSON.stringify({ utc: new Date().toISOString(), ...data }));
const generation = '00000000-0000-4000-8000-000000000001';
const verifiedAt = new Date().toISOString();
const expiresAt = Math.floor(Date.now() / 1000) + 7200;
const record = (n) => {
  const oid = `${n.toString(16).padStart(8, '0')}-0000-4000-8000-${String(n).padStart(12, '0')}`;
  return {
    id: oid, oid, tenantId: '00000000-0000-4000-8000-000000000000',
    tier: n % 7 === 0 ? 'premium' : 'standard', businessUnit: 'sales',
    mappingVersion: 1, effectiveFrom: null,
    reconciliationGeneration: generation, lastVerifiedAt: verifiedAt, expiresAt,
  };
};
async function pointRead(n) {
  const d = record(n), start = performance.now();
  const r = await container.item(d.id, d.oid).read();
  if (r.resource?.oid !== d.oid) throw new Error(`Missing record ${n}`);
  return { n, ru: r.requestCharge, ms: performance.now() - start };
}
try {
  const { resources: before } = await container.items.query('SELECT VALUE COUNT(1) FROM c').fetchAll();
  if (before[0] !== 0) throw new Error('loadtest must be empty; refusing to overwrite an existing measurement');
  const start = performance.now();
  let charge = 0, written = 0, next = 1;
  charge += (await container.items.create(record(0))).requestCharge;
  written++;
  emit({ phase: 'baseline', read: await pointRead(0), count: total, concurrency });
  await Promise.all(Array.from({ length: concurrency }, async () => {
    for (;;) {
      const n = next++;
      if (n >= total) break;
      const r = await container.items.create(record(n));
      charge += r.requestCharge;
      written++;
      if (written % 10000 === 0) emit({ phase: 'write', written, ru: charge, seconds: (performance.now() - start) / 1000 });
    }
  }));
  const seconds = (performance.now() - start) / 1000;
  const { resources: after, requestCharge: countRu } = await container.items.query('SELECT VALUE COUNT(1) FROM c').fetchAll();
  if (after[0] !== total) throw new Error(`Cardinality mismatch: ${after[0]} not ${total}`);
  emit({ phase: 'loaded', written, confirmedCount: after[0], seconds, recordsPerSecond: written / seconds, writeRu: charge, countRu });
  const reads = [];
  for (const n of [...new Set([0, 1, Math.floor(total / 2), total - 2, total - 1].filter(n => n >= 0))]) {
    const samples = [];
    for (let i = 0; i < 100; i++) { const r = await pointRead(n); samples.push(r); reads.push(r); }
    emit({ phase: 'point-reads', n, samples });
  }
  const latencies = reads.map(r => r.ms).sort((a, b) => a - b);
  const p = q => latencies[Math.ceil(q * latencies.length) - 1];
  emit({ phase: 'complete', ok: true, count: after[0], writeRu: charge, seconds, recordsPerSecond: written / seconds,
    reads: reads.length, minRu: Math.min(...reads.map(r => r.ru)), maxRu: Math.max(...reads.map(r => r.ru)),
    p50: p(.5), p95: p(.95), p99: p(.99), max: p(1) });
} catch (e) {
  emit({ phase: 'failed', ok: false, error: e.message, code: e.code });
  process.exitCode = 1;
} finally { client.dispose(); }
