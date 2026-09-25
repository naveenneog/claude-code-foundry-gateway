import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { spawnSync } from 'node:child_process';
import { specProblems, loadSteps, selectSteps, documentedOutputs, documentationProblems } from '../guide/lib/portal-specs.mjs';
import { AuthenticationSurface, authenticationReason, parseArguments, portalUrl, resolvePlan, runBatch } from '../guide/lib/portal-batch.mjs';
import { lockProfile } from '../guide/lib/portal-profile.mjs';

test('the repository publishes a portal capture spec contract and Turnstile example', () => {
  assert.ok(fs.existsSync(path.resolve('guide/captures/README.md')), 'Portal capture spec contract is missing');
  assert.ok(fs.existsSync(path.resolve('guide/captures/turnstile.json')), 'Turnstile portal example is missing');
});

const step = {
  id: 'example-overview', output: 'docs/guide/example.png',
  target: { discover: 'gateway', selectionKey: 'gateway' }, blade: '/overview',
  waitFor: { text: 'Gateway URL' }, settle: 1000, redaction: { mapEnv: 'PORTAL_REDACTIONS_FILE' },
};
const document = (value = step) => ({ version: 1, steps: [value] });
const problems = (mutate) => {
  const value = structuredClone(step);
  mutate(value);
  return specProblems(document(value));
};

test('all repository specs and built-ins validate and every output is documented', () => {
  const steps = loadSteps(process.cwd());
  const references = documentedOutputs(process.cwd());
  assert.ok(steps.some((item) => item.id === 'turnstile-app-overview'));
  assert.ok(steps.some((item) => item.id === 'gateway-overview'));
  assert.deepEqual(steps.filter((item) => !references.has(item.output)).map((item) => item.output), []);
});

test('logical selectors and operator-supplied name filters are valid', () => {
  assert.deepEqual(specProblems(document()), []);
  assert.deepEqual(specProblems(document({
    ...step, target: { discover: 'resource', resourceType: 'Microsoft.App/jobs', tags: { workload: 'turnstile' } },
  })), []);
  assert.deepEqual(specProblems(document({
    ...step, blade: undefined, target: { discover: 'entra-app', nameFilterEnv: 'APP_FILTER' },
    entraBlade: { kind: 'app-registration', name: 'Overview' },
  })), []);
});

for (const [name, mutation] of [
  ['literal resource name', (value) => { value.target.name = 'instance-with-a-private-name'; }],
  ['literal resource id', (value) => { value.target.resourceId = '/subscriptions/private/resourceGroups/private'; }],
  ['literal URL', (value) => { value.target.url = 'https://private.example.org'; }],
  ['literal name instead of env', (value) => { value.target.nameFilterEnv = 'my-resource-name'; }],
  ['literal GUID in selector', (value) => { value.waitFor = { selector: '#aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' }; }],
  ['absolute output', (value) => { value.output = 'C:/outside/file.png'; }],
  ['traversal output', (value) => { value.output = '../outside.png'; }],
  ['absolute POSIX output', (value) => { value.output = '/outside.png'; }],
  ['non-PNG output', (value) => { value.output = 'scripts/replace.mjs'; }],
  ['unknown discovery', (value) => { value.target.discover = 'invented'; }],
  ['generic resource without filter', (value) => { value.target = { discover: 'resource', resourceType: 'Microsoft.App/jobs' }; }],
  ['missing wait', (value) => { delete value.waitFor; }],
  ['ambiguous wait', (value) => { value.waitFor = { text: 'A', selector: 'B' }; }],
  ['missing redaction', (value) => { delete value.redaction; }],
  ['literal private map path', (value) => { value.redaction.mapEnv = 'C:/private/pairs.json'; }],
  ['credential action', (value) => { value.clicks = [{ text: 'Sign in' }]; }],
  ['commit action', (value) => { value.clicks = [{ text: 'Save' }]; }],
  ['named destructive action', (value) => { value.clicks = [{ text: 'Delete resource' }]; }],
  ['consent action', (value) => { value.clicks = [{ text: 'Grant admin consent for this tenant' }]; }],
  ['typing action', (value) => { value.clicks = [{ selector: 'input', fill: 'secret' }]; }],
  ['negative settle', (value) => { value.settle = -1; }],
  ['unbounded settle', (value) => { value.settle = 100000; }],
]) {
  test(`mutation rejected: ${name}`, () => assert.ok(problems(mutation).length > 0));
}

test('unknown --only IDs fail instead of silently capturing something else', () => {
  const steps = [step, { ...step, id: 'other', output: 'docs/guide/other.png' }];
  assert.deepEqual(selectSteps(steps, ['other']).map((item) => item.id), ['other']);
  assert.throws(() => selectSteps(steps, ['missing']), /Unknown --only/);
});
test('duplicate IDs/outputs and undocumented destinations fail the actual validators', () => {
  assert.throws(() => loadSteps(process.cwd(), { builtins: [step, { ...step, output: 'docs/guide/other.png' }] }), /duplicate id/);
  assert.throws(() => loadSteps(process.cwd(), { builtins: [step, { ...step, id: 'other' }] }), /duplicate output/);
  assert.deepEqual(documentationProblems([step], new Set([step.output])), []);
  assert.match(documentationProblems([step], new Set())[0], /not referenced by a document/);
});

