import assert from 'node:assert/strict';
import { test } from 'node:test';
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { chromium } from 'playwright';
import { Redactor, catalogWrite, snapshotText, capturePixels } from '../guide/lib/turnstile-live.mjs';
import { executionMode, managerClaims, freshRole, directWiderRoles } from '../guide/capture-turnstile-manager.mjs';
import { chosenOption } from '../guide/lib/azure-targets.mjs';

export function manifestProblems(images, entries, readImage) {
  const problems = [];
  const seen = new Set();
  for (const entry of entries) {
    if (seen.has(entry.image)) problems.push(`duplicate: ${entry.image}`);
    seen.add(entry.image);
    if (entry.live !== true) problems.push(`not live: ${entry.image}`);
    if (!/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z$/.test(entry.captured_at_utc ?? '')
      || !Number.isFinite(Date.parse(entry.captured_at_utc))) problems.push(`date missing/invalid: ${entry.image}`);
    if (!entry.route && !entry.command) problems.push(`source missing: ${entry.image}`);
    if (!entry.identity_kind || !entry.tool) problems.push(`method missing: ${entry.image}`);
    if (!/^[a-f0-9]{40}$/.test(entry.accel_commit ?? '')
      || !/^[a-f0-9]{40}$/.test(entry.fork_commit ?? '')) problems.push(`revision missing: ${entry.image}`);
    if (entry.redaction?.applied !== true || entry.redaction?.leak_check_passed !== true)
      problems.push(`redaction not proved: ${entry.image}`);
    if (readImage && images.includes(entry.image)) {
      const actual = createHash('sha256').update(readImage(entry.image)).digest('hex');
      if (entry.sha256 !== actual) problems.push(`pixels changed: ${entry.image}`);
    }
  }
  for (const image of images) if (!seen.has(image)) problems.push(`manifest entry missing: ${image}`);
  for (const entry of entries) if (!images.includes(entry.image)) problems.push(`image missing: ${entry.image}`);
  return problems;
}

test('every shipped/referenced Turnstile image has live dated, redacted provenance tied to its pixels', () => {
  const root = process.cwd();
  const manifest = path.join(root, 'docs/guide/turnstile-captures.json');
  assert.ok(fs.existsSync(manifest), 'Turnstile live capture manifest is missing');
  const document = fs.readFileSync(path.join(root, 'docs/TURNSTILE.md'), 'utf8');
  const referenced = [...document.matchAll(/!\[[^\]]*\]\(guide\/(turnstile-[^)]+\.png)\)/g)].map((m) => m[1]);
  const shipped = fs.readdirSync(path.join(root, 'docs/guide')).filter((name) => /^turnstile-.*\.png$/.test(name));
  assert.ok(referenced.length >= 22);
  const images = [...new Set([...referenced, ...shipped])];
  const { captures } = JSON.parse(fs.readFileSync(manifest, 'utf8'));
  assert.ok(Array.isArray(captures));
  assert.deepEqual(manifestProblems(images, captures, (name) => fs.readFileSync(path.join(root, 'docs/guide', name))), []);
});

const valid = {
  image: 'turnstile-example.png', live: true, captured_at_utc: '2026-09-24T16:00:00.000Z',
  route: '/?page=budgets', identity_kind: 'owner_cli_code', tool: 'Playwright',
  accel_commit: 'a'.repeat(40), fork_commit: 'b'.repeat(40),
  redaction: { applied: true, leak_check_passed: true },
  sha256: createHash('sha256').update('pixels').digest('hex'),
};
const check = (entries) => manifestProblems([valid.image], entries, () => Buffer.from('pixels'));
test('valid evidence is accepted', () => assert.deepEqual(check([valid]), []));
for (const [name, mutate, expected] of [
  ['missing entry', () => [], 'manifest entry missing'],
  ['not live', () => [{ ...valid, live: false }], 'not live'],
  ['missing date', () => [{ ...valid, captured_at_utc: undefined }], 'date missing'],
  ['non-UTC date', () => [{ ...valid, captured_at_utc: '2026-09-24' }], 'date missing'],
  ['missing source', () => [{ ...valid, route: undefined }], 'source missing'],
  ['failed redaction', () => [{ ...valid, redaction: { applied: true, leak_check_passed: false } }], 'redaction not proved'],
  ['changed pixels', () => [{ ...valid, sha256: '0'.repeat(64) }], 'pixels changed'],
  ['duplicate capture', () => [valid, valid], 'duplicate'],
]) {
  test(`mutation is caught: ${name}`, () => assert.ok(check(mutate()).some((p) => p.includes(expected))));
}

