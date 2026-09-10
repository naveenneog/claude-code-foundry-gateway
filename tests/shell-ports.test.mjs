import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

const existing = new Set(['Show-Banner', 'Test-Prerequisites', 'get-foundry-token', 'Setup-ClaudeWorkstation', 'Invoke-ShellTests']);
const sources = readdirSync('scripts').filter(name => name.endsWith('.ps1') && !existing.has(name.slice(0, -4)));
const kebab = name => name.replace(/([a-z0-9])([A-Z])/g, '$1-$2').toLowerCase();

test('boundary validation rejects credential redirection and malformed identity maps', async () => {
  const { gatewayUrl, guid, overrides, request } = await import('../scripts/lib/common.mjs');
  for (const url of ['http://example.org', 'https://user:pass@example.org', 'https://example.org/#fragment']) {
    assert.throws(() => gatewayUrl(url));
  }
  assert.equal(gatewayUrl('https://gateway.azure-api.net/claude'), 'https://gateway.azure-api.net/claude');
  assert.throws(() => guid('bad-id'));
  assert.throws(() => overrides(',invalid=100,'));
  assert.throws(() => overrides(',00000000-0000-0000-0000-000000000001=oops,'));
  let called = false;
  await assert.rejects(request('https://evil.example/next', 'https://graph.microsoft.com', {
    token: () => { called = true; return 'synthetic'; }
  }));
  assert.equal(called, false);
});