test('argument parsing keeps profile use explicit and supports repeatable selections', () => {
  const args = parseArguments(['--dry-run', '--only', 'a,b', '--select', 'gateway=actual', '--non-interactive']);
  assert.equal(args.dryRun, true);
  assert.equal(args.profile, undefined);
  assert.deepEqual(args.only, ['a', 'b']);
  assert.equal(args.selections.gateway, 'actual');
  assert.throws(() => parseArguments(['--only']), /Missing value/);
  assert.throws(() => parseArguments(['--list', '--dry-run']), /not both/);
});

const tenant = '00000000-0000-0000-0000-000000000001';
const app = '00000000-0000-0000-0000-000000000002';
const principal = '00000000-0000-0000-0000-000000000003';
const target = { id: `/subscriptions/${tenant}/resourceGroups/example/providers/Microsoft.ApiManagement/service/example`, tenantId: tenant };
test('dry-run planning resolves every unique target with no browser dependency', async () => {
  let calls = 0;
  const plan = await resolvePlan([step, { ...step, id: 'second', blade: '/identity' }], async () => { calls++; return target; });
  assert.equal(calls, 1);
  assert.equal(plan.resolved.length, 2);
  assert.equal(plan.failed.length, 0);
  assert.ok(plan.resolved[1].url.endsWith('/identity'));
});
test('one failed discovery is reported while other targets are still resolved', async () => {
  const plan = await resolvePlan([step, { ...step, id: 'second', target: { discover: 'workspace' } }],
    async (selection) => { if (selection.discover === 'gateway') throw new Error('no gateway'); return target; });
  assert.equal(plan.failed.length, 1);
  assert.equal(plan.resolved.length, 1);
});
test('Entra URLs use only discovered identifiers and blade declarations', () => {
  assert.ok(portalUrl({ entraBlade: { kind: 'app-registration', name: 'AppRoles' } },
    { appId: app }).endsWith(`/AppRoles/appId/${app}`));
  assert.ok(portalUrl({ entraBlade: { kind: 'enterprise-application', name: 'Users' } },
    { appId: app, servicePrincipalId: principal }).includes(`/objectId/${principal}/appId/`));
  assert.throws(() => portalUrl({ entraBlade: { kind: 'group', name: 'Members' } }, { id: 'not-an-id' }), /valid group id/);
});

test('authentication detection distinguishes silent redirects from actual prompts', () => {
  assert.equal(authenticationReason({ url: 'https://login.microsoftonline.com/', texts: ['Redirecting'] }), null);
  assert.match(authenticationReason({ url: 'https://login.microsoftonline.com/', texts: ['Pick an account'] }), /Authentication prompt/);
  assert.equal(authenticationReason({ url: 'https://portal.azure.com/', texts: ['Sign-in logs', 'Sign in users quickly'] }), null);
});
test('the first authentication surface stops all later visits and reports remaining IDs', async () => {
  const plan = [0, 1, 2].map((id) => ({ step: { ...step, id: `step-${id}` }, url: `url-${id}` }));
  const visited = [];
  const result = await runBatch(plan, {
    navigate: async (url) => visited.push(url),
    ensureAuthenticated: async () => { if (visited.at(-1) === 'url-1') throw new AuthenticationSurface('Enter password'); },
    wait: async () => {}, click: async () => {}, settle: async () => {}, capture: async () => ({}),
  });
  assert.deepEqual(visited, ['url-0', 'url-1']);
  assert.equal(result.captured.length, 1);
  assert.equal(result.failed.length, 1);
  assert.equal(result.skipped.length, 1);
  assert.deepEqual(result.remaining, ['step-1', 'step-2']);
});
test('a non-auth blade failure is counted and does not masquerade as a capture', async () => {
  const result = await runBatch([{ step, url: 'url' }], {
    navigate: async () => {}, ensureAuthenticated: async () => {}, wait: async () => { throw new Error('missing blade'); },
    capture: async () => assert.fail('must not capture an unfinished page'),
  });
  assert.equal(result.failed.length, 1);
  assert.equal(result.captured.length, 0);
});

test('the profile lock refuses a second browser and releases only once, using in-memory IO', () => {
  let exists = false;
  let removals = 0;
  const io = {
    existsSync: () => true, statSync: () => ({ isDirectory: () => true }),
    openSync: (_file, mode) => { assert.equal(mode, 'wx'); if (exists) throw Object.assign(new Error(), { code: 'EEXIST' }); exists = true; return 1; },
    writeFileSync: () => {}, closeSync: () => {},
    unlinkSync: () => { exists = false; removals++; },
  };
  const release = lockProfile('not-a-real-profile', io);
  assert.throws(() => lockProfile('not-a-real-profile', io), /locked/);
  release(); release();
  assert.equal(removals, 1);
  lockProfile('not-a-real-profile', io)();
  assert.equal(removals, 2);
});

test('--list validates and enumerates specs without Azure or a browser profile', () => {
  const result = spawnSync(process.execPath, ['guide/capture-portal.mjs', '--list'], {
    cwd: process.cwd(), encoding: 'utf8', env: { ...process.env, AZURE_CONFIG_DIR: 'not-a-real-azure-profile' },
  });
  assert.equal(result.status, 0, result.stderr);
  const listed = JSON.parse(result.stdout);
  assert.ok(listed.some((item) => item.id === 'turnstile-app-overview'));
});