test('runtime redaction removes names, emails, private object ids and sign-in codes', () => {
  const redact = new Redactor([['Private Person', 'Example Owner'], ['private-team', 'sales-emea']]);
  const raw = 'Private Person private-team someone@private.example.org aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee login_code=abcdefghijklmnopqrstuvwxyz';
  assert.ok(redact.leaks(raw).length >= 3);
  assert.deepEqual(redact.leaks(redact.redact(raw)), []);
  assert.match(redact.redact(raw), /Example Owner sales-emea developer@contoso.com/);
});
test('a distinctive private value is removed inside a longer derived name, and one that survives is a leak', () => {
  // A deployment suffix reappears inside names built from it, such as a storage account
  // shown as an environment variable on another resource's blade.
  const redact = new Redactor([['privatesuffix', 'contoso'], ['ab12cd', 'contoso'], ['AUM', 'Product']]);
  const raw = 'streportsprivatesuffix stab12cdlogs AUM.Manager aumovio-pipeline';
  assert.ok(redact.leaks(raw).includes('known identifier'));
  assert.ok(redact.leaks('streportsprivatesuffix').includes('known identifier'));
  assert.ok(redact.leaks('stab12cdlogs').includes('known identifier'));
  assert.deepEqual(redact.leaks('aumovio-pipeline'), []);
  const safe = redact.redact(raw);
  assert.deepEqual(redact.leaks(safe), []);
  assert.equal(safe, 'streportscontoso stcontosologs Product.Manager aumovio-pipeline');
});
test('a replacement that happens to contain another private value is not itself a leak', () => {
  const redact = new Redactor([['private-project', 'contoso-app'], ['privatesuffix', 'private-projection']]);
  const safe = redact.redact('resolver-privatesuffix');
  assert.equal(safe, 'resolver-private-projection');
  assert.deepEqual(redact.leaks(safe), []);
  assert.ok(redact.leaks('private-project resolver-private-projection').includes('known identifier'));
});
test('a surviving unknown email or token refuses a capture rather than claiming redaction', () => {
  const redact = new Redactor();
  assert.ok(redact.leaks('another@private.example.org').includes('email'));
  assert.ok(redact.leaks('eyJ' + 'x'.repeat(20) + '.payload.signature').includes('credential'));
  assert.deepEqual(redact.leaks('admin@contoso.com 00000000-0000-0000-0000-000000000000'), []);
  const resource = 'evhns-tsclaude-example123.servicebus.windows.net';
  assert.ok(redact.leaks(resource).includes('deployment resource'));
  assert.deepEqual(redact.leaks(redact.redact(resource)), []);
});
test('catalog restoration preserves every authored field but excludes save audit metadata', () => {
  const original = { organizations: [{ id: 'a', name: 'A', parent_id: null, external_ref: 'group:a', attributes: { custom: true } }],
    departments: [{ id: 'a', name: 'Direct', parent_id: 'a', external_ref: null, attributes: {} }],
    default_department_id: 'a', updated_at: 'now', updated_by: 'owner' };
  const write = catalogWrite(original);
  assert.equal('updated_at' in write, false);
  assert.equal('parent_id' in write.organizations[0], false);
  assert.deepEqual(write.organizations[0].attributes, { custom: true });
  assert.equal(write.departments[0].parent_id, 'a');
});
test('Phase 2 is read-only by default and needs two explicit execution flags', () => {
  assert.equal(executionMode([]), 'dry-run');
  assert.equal(executionMode(['--dry-run']), 'dry-run');
  assert.throws(() => executionMode(['--execute']), /requires/);
  assert.throws(() => executionMode(['--execute', '--lead-go', '--dry-run']), /requires/);
  assert.equal(executionMode(['--execute', '--lead-go']), 'execute');
});
test('a cached Admin, Viewer, missing group or overage token can never be presented as a manager', () => {
  const manager = { roles: ['Turnstile.Manager'], groups: ['unit-group'] };
  assert.equal(managerClaims(manager, 'unit-group'), true);
  assert.equal(managerClaims({ ...manager, roles: [...manager.roles, 'Turnstile.Admin'] }, 'unit-group'), false);
  assert.equal(managerClaims({ ...manager, roles: [...manager.roles, 'Turnstile.Viewer'] }, 'unit-group'), false);
  assert.equal(managerClaims({ ...manager, roles: [...manager.roles, 'Another.Role'] }, 'unit-group'), false);
  assert.equal(managerClaims(manager, 'other-group'), false);
  assert.equal(managerClaims({ ...manager, hasgroups: true }, 'unit-group'), false);
  assert.equal(managerClaims({ ...manager, hasgroups: false }, 'unit-group'), false);
});
test('role-transition proof rejects tokens minted before the transition', () => {
  assert.equal(freshRole({ iat: 100, roles: ['Turnstile.Manager'] }, 'Turnstile.Manager', 100_000), true);
  assert.equal(freshRole({ iat: 98, roles: ['Turnstile.Manager'] }, 'Turnstile.Manager', 100_000), false);
  assert.equal(freshRole({ iat: 100, roles: ['Turnstile.Admin'] }, 'Turnstile.Manager', 100_000), false);
  assert.equal(freshRole({ roles: ['Turnstile.Admin'] }, 'Turnstile.Admin', 100_000), false);
  assert.equal(freshRole({ iat: 700, roles: ['Turnstile.Manager'] }, 'Turnstile.Manager', 1_000_000, 300), true);
  assert.equal(freshRole({ iat: 698, roles: ['Turnstile.Manager'] }, 'Turnstile.Manager', 1_000_000, 300), false);
});
test('direct Admin or Viewer assignments block a group-only manager transition before writes', () => {
  const roles = [{ id: 'admin', value: 'Turnstile.Admin' }, { id: 'viewer', value: 'Turnstile.Viewer' },
    { id: 'manager', value: 'Turnstile.Manager' }];
  const assignments = [{ principalId: 'self', appRoleId: 'admin' }, { principalId: 'self', appRoleId: 'viewer' },
    { principalId: 'self', appRoleId: 'manager' }, { principalId: 'another-user', appRoleId: 'admin' }];
  assert.deepEqual(directWiderRoles(assignments, roles, 'self'), ['Turnstile.Admin', 'Turnstile.Viewer']);
  assert.deepEqual(directWiderRoles(assignments, roles, 'unassigned'), []);
});
test('broker renewal is explicit and passes the scope through the environment, never shell interpolation', async () => {
  const { entraToken } = await import('../guide/lib/entra-token.mjs');
  const scope = 'api://example/Turnstile.Manage';
  assert.equal(entraToken(scope, { runAz: (args) => {
    assert.deepEqual(args, ['account', 'get-access-token', '--scope', scope, '--query', 'accessToken', '-o', 'tsv']);
    return 'ordinary-token';
  } }), 'ordinary-token');
  assert.equal(entraToken(scope, { renew: true, runAz: () => assert.fail('must not fall back to cached acquisition'),
    runPs: (script, env) => {
      assert.equal(env.P53_RENEW_SCOPE, scope);
      assert.ok(env.P53_RENEW_SCRIPT.endsWith('renew-entra-token.py'));
      assert.ok(!script.includes(scope));
      return 'renewed-token';
    },
  }), 'renewed-token');
});
test('failed broker renewal propagates instead of silently accepting a cached token', async () => {
  const { entraToken } = await import('../guide/lib/entra-token.mjs');
  assert.throws(() => entraToken('api://example/.default', { renew: true,
    runPs: () => { throw new Error('renewal unavailable'); },
    runAz: () => assert.fail('must not retry through cache'),
  }), /renewal unavailable/);
});
test('the frozen rendered-DOM detector joins split SVG labels and checks displayed input values', () => {
  const snapshot = {
    strings: ['visible', 'block', 'text', 'tspan', '#text', 'person@pri', 'vate.example.org', 'INPUT', 'another@private.example.org'],
    documents: [{
      nodes: {
        nodeType: [1, 1, 3, 1, 3, 1], parentIndex: [-1, 0, 1, 0, 3, -1],
        nodeName: [2, 3, 4, 3, 4, 7], nodeValue: [-1, -1, 5, -1, 6, -1],
        attributes: [[], [], [], [], [], []], inputValue: { index: [5], value: [8] },
      },
      layout: { nodeIndex: [0, 1, 2, 3, 4, 5], styles: Array.from({ length: 6 }, () => [1, 0]) },
    }],
  };
  const text = snapshotText(snapshot);
  assert.ok(text.includes('person@private.example.org'));
  assert.ok(text.includes('another@private.example.org'));
  assert.ok(new Redactor().leaks(text).includes('email'));
});