test('local ports generate escaped policy and import memory idempotently', async () => {
  const { mkdtempSync, rmSync, writeFileSync } = await import('node:fs');
  const { tmpdir } = await import('node:os');
  const { join } = await import('node:path');
  const { local } = await import('../scripts/lib/local.mjs');
  const root = mkdtempSync(join(tmpdir(), 'shell-port-'));
  try {
    await local('new-claude-code-policy', { 'gateway-url': 'https://gateway.azure-api.net/claude', 'sonnet-model': '<model&>', 'output-path': root });
    const settings = JSON.parse(readFileSync(join(root, 'claude-code.managed-settings.json'), 'utf8'));
    assert.equal(settings.env.CLAUDE_CODE_USE_FOUNDRY, '1');
    assert.ok(settings.permissions.deny.includes('Read(./.env)'));
    assert.match(readFileSync(join(root, 'claude-code.mobileconfig'), 'utf8'), /&lt;model&amp;&gt;/);
    const apply = spawnSync('bash', [join(root, 'claude-code.apply.sh'), '--dry-run'], { encoding: 'utf8' });
    assert.equal(apply.status, 0, apply.stderr);
    assert.match(apply.stdout, /managed-settings.json/);
    assert.match(readFileSync(join(root, 'claude-code.apply.ps1'), 'utf8'), /SupportsShouldProcess/);
    const source = join(root, 'memory.md');
    const destination = join(root, 'CLAUDE.md');
    writeFileSync(source, 'Remember this.');
    writeFileSync(destination, '<!-- claude-memory-import: begin -->\nold-memory\n<!-- claude-memory-import: end -->');
    await local('import-claude-memory', { path: source, destination });
    await local('import-claude-memory', { path: source, destination });
    assert.equal(readFileSync(destination, 'utf8').match(/Remember this\./g).length, 1);
    assert.doesNotMatch(readFileSync(destination, 'utf8'), /old-memory/);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('bypass findings cause a failing command status', async () => {
  const { exitCodeForResult } = await import('../scripts/lib/cli.mjs');
  assert.equal(exitCodeForResult('get-claude-bypass', { bypass_count: 1 }), 1);
  assert.equal(exitCodeForResult('get-claude-bypass', { bypass_count: 0 }), 0);
  assert.equal(exitCodeForResult('get-claude-budget', {}), 0);
});

test('generated PowerShell installer preserves the absolute Windows destination', async () => {
  const { mkdtempSync, rmSync } = await import('node:fs');
  const { tmpdir } = await import('node:os');
  const { join } = await import('node:path');
  const { local } = await import('../scripts/lib/local.mjs');
  const root = mkdtempSync(join(tmpdir(), 'policy-path-'));
  try {
    await local('new-claude-code-policy', { 'gateway-url': 'https://example.org/claude', 'output-path': root });
    assert.ok(readFileSync(join(root, 'claude-code.apply.ps1'), 'utf8').includes(String.raw`C:\Program Files\ClaudeCode`));
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('CSV roster preserves quoted values and rejects malformed input', async () => {
  const { csvRows } = await import('../scripts/lib/gateway.mjs');
  assert.deepEqual(csvRows('\uFEFFEmail,Tier\r\n"a,b@example.org",premium\r\n'), [{ Email: 'a,b@example.org', Tier: 'premium' }]);
  for (const value of ['Email,Email\na,b', 'Email,Tier\na', 'Email\n"unclosed', 'Email\n"closed"tail', ',Tier\na,b']) {
    assert.throws(() => csvRows(value));
  }
});

test('entitlement import resolves every target before writing and supports default groups', async () => {
  const { mkdtempSync, rmSync, writeFileSync } = await import('node:fs');
  const { tmpdir } = await import('node:os');
  const { join } = await import('node:path');
  const { importEntitlement } = await import('../scripts/lib/gateway.mjs');
  const root = mkdtempSync(join(tmpdir(), 'roster-port-'));
  const standard = '11111111-1111-1111-1111-111111111111';
  const premium = '22222222-2222-2222-2222-222222222222';
  const groups = [];
  const writes = [];
  const services = {
    userId: async value => value,
    groupId: async name => { groups.push(name); return name; },
    groupMembers: async name => { if (name === 'claude-code-premium-sombaner') throw new Error('Synthetic denied target'); return []; },
    request: async (...args) => { writes.push(args); }
  };
  try {
    const csv = join(root, 'roster.csv');
    writeFileSync(csv, `Email,Plan\n${standard},Standard\n${premium},PREMIUM\n`);
    await assert.rejects(importEntitlement({ csv, execute: true }, services), /Synthetic denied target/);
    assert.deepEqual(groups, ['claude-code-standard-sombaner', 'claude-code-premium-sombaner']);
    assert.equal(writes.length, 0);
    services.groupMembers = async () => [];
    const report = join(root, 'report.csv');
    const rows = await importEntitlement({ csv, 'report-path': report }, services);
    assert.deepEqual(rows.map(row => row.status), ['would-add', 'would-add']);
    assert.match(readFileSync(report, 'utf8'), /^"object_id","user","tier","group","status"/);
    assert.equal(writes.length, 0);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('all nineteen missing equivalents have offline help and dry runs', () => {
  assert.equal(sources.length, 19);
  for (const name of sources) {
    const file = `scripts/${kebab(name.slice(0, -4))}.sh`;
    assert.match(readFileSync(file, 'utf8'), /^#!\/usr\/bin\/env bash/);
    for (const option of ['--help', '--dry-run']) {
      const result = spawnSync('bash', [file, option], {
        encoding: 'utf8', timeout: 5000,
        env: { PATH: process.env.PATH, HOME: '/nonexistent', AZURE_CONFIG_DIR: '/nonexistent' }
      });
      assert.equal(result.status, 0, `${file} ${option}: ${result.stderr}`);
      assert.match(result.stdout, option === '--help' ? /Usage:/ : /"dryRun": true/);
    }
  }
});

test('entitlement sync makes premium exclusive and propagates failed writes', async () => {
  const { syncAccess } = await import('../scripts/lib/gateway.mjs');
  const first = '00000000-0000-0000-0000-000000000001';
  const second = '00000000-0000-0000-0000-000000000002';
  const writes = [];
  const context = { getValue: async () => ',,', setValue: async (...args) => writes.push(args) };
  const options = { 'additional-standard-oids': `${first},${second}`, 'additional-premium-oids': first };
  await syncAccess(context, options, async () => []);
  assert.deepEqual(writes, [['allow-standard', `,${second},`], ['allow-premium', `,${first},`]]);
  await assert.rejects(syncAccess({ ...context, setValue: async () => { throw new Error('write failed'); } }, options, async () => []), /write failed/);
  await assert.rejects(syncAccess({ ...context, getValue: async () => `,${first},` }, {}, async () => []), /empty/);
});

test('analytics preserves null counters and nests models', async () => {
  const { analyticsEnvelope } = await import('../scripts/lib/reports.mjs');
  const report = analyticsEnvelope([{ date: '2026-01-01', actor: 'example', model: 'sonnet', tokens_input: 4, tokens_output: 2 }], 'tenant');
  assert.equal(report.data[0].model_breakdown[0].tokens.input, 4);
  assert.equal(report.data[0].core_metrics.num_sessions, null);
  assert.equal(report.data[0].model_breakdown[0].estimated_cost.is_estimate, true);
});

test('analytics loads the repository query and uses the requested inclusive window', async () => {
  const { analyticsQuery } = await import('../scripts/lib/reports.mjs');
  assert.match(analyticsQuery({ date: '2026-01-03', days: 3 }), /let _day = datetime\(2026-01-01\);/);
  assert.match(analyticsQuery({ date: '2026-01-03', days: 3 }), /let _next = _day \+ 3d;/);
  assert.throws(() => analyticsQuery({ date: '2026-02-30' }), /valid/);
});

test('live dispatcher rejects invalid credential destinations before Azure CLI', async () => {
  const { run } = await import('../scripts/lib/ports.mjs');
  await assert.rejects(run('test-foundry-direct', { resource: 'bad/host#' }), /resource name/);
  await assert.rejects(run('debug-claude-code', { 'gateway-base-url': 'http://example.org' }), /HTTPS/);
});

test('local onboarding works without a distribution URL and transcripts contain executed plans', async () => {
  const { mkdtempSync, rmSync, writeFileSync } = await import('node:fs');
  const { tmpdir } = await import('node:os');
  const { join } = await import('node:path');
  const { local } = await import('../scripts/lib/local.mjs');
  const root = mkdtempSync(join(tmpdir(), 'local-port-'));
  try {
    const config = join(root, 'config.json');
    writeFileSync(config, JSON.stringify({ gatewayUrl: 'https://gateway.example/claude', tiers: { premium: { tokensPerDay: 1200 } } }));
    const result = await local('new-onboarding-email', { 'config-path': config, to: 'user@example.org', tier: 'premium', 'output-path': root });
    assert.match(readFileSync(`${result.output}.txt`, 'utf8'), /premium/);
    assert.match(readFileSync(`${result.output}.eml`, 'utf8'), /filename="claude-gateway.json"/);
    await local('capture-transcripts', { 'output-path': root });
    assert.match(readFileSync(join(root, 'set-claude-budget.txt'), 'utf8'), /"dryRun": true/);
  } finally { rmSync(root, { recursive: true, force: true }); }
});