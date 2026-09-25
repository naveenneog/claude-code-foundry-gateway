// Phase 2 is deliberately separate. Default/--dry-run performs reads only.
// Execute only after the lead explicitly authorizes the exclusive mutation window:
//   node guide/capture-turnstile-manager.mjs --execute --lead-go --include-direct-admin --renew-broker-token
// The CLI account must already OWN all three groups; no grants/users/groups are created.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';
import { chromium } from 'playwright';
import { entraToken } from './lib/entra-token.mjs';
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
  return Array.isArray(claims.roles) && claims.roles.length === 1 && claims.roles[0] === 'Turnstile.Manager'
    && Array.isArray(claims.groups) && claims.groups.includes(requiredGroup)
    && !Object.hasOwn(claims, 'hasgroups') && !claims._claim_names?.groups;
}

export function freshRole(claims, role, afterMilliseconds, backdateSeconds = 0) {
  return Number.isFinite(claims.iat) && claims.iat >= Math.floor(afterMilliseconds / 1000) - 1 - backdateSeconds
    && Array.isArray(claims.roles) && claims.roles.includes(role);
}

export function directWiderRoles(assignments, appRoles, userId) {
  const names = new Map(appRoles.map((role) => [role.id, role.value]));
  return assignments.filter((assignment) => assignment.principalId === userId)
    .map((assignment) => names.get(assignment.appRoleId))
    .filter((role) => role === 'Turnstile.Admin' || role === 'Turnstile.Viewer');
}

