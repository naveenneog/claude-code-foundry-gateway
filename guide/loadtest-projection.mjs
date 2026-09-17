/**
 * Capacity test for the entitlement projection.
 *
 * docs/SCALE.md says the traffic half of the load envelope is unmeasured, and
 * that a capacity test which only proves 500,000 keys can be created proves
 * nothing. This proves the thing that actually decides P19:
 *
 *   a lookup stays a point read as the projection grows
 *
 * That is the architectural claim. Cosmos point-read cost is a function of the
 * document, not of how many documents sit beside it - but only if the partition
 * key spreads them. Partitioned on /oid, every identity is its own logical
 * partition. Partitioned on /tenantId, as the obvious reading of ADR-0005
 * suggests, all 500,000 would share one, which looks identical at eight
 * developers and collapses at scale.
 *
 * So the test loads identities and then reads records written early, late, and
 * at random, reporting request units and latency for each. If the numbers move
 * with collection size, the partition strategy is wrong.
 *
 *   node guide/loadtest-projection.mjs --count 500000
 *
 * Writes cost real money: roughly 5 RU each, so 500,000 is about 2.5M RU, about
 * $0.63 at the rate in ADR-0011. Reads are 1 RU.
 */
import { CosmosClient } from '@azure/cosmos';
import { DefaultAzureCredential } from '@azure/identity';

const args = process.argv.slice(2);
const argOf = (name, fallback) => {
  const i = args.indexOf(name);
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
};

const endpoint = argOf('--endpoint', 'https://cosmos-claude-gw-fzgql9.documents.azure.com:443/');
const total = Number(argOf('--count', '500000'));
const batchSize = Number(argOf('--batch', '100'));
const concurrency = Number(argOf('--concurrency', '32'));
const tenantId = argOf('--tenant', 'fdpo-load-test');

const client = new CosmosClient({ endpoint, aadCredentials: new DefaultAzureCredential() });
const container = client.database('claude').container('entitlement');

// The record ADR-0005 specifies, plus nothing. Every field is one the gateway
// or the failure contract actually reads; a projection that carries more is a
// projection that costs more to write on every resync.
const record = (n) => {
  const oid = `ld${String(n).padStart(8, '0')}-0000-4000-8000-${String(n).padStart(12, '0')}`;
  return {
    id: `${tenantId}|${oid}`,
    oid,
    tenantId,
    tier: n % 7 === 0 ? 'premium' : 'standard',
    businessUnit: `bu-${n % 250}`,
    authorized: true,
    mappingVersion: 1,
    effectiveFrom: '2026-09-17T00:00:00Z',
    lastVerifiedAt: new Date().toISOString(),
  };
};

async function writeBatch(start, count) {
  const ops = [];
  for (let i = start; i < start + count; i++) {
    const doc = record(i);
    ops.push(container.items.upsert(doc).then((r) => r.requestCharge));
  }
  const charges = await Promise.all(ops);
  return charges.reduce((a, b) => a + b, 0);
}

async function pointRead(n) {
  const doc = record(n);
  const t0 = process.hrtime.bigint();
  const res = await container.item(doc.id, doc.oid).read();
  const ms = Number(process.hrtime.bigint() - t0) / 1e6;
  return { ru: res.requestCharge, ms, found: !!res.resource, tier: res.resource?.tier };
}

console.log(`Projection capacity test`);
console.log(`  endpoint  ${endpoint}`);
console.log(`  loading   ${total.toLocaleString()} identities\n`);

// Read before the load, so the "empty collection" number is a real measurement
// rather than an assumption about what small means.
let baseline = null;
try {
  await container.items.upsert(record(0));
  baseline = await pointRead(0);
  console.log(`  baseline point read, near-empty collection: ${baseline.ru} RU, ${baseline.ms.toFixed(1)} ms\n`);
} catch (e) {
  console.error(`  baseline read failed: ${e.message}`);
  process.exit(1);
}

const t0 = Date.now();
let written = 0;
let ruTotal = 0;

for (let start = 0; start < total; start += batchSize * concurrency) {
  const waves = [];
  for (let c = 0; c < concurrency; c++) {
    const from = start + c * batchSize;
    if (from >= total) break;
    waves.push(writeBatch(from, Math.min(batchSize, total - from)));
  }
  const charges = await Promise.all(waves);
  ruTotal += charges.reduce((a, b) => a + b, 0);
  written = Math.min(start + batchSize * concurrency, total);

  if (written % 50000 === 0 || written >= total) {
    const secs = (Date.now() - t0) / 1000;
    console.log(`  ${written.toLocaleString().padStart(9)} written  ${(written / secs).toFixed(0).padStart(6)}/s  ${ruTotal.toFixed(0)} RU`);
  }
}

const loadSecs = (Date.now() - t0) / 1000;
console.log(`\n  loaded ${written.toLocaleString()} in ${loadSecs.toFixed(0)}s, ${ruTotal.toFixed(0)} RU total`);
console.log(`  write cost at ADR-0011 rates: $${((ruTotal / 1000000) * 0.25).toFixed(2)}\n`);

// The measurement that decides it. If these move with collection size, the
// partition strategy is wrong and 500,000 will not hold.
console.log('  Point reads against the full collection');
const probes = [0, 1, Math.floor(total / 2), total - 2, total - 1];
const results = [];
for (const n of probes) {
  const r = await pointRead(n);
  results.push(r);
  console.log(`    record ${String(n).padStart(9)}  ${r.ru} RU  ${r.ms.toFixed(1)} ms  ${r.found ? r.tier : 'MISSING'}`);
}

const rus = results.map((r) => r.ru);
const maxRu = Math.max(...rus);
const spread = maxRu - Math.min(...rus);

console.log('');
console.log(`  RU per lookup: ${Math.min(...rus)} to ${maxRu}`);
console.log(`  Baseline on a near-empty collection was ${baseline.ru} RU.`);
console.log(
  spread === 0 && maxRu === baseline.ru
    ? '  Unchanged by collection size - the point read holds.'
    : '  CHANGED with collection size - check the partition key.',
);
