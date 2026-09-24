// Phase 2 is deliberately separate. Default/--dry-run performs reads only.
// Execute only after the lead explicitly authorizes the exclusive mutation window:
//   node guide/capture-turnstile-manager.mjs --execute --lead-go
// The CLI account must already OWN all three groups; no grants/users/groups are created.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
import { chromium } from 'playwright';
import {
  az, api, captureMetadata, capturePage, catalogWrite, cliSignIn, evidenceDir,
  privateJson, Redactor, renderTranscript, requireEnvironment, sleep, utc,
} from './lib/turnstile-live.mjs';

export function executionMode(args) {
  if (!args.includes('--execute')) return 'dry-run';
  if (!args.includes('--lead-go') || args.includes('--dry-run'))
    throw new Error('Execution requires --execute --lead-go and must not include --dry-run');
  return 'execute';
}

export function managerClaims(claims, requiredGroup) {
  return Array.isArray(claims.roles) && claims.roles.includes('Turnstile.Manager')
    && !claims.roles.includes('Turnstile.Admin') && !claims.roles.includes('Turnstile.Viewer')
    && Array.isArray(claims.groups) && claims.groups.includes(requiredGroup)
    && !Object.hasOwn(claims, 'hasgroups') && !claims._claim_names?.groups;
}