async function main() {
  const mode = executionMode(process.argv.slice(2));
  const includeDirectAdmin = process.argv.includes('--include-direct-admin');
  const renewBrokerToken = process.argv.includes('--renew-broker-token');
  requireEnvironment('TURNSTILE_URL', 'TURNSTILE_SCOPE', 'TURNSTILE_SP_ID', 'GATEWAY_RG', 'GATEWAY_APIM');
  const base = process.env.TURNSTILE_URL.replace(/\/$/, '');
  const scope = process.env.TURNSTILE_SCOPE;
  const resource = scope.slice(0, scope.lastIndexOf('/'));
  const clientId = resource.replace(/^api:\/\//, '');
  assert.match(clientId, /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i,
    'This transition requires the existing api://<client-id> scope');
  const managerScope = process.env.TURNSTILE_MANAGER_SCOPE || `api://${clientId.toUpperCase()}/.default`;
  const restoreScope = process.env.TURNSTILE_OWNER_RESTORE_SCOPE || `${clientId.toUpperCase()}/.default`;
  assert.notEqual(managerScope, scope);
  assert.notEqual(restoreScope, managerScope);
  const decode = (token) => JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString());
  const historyFile = path.join(evidenceDir, 'phase2-scope-history.json');
  const history = fs.existsSync(historyFile) ? JSON.parse(fs.readFileSync(historyFile, 'utf8')) : [];
  const usedForms = new Set([scope, `${resource}/.default`, `${clientId}/.default`,
    `${clientId}/Turnstile.Manage`, ...history.map((entry) => entry.scope)]);
  if (mode === 'execute') {
    assert.ok(!usedForms.has(managerScope) && !usedForms.has(restoreScope),
      'Choose valid existing scope spellings not previously used by this capture history; nothing changed');
  }
  const rememberScope = (value, purpose) => {
    history.push({ scope: value, purpose, requested_at_utc: utc() });
    privateJson('phase2-scope-history.json', history);
  };
  const graphToken = az(['account', 'get-access-token', '--resource', 'https://graph.microsoft.com', '--query', 'accessToken', '-o', 'tsv']);
  const ownerToken = entraToken(scope, { renew: renewBrokerToken });
  if (mode === 'execute') {
    assert.ok(decode(ownerToken).exp * 1000 - Date.now() > 15 * 60_000, 'Recovery Owner token needs at least 15 minutes remaining before mutation');
    assert.ok(decode(graphToken).exp * 1000 - Date.now() > 15 * 60_000, 'Recovery Graph token needs at least 15 minutes remaining before mutation');
  }
  const gatewayValues = () => Object.fromEntries(JSON.parse(az(['apim', 'nv', 'list',
    '-g', process.env.GATEWAY_RG, '--service-name', process.env.GATEWAY_APIM, '-o', 'json']))
    .filter((row) => !row.secret && !row.properties?.secret)
    .map((row) => [row.name, row.value ?? row.properties?.value ?? null]));
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
    groups[kind] = { id: group.id, name, member_ids: members.map((person) => person.id).sort(),
      owner_ids: owners.map((person) => person.id).sort() };
  }
  const assignments = (await graph(`/servicePrincipals/${process.env.TURNSTILE_SP_ID}/appRoleAssignedTo`)).value;
  const servicePrincipal = await graph(`/servicePrincipals/${process.env.TURNSTILE_SP_ID}`);
  const widerDirectRoles = directWiderRoles(assignments, servicePrincipal.appRoles, me.id);
  const adminRole = servicePrincipal.appRoles.find((role) => role.value === 'Turnstile.Admin');
  const directAdmin = assignments.filter((assignment) => assignment.principalId === me.id
    && assignment.appRoleId === adminRole?.id);
  for (const [kind, group] of Object.entries(groups)) {
    const expectedRole = kind === 'admin' ? 'Turnstile.Admin' : 'Turnstile.Manager';
    const role = servicePrincipal.appRoles.find((role) => role.value === expectedRole);
    assert.ok(role && assignments.some((assignment) => assignment.principalId === group.id && assignment.appRoleId === role.id),
      `Existing ${expectedRole} assignment required`);
  }
  const originalResponse = await owner('/api/v1/enterprise-catalog');
  const catalog = catalogWrite(originalResponse);
  const catalogBytes = JSON.stringify(catalog);
  const sha256 = (value) => createHash('sha256').update(value).digest('hex');
  const namedValues = gatewayValues();
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
    fresh_scopes: { manager: managerScope, owner_restore: restoreScope },
    blocking_direct_roles: widerDirectRoles,
    direct_admin_plan_authorized: includeDirectAdmin,
    token_renewal: renewBrokerToken ? 'Windows broker AccessTokenToRenew' : 'Azure CLI cache',
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
  assert.ok(!widerDirectRoles.includes('Turnstile.Viewer'), 'A direct Viewer assignment needs separate authorization; nothing changed');
  if (widerDirectRoles.includes('Turnstile.Admin')) {
    assert.ok(includeDirectAdmin, 'Direct Admin removal requires --include-direct-admin and explicit lead authorization; nothing changed');
    assert.equal(directAdmin.length, 1, 'Snapshot/restore supports exactly one authorized direct Admin assignment');
    assert.equal(directAdmin[0].resourceId, process.env.TURNSTILE_SP_ID);
  }
  fs.mkdirSync(evidenceDir, { recursive: true });
  const lockPath = path.join(evidenceDir, 'phase2.lock');
  const lock = fs.openSync(lockPath, 'wx');
  fs.closeSync(lock);
  privateJson('phase2-recovery.json', { groups, user_id: me.id, catalog, original_response: originalResponse,
    authored_catalog_sha256: sha256(catalogBytes), named_values: namedValues,
    direct_admin_assignments: directAdmin, started_at_utc: utc() });
  let browser;
  let mutationIntent = false;
  const restored = {};
  let adminRestoredAt = 0;
  let restoreSavedAt = 0;
  let journeyError;
  try {
    const changed = structuredClone(catalog);
    changed.organizations.find((row) => row.id === unit.id).attributes.manager_group_id = groups.unit.id;
    changed.departments.find((row) => row.id === team.id).attributes.manager_group_id = groups.team.id;
    mutationIntent = true;
    await owner('/api/v1/enterprise-catalog', 'PUT', changed);
    await graph(`/groups/${groups.unit.id}/members/$ref`, 'POST', { '@odata.id': `https://graph.microsoft.com/v1.0/directoryObjects/${me.id}` });
    await graph(`/groups/${groups.admin.id}/members/${me.id}/$ref`, 'DELETE');
    for (const assignment of directAdmin) {
      await graph(`/servicePrincipals/${assignment.resourceId}/appRoleAssignedTo/${assignment.id}`, 'DELETE');
    }
    const removedAt = Date.now();
    privateJson('phase2-progress.json', { utc: utc(), state: 'manager group added; Admin membership and authorized direct assignment removed', user_id: me.id });
    await sleep(60_000);
    rememberScope(managerScope, 'manager proof');
    const token = entraToken(managerScope, { renew: renewBrokerToken });
    const claims = decode(token);
    assert.ok(managerClaims(claims, groups.unit.id), 'Token is cached/unpropagated or has a wider role; stop and restore, never show it as Manager');
    assert.ok(!claims.groups.includes(groups.admin.id), 'Manager token still carries the Admin group');
    // Entra issue timestamps were observed backdated by five minutes. Spelling alone is
    // not a cache-bypass proof: require the new role/group state and a different token too.
    assert.ok(freshRole(claims, 'Turnstile.Manager', removedAt, 300), 'Manager token is too old for this transition');
    assert.notEqual(sha256(token), sha256(ownerToken), 'Manager proof reused the pre-transition token');
    browser = await chromium.launch({ headless: true });
    const context = await browser.newContext({ viewport: { width: 1440, height: 1000 }, locale: 'en-US' });
    const page = await context.newPage();
    const signedIn = await cliSignIn(context, page, base, managerScope);
    assert.equal(signedIn.profile.role, 'member');
    assert.deepEqual(signedIn.profile.manager_scope?.organizations.map((row) => row.id), [unit.id]);
    assert.deepEqual(signedIn.profile.manager_scope.departments.map((row) => row.id).sort(),
      catalog.departments.filter((row) => row.parent_id === unit.id).map((row) => row.id).sort());
    const metadata = captureMetadata();
    for (const [route, image] of [
      ['/?page=budgets', 'turnstile-manager-budgets.png'],
      ['/?page=finops-overview', 'turnstile-manager-usage.png'],
      ['/?page=gateway-governance', 'turnstile-manager-governance.png'],
    ]) {
      const stillManager = await api(context, base, '/api/v1/auth/me');
      assert.equal(stillManager.role, 'member', 'Another Owner sign-in changed the session; do not claim Manager evidence');
      assert.ok(stillManager.manager_scope);
      await page.goto(base + route, { waitUntil: 'networkidle' });
      await capturePage(page, image, { route, identity_kind: 'manager_cli_code' }, redactor, metadata);
    }
    const refusals = [];
    for (const route of ['/api/v1/model-management', '/api/v1/observability/overview', '/api/v1/application-access/applications']) {
      const response = await context.request.get(base + route);
      assert.equal(response.status(), 403);
      refusals.push({ route, status: response.status(), body: await response.json() });
    }
    const budgets = await api(context, base, `/api/v1/budgets?period=${new Date().toISOString().slice(0, 7)}&include_users=true`);
    assert.ok(budgets.items.every((row) => row.scope_type !== 'organization' || row.scope_id === unit.id));
    const permittedDepartments = new Set(signedIn.profile.manager_scope.departments.map((row) => row.id));
    assert.ok(budgets.items.every((row) => row.scope_type !== 'department' || permittedDepartments.has(row.scope_id)));
    await renderTranscript(page, 'turnstile-manager-refused.png', 'Live Manager session: protected admin routes are refused',
      JSON.stringify({ profile: signedIn.profile, refusals }, null, 2),
      { command: 'Browser session GET /api/v1/auth/me; GET /api/v1/model-management; GET /api/v1/observability/overview; GET /api/v1/application-access/applications',
        identity_kind: 'manager_cli_code' }, redactor, metadata);
    privateJson('phase2-manager.json', { utc: utc(), profile: signedIn.profile, code_replay_status: signedIn.replay_status,
      token_issued_at: new Date(claims.iat * 1000).toISOString(), membership_removed_at: new Date(removedAt).toISOString(),
      refusals, scoped_budget_ids: budgets.items.map((row) => [row.scope_type, row.scope_id]) });
    await context.request.post(base + '/api/v1/auth/logout');
  } catch (error) {
    journeyError = String(error.message);
    privateJson('phase2-failure.json', { utc: utc(), error: journeyError });
    throw error;
  } finally {
    if (mutationIntent) {
      // Each recovery action runs even if a preceding one fails.
      for (const [name, action] of [
        ['admin_membership', async () => {
          if (!(await graph(`/groups/${groups.admin.id}/members`)).value.some((p) => p.id === me.id))
            await graph(`/groups/${groups.admin.id}/members/$ref`, 'POST', { '@odata.id': `https://graph.microsoft.com/v1.0/directoryObjects/${me.id}` });
          assert.ok((await graph(`/groups/${groups.admin.id}/members`)).value.some((p) => p.id === me.id));
          adminRestoredAt = Date.now();
        }],
        ['direct_admin_assignment', async () => {
          for (const assignment of directAdmin) {
            const existing = (await graph(`/servicePrincipals/${assignment.resourceId}/appRoleAssignedTo`)).value
              .find((row) => row.principalId === assignment.principalId && row.resourceId === assignment.resourceId
                && row.appRoleId === assignment.appRoleId);
            const current = existing ?? await graph(`/servicePrincipals/${assignment.resourceId}/appRoleAssignedTo`, 'POST', {
              principalId: assignment.principalId, resourceId: assignment.resourceId, appRoleId: assignment.appRoleId,
            });
            assert.equal(current.appRoleId, assignment.appRoleId);
            assert.equal(current.principalId, assignment.principalId);
            assert.equal(current.resourceId, assignment.resourceId);
            let confirmed;
            for (let attempt = 0; attempt < 4 && !confirmed; attempt++) {
              confirmed = (await graph(`/servicePrincipals/${assignment.resourceId}/appRoleAssignedTo`)).value
                .find((row) => row.principalId === assignment.principalId && row.resourceId === assignment.resourceId
                  && row.appRoleId === assignment.appRoleId);
              if (!confirmed) await sleep(2000);
            }
            assert.ok(confirmed, 'Re-created direct Admin assignment was not read back');
            privateJson('phase2-direct-assignment-restored.json', { utc: utc(), before: assignment, after: confirmed });
          }
        }],
        ['test_membership', async () => {
          if ((await graph(`/groups/${groups.unit.id}/members`)).value.some((p) => p.id === me.id))
            await graph(`/groups/${groups.unit.id}/members/${me.id}/$ref`, 'DELETE');
          assert.equal((await graph(`/groups/${groups.unit.id}/members`)).value.length, 0);
        }],
        ['catalog', async () => {
          restoreSavedAt = Date.now();
          await owner('/api/v1/enterprise-catalog', 'PUT', catalog);
          assert.equal(JSON.stringify(catalogWrite(await owner('/api/v1/enterprise-catalog'))), catalogBytes);
        }],
      ]) {
        try {
          await action(); restored[name] = true;
        } catch (error) {
          restored[name] = false;
          restored[`${name}_error`] = String(error.message);
          privateJson('phase2-restored.json', { utc: utc(), recovery_in_progress: true, restored });
          console.error(`Recovery step failed: ${name}; inspect private state immediately. Remaining safety restoration will still be attempted.`);
          // Admin membership gets immediate bounded recovery priority; do not leave it removed.
          if (name === 'admin_membership') {
            for (let attempt = 0; attempt < 3 && !restored[name]; attempt++) {
              await sleep(5000);
              try { await action(); restored[name] = true; delete restored[`${name}_error`]; } catch { /* report exact state below */ }
            }
          }
        }
      }
      privateJson('phase2-restored.json', { utc: utc(), restored });
    }
    if (browser) await browser.close();
    if (mutationIntent) {
      try {
        for (const group of Object.values(groups)) {
          const members = (await graph(`/groups/${group.id}/members`)).value.map((person) => person.id).sort();
          assert.deepEqual(members, group.member_ids);
        }
        restored.memberships_exact = true;
        const deadline = Date.now() + 6 * 60_000;
        let succeeded = false;
        while (Date.now() < deadline) {
          const status = await owner('/api/v1/gateway-apply');
          const run = status.executions.find((run) => Date.parse(run.started_at ?? '') >= Math.floor(restoreSavedAt / 1000) * 1000);
          if (run?.status === 'Failed') throw new Error('Restore apply failed');
          if (run?.status === 'Succeeded') { restored.apply = run; succeeded = true; break; }
          await sleep(5000);
        }
        assert.ok(succeeded, 'Restore apply did not succeed in time');
        assert.deepEqual(gatewayValues(), namedValues);
        restored.named_values_exact = true;
        const response = await owner('/api/v1/enterprise-catalog');
        assert.equal(JSON.stringify(catalogWrite(response)), catalogBytes);
        restored.authored_catalog_sha256 = sha256(JSON.stringify(catalogWrite(response)));
        privateJson('phase2-catalog-restored.json', response);
      } catch (error) { restored.integrity_error = String(error.message); }
    }
    // Prove restored Owner access even when the manager journey itself threw.
    if (mutationIntent) {
      let ownerBrowser;
      try {
        ownerBrowser = await chromium.launch({ headless: true });
        rememberScope(restoreScope, 'owner restoration proof');
        const freshOwnerToken = entraToken(restoreScope, { renew: renewBrokerToken });
        const ownerClaims = decode(freshOwnerToken);
        const tokenFreshnessVerified = freshRole(ownerClaims, 'Turnstile.Admin', adminRestoredAt, 300)
          && sha256(freshOwnerToken) !== sha256(ownerToken);
        const context = await ownerBrowser.newContext();
        const result = await cliSignIn(context, await context.newPage(), base, restoreScope);
        assert.equal(result.profile.role, 'owner');
        assert.equal(result.profile.manager_scope, null);
        privateJson('phase2-owner-restored.json', { utc: utc(), profile: result.profile, membership_rechecked: restored.admin_membership,
          token_issued_at: new Date(ownerClaims.iat * 1000).toISOString(), admin_restored_at: new Date(adminRestoredAt).toISOString(),
          token_freshness_verified: tokenFreshnessVerified });
        await context.request.post(base + '/api/v1/auth/logout');
        restored.owner_access = true;
        restored.owner_token_freshness_verified = tokenFreshnessVerified;
      } catch (error) { restored.owner_access = false; restored.owner_access_error = String(error.message); }
      finally { if (ownerBrowser) await ownerBrowser.close(); }
      privateJson('phase2-restored.json', { utc: utc(), restored });
    }
    fs.unlinkSync(lockPath);
    const required = ['admin_membership', 'direct_admin_assignment', 'test_membership', 'catalog', 'memberships_exact', 'named_values_exact', 'owner_access'];
    if (mutationIntent && (required.some((key) => restored[key] !== true) || restored.integrity_error))
      throw new Error(`Recovery incomplete: inspect phase2-restored.json immediately. Original failure: ${journeyError ?? 'none'}`);
    if (mutationIntent && restored.owner_token_freshness_verified !== true)
      throw new Error(`State restored, but fresh-token proof is unverified. Original failure: ${journeyError ?? 'none'}`);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  await main();
}