test('legacy capture and inspector tools do not embed deployment targets or historical transcripts', () => {
  for (const file of [
    'guide/capture.mjs', 'guide/capture-entra.mjs', 'guide/render-terminal.mjs',
    'guide/render-turnstile.mjs', 'scripts/Capture-Transcripts.ps1', 'scripts/inspect-proxy.mjs',
  ]) {
    const source = fs.readFileSync(file, 'utf8');
    assert.doesNotMatch(source, /https:\/\/[a-z0-9-]+\.(?:services\.ai\.azure\.com|azure-api\.net)/i, file);
    const privateIds = [...source.matchAll(/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi)]
      .map(([value]) => value.toLowerCase())
      .filter((value) => value !== '04b07795-8ddb-461a-bbee-02f9e1bf7b46' && !value.startsWith('00000000-0000-0000-0000-'));
    assert.deepEqual(privateIds, [], file);
  }
  assert.doesNotMatch(fs.readFileSync('guide/render-terminal.mjs', 'utf8'), /const shots\s*=\s*\[/);
});

test('discovery accepts only real selections and refuses ambiguous unattended choices', () => {
  const options = [{ id: 'resource-a', name: 'A' }, { id: 'resource-b', name: 'B' }];
  assert.equal(chosenOption(options, 'B', undefined, true).id, 'resource-b');
  assert.equal(chosenOption(options, undefined, 'resource-a', true).name, 'A');
  assert.equal(chosenOption(options, undefined, undefined, false), null);
  assert.throws(() => chosenOption(options, undefined, undefined, true), /explicit parameter/);
  assert.throws(() => chosenOption(options, 'missing', undefined, true), /missing or ambiguous/);
  assert.throws(() => chosenOption([...options, { id: 'another', name: 'A' }], 'A', undefined, true), /ambiguous/);
});

test('capture redacts child frames and refuses to rely on an uninspected iframe', async () => {
  const browser = await chromium.launch({ headless: true });
  try {
    const page = await browser.newPage();
    await page.setContent(`<main>Controlled browser fixture for capture validation, not live deployment evidence.</main>
      <iframe srcdoc="<p>Private Person person@private.example.org aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee</p>"></iframe>`);
    await page.frames()[1].waitForLoadState();
    const pixels = await capturePixels(page, 'fixture-not-published.png', new Redactor([['Private Person', 'Example Owner']]), null, false);
    assert.ok(pixels.length > 100);
    const text = await page.frames()[1].locator('body').innerText();
    assert.ok(text.includes('Example Owner'));
    assert.ok(text.includes('developer@contoso.com'));
    assert.ok(!text.includes('aaaaaaaa'));
  } finally { await browser.close(); }
});