async function main() {
  const mode = executionMode(process.argv.slice(2));
  requireEnvironment('TURNSTILE_URL', 'TURNSTILE_SCOPE', 'TURNSTILE_SP_ID');
  const base = process.env.TURNSTILE_URL.replace(/\/$/, '');
  const scope = process.env.TURNSTILE_SCOPE;
  const graphToken = az(['account', 'get-access-token', '--resource', 'https://graph.microsoft.com', '--query', 'accessToken', '-o', 'tsv']);
  const ownerToken = az(['account', 'get-access-token', '--scope', scope, '--query', 'accessToken', '-o', 'tsv']);
  const graph = async (route, method = 'GET', data) => {
    const result = await fetch(`https://graph.microsoft.com/v1.0${route}`, {
      method, headers: { Authorization: `Bearer ${graphToken}`, 'Content-Type': 'application/json' },
      body: data ? JSON.stringify(data) : undefined, signal: AbortSignal.timeout(60_000),
    });
    if (!result.ok) throw new Error(`Graph ${method} failed with ${result.status}`);
    return result.status === 204 ? null : result.json();
  };
  const owner = async (route, method = 'GET', data) => {
    const response = await fetch(base + route, {
      method, headers: { Authorization: `Bearer ${ownerToken}`, 'Content-Type': 'application/json' },
      body: data ? JSON.stringify(data) : undefined, signal: AbortSignal.timeout(90_000),
    });
    if (!response.ok) throw new Error(`Turnstile ${method} ${route} returned ${response.status}`);
    return response.json();
  };
  const me = await graph('/me');
  const profile = await owner('/api/v1/auth/me');
  assert.equal(profile.role, 'owner', 'Start as Owner');
  assert.equal(profile.manager_scope, null);
  const groups = {};
  for (const [kind, name] of [
    ['admin', 'turnstile-claude-admins'], ['unit', 'claude-mgr-test-unit'], ['team', 'claude-mgr-test-team'],
  ]) {
    const group = JSON.parse(az(['ad', 'group', 'show', '--group', name, '-o', 'json']));
    assert.equal(group.displayName, name);
    assert.equal(group.securityEnabled, true);
    const owners = (await graph(`/groups/${group.id}/owners`)).value;
    assert.ok(owners.some((person) => person.id === me.id), `CLI account must own ${name}`);
    const members = (await graph(`/groups/${group.id}/members`)).value;
    if (kind === 'admin') assert.ok(members.some((person) => person.id === me.id), 'CLI account must be an Admin-group member');
    else assert.equal(members.length, 0, 'Test groups must start empty');
    groups[kind] = { id: group.id, name };
  }
  const assignments = (await graph(`/servicePrincipals/${process.env.TURNSTILE_SP_ID}/appRoleAssignedTo`)).value;
  const servicePrincipal = await graph(`/servicePrincipals/${process.env.TURNSTILE_SP_ID}`);
  for (const [kind, group] of Object.entries(groups)) {
    const expectedRole = kind === 'admin' ? 'Turnstile.Admin' : 'Turnstile.Manager';
    const role = servicePrincipal.appRoles.find((role) => role.value === expectedRole);
    assert.ok(role && assignments.some((assignment) => assignment.principalId === group.id && assignment.appRoleId === role.id),
      `Existing ${expectedRole} assignment required`);
  }
  const catalog = catalogWrite(await owner('/api/v1/enterprise-catalog'));
  const unit = catalog.organizations.find((unit) => unit.id !== 'unassigned');
  const team = catalog.departments.find((team) => team.parent_id === unit.id && team.id !== unit.id);
  assert.ok(unit && team, 'An existing example unit with a team is required');
  assert.ok(!unit.attributes.manager_group_id && !team.attributes.manager_group_id, 'Do not overwrite another manager assignment');
  const plan = {
    mode, utc: utc(), identity: { role: profile.role, method: profile.method, manager_scope: profile.manager_scope },
    preconditions: { owns_admin_and_test_groups: true, currently_admin_member: true, test_groups_empty: true, app_roles_already_assigned: true },
    sequence: ['snapshot catalog', 'add only two manager_group_id attributes', 'add self to unit test group',
      'remove self from Admin members, never owners', 'wait for propagation, mint alternate-scope token, reject cached Admin/Viewer',
      'browser CLI-code manager journey', 'finally: re-add Admin, remove test member, restore exact catalog, prove Owner access'],
    catalog_unit: unit.id, catalog_team: team.id,
    no_new_grants_users_or_roles: true,
  };
  privateJson('phase2-plan.json', plan);
  const priorRedactions = path.join(evidenceDir, 'redactions.json');
  const pairs = fs.existsSync(priorRedactions) ? JSON.parse(fs.readFileSync(priorRedactions)) : [];
  pairs.push([me.displayName, 'Example Owner'], [unit.id, 'sales'], [team.id, 'sales-emea']);
  const redactor = new Redactor(pairs);
  if (mode === 'dry-run') {
    console.log(redactor.redact(JSON.stringify(plan, null, 2)));
    if (process.argv.includes('--capture')) {
      const browser = await chromium.launch({ headless: true });
      try {
        const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
        await renderTranscript(page, 'turnstile-t09-entra-mutation.png', 'Live manager preflight; dry run, no membership change',
          `PS C:\\gateway> node guide/capture-turnstile-manager.mjs --dry-run\n\n${JSON.stringify(plan, null, 2)}`,
          { command: 'node guide/capture-turnstile-manager.mjs --dry-run', identity_kind: 'owner_cli' },
          redactor, captureMetadata());
      } finally { await browser.close(); }
    }
    return;
  }

  assert.ok(fs.existsSync(priorRedactions), 'Run the Owner capture first to build the complete private redaction map');
  fs.mkdirSync(evidenceDir, { recursive: true });
  const lockPath = path.join(evidenceDir, 'phase2.lock');
  const lock = fs.openSync(lockPath, 'wx');
  fs.closeSync(lock);
  privateJson('phase2-recovery.json', { groups, user_id: me.id, catalog, started_at_utc: utc() });
  let browser;
  let mutationIntent = false;
  const restored = {};
  try {
    const changed = structuredClone(catalog);
    changed.organizations.find((row) => row.id === unit.id).attributes.manager_group_id = groups.unit.id;
    changed.departments.find((row) => row.id === team.id).attributes.manager_group_id = groups.team.id;
    mutationIntent = true;
    await owner('/api/v1/enterprise-catalog', 'PUT', changed);
    await graph(`/groups/${groups.unit.id}/members/$ref`, 'POST', { '@odata.id': `https://graph.microsoft.com/v1.0/directoryObjects/${me.id}` });
    await graph(`/groups/${groups.admin.id}/members/${me.id}/$ref`, 'DELETE');
    await sleep(60_000);
    const alternateScope = scope.replace(/\/[^/]+$/, '/.default');
    const token = az(['account', 'get-access-token', '--scope', alternateScope, '--query', 'accessToken', '-o', 'tsv']);
    const claims = JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString());
    assert.ok(managerClaims(claims, groups.unit.id), 'Token is cached/unpropagated or has a wider role; stop and restore, never show it as Manager');
    browser = await chromium.launch({ headless: true });
    const context = await browser.newContext({ viewport: { width: 1440, height: 1000 }, locale: 'en-US' });
    const page = await context.newPage();
    const signedIn = await cliSignIn(context, page, base, alternateScope);
    assert.equal(signedIn.profile.role, 'member');
    assert.ok(signedIn.profile.manager_scope?.organizations.some((row) => row.id === unit.id));
    const metadata = captureMetadata();
    for (const [route, image] of [
      ['/?page=budgets', 'turnstile-manager-budgets.png'],
      ['/?page=finops-overview', 'turnstile-manager-usage.png'],
      ['/api/v1/model-management', 'turnstile-manager-refused.png'],
    ]) {
      const stillManager = await api(context, base, '/api/v1/auth/me');
      assert.equal(stillManager.role, 'member', 'Another Owner sign-in changed the session; do not claim Manager evidence');
      assert.ok(stillManager.manager_scope);
      await page.goto(base + route, { waitUntil: 'networkidle' });
      if (route.startsWith('/api/')) assert.equal((await context.request.get(base + route)).status(), 403);
      await capturePage(page, image, { route, identity_kind: 'manager_cli_code' }, redactor, metadata);
    }
    privateJson('phase2-manager.json', { utc: utc(), profile: signedIn.profile, code_replay_status: signedIn.replay_status });
    await context.request.post(base + '/api/v1/auth/logout');
  } finally {
    if (mutationIntent) {
      // Each recovery action runs even if a preceding one fails.
      for (const [name, action] of [
        ['admin_membership', async () => {
          if (!(await graph(`/groups/${groups.admin.id}/members`)).value.some((p) => p.id === me.id))
            await graph(`/groups/${groups.admin.id}/members/$ref`, 'POST', { '@odata.id': `https://graph.microsoft.com/v1.0/directoryObjects/${me.id}` });
          assert.ok((await graph(`/groups/${groups.admin.id}/members`)).value.some((p) => p.id === me.id));
        }],
        ['test_membership', async () => {
          if ((await graph(`/groups/${groups.unit.id}/members`)).value.some((p) => p.id === me.id))
            await graph(`/groups/${groups.unit.id}/members/${me.id}/$ref`, 'DELETE');
          assert.equal((await graph(`/groups/${groups.unit.id}/members`)).value.length, 0);
        }],
        ['catalog', async () => {
          await owner('/api/v1/enterprise-catalog', 'PUT', catalog);
          assert.deepEqual(catalogWrite(await owner('/api/v1/enterprise-catalog')), catalog);
        }],
      ]) {
        try { await action(); restored[name] = true; } catch { restored[name] = false; }
      }
      privateJson('phase2-restored.json', { utc: utc(), restored });
    }
    if (browser) await browser.close();
    // Prove restored Owner access even when the manager journey itself threw.
    if (mutationIntent) {
      let ownerBrowser;
      try {
        ownerBrowser = await chromium.launch({ headless: true });
        const context = await ownerBrowser.newContext();
        const result = await cliSignIn(context, await context.newPage(), base, scope);
        assert.equal(result.profile.role, 'owner');
        assert.equal(result.profile.manager_scope, null);
        privateJson('phase2-owner-restored.json', { utc: utc(), profile: result.profile, membership_rechecked: restored.admin_membership });
        await context.request.post(base + '/api/v1/auth/logout');
        restored.owner_access = true;
      } catch { restored.owner_access = false; }
      finally { if (ownerBrowser) await ownerBrowser.close(); }
      privateJson('phase2-restored.json', { utc: utc(), restored });
    }
    fs.unlinkSync(lockPath);
    if (Object.values(restored).some((ok) => !ok)) throw new Error('Recovery incomplete: use the private phase2-recovery.json immediately; do not claim completion');
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  await main();
}
