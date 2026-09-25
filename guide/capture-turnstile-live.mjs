// Current-deployment evidence, not demo data. See docs/TURNSTILE.md, live evidence.
// Set TURNSTILE_URL, TURNSTILE_SCOPE, TURNSTILE_APP_ID, TURNSTILE_SP_ID,
// TURNSTILE_FORK_COMMIT, GATEWAY_RG and GATEWAY_APIM. No credentials file is needed.
// --read-only omits the reversible tier exercise. A normal run always restores it.
import assert from 'node:assert/strict';
import { chromium } from 'playwright';
import {
  api, az, captureMetadata, capturePage, catalogWrite, cliSignIn,
  privateJson, ps, Redactor, renderTranscript, requireEnvironment, sleep, utc,
} from './lib/turnstile-live.mjs';

requireEnvironment('TURNSTILE_URL', 'TURNSTILE_SCOPE', 'TURNSTILE_APP_ID', 'TURNSTILE_SP_ID', 'GATEWAY_RG', 'GATEWAY_APIM');
const base = process.env.TURNSTILE_URL.replace(/\/$/, '');
const metadata = captureMetadata();
const reference = { resource_group: process.env.GATEWAY_RG, apim: process.env.GATEWAY_APIM };
const privateEvidence = { started_at_utc: utc(), metadata, journeys: [], api_responses: [] };
const browser = await chromium.launch({ headless: true });
const context = await browser.newContext({ viewport: { width: 1440, height: 1000 }, locale: 'en-US' });
const page = await context.newPage();
const terminal = await context.newPage();
context.on('response', (response) => {
  const url = new URL(response.url());
  if (url.origin === base && url.pathname.startsWith('/api/'))
    privateEvidence.api_responses.push({ route: url.pathname, status: response.status(), utc: utc() });
});
const namedValue = (id) => az(['apim', 'nv', 'show', '-g', reference.resource_group, '--service-name', reference.apim,
  '--named-value-id', id, '--query', 'value', '-o', 'tsv']);
const account = JSON.parse(az(['account', 'show', '-o', 'json']));
const person = JSON.parse(az(['ad', 'signed-in-user', 'show', '-o', 'json']));
const pairs = [
  [person.displayName, 'Example Owner'], [account.name, 'Contoso subscription'],
  [reference.resource_group, 'rg-claude-gateway'], [reference.apim, 'apim-claude-gateway'],
  [new URL(base).hostname, 'api-turnstile-contoso.azurewebsites.net'],
];
// Discover integration resource names too; do not bake one deployment's names into masks.
for (const field of namedValue('turnstile-integration').split(';')) {
  const at = field.indexOf('=');
  if (at < 0) continue;
  const key = field.slice(0, at);
  const value = field.slice(at + 1);
  if (/namespace|resourcegroup/i.test(key) && value) pairs.push([value, `${key}-contoso`]);
  for (const match of value.matchAll(/\/resourceGroups\/([^/]+)|\/namespaces\/([^/]+)/gi))
    pairs.push([match[1] ?? match[2], 'resource-contoso']);
}
let redactor = new Redactor(pairs);
const ownerSource = (route) => ({ route, identity_kind: 'owner_cli_code' });
const commandSource = (command) => ({ command, identity_kind: 'owner_cli' });

async function visit(route) {
  const start = Date.now();
  await page.goto(base + route, { waitUntil: 'domcontentloaded', timeout: 90_000 });
  await page.locator('.app-shell').waitFor({ timeout: 90_000 });
  await page.waitForTimeout(2000);
  await page.waitForFunction(() => !document.querySelector('.finops-state .spin, .registry-loading'), { timeout: 60_000 });
  assert.ok((await page.locator('main').innerText()).trim().length > 40, `Empty page: ${route}`);
  privateEvidence.journeys.push({ route, utc: utc(), seconds: (Date.now() - start) / 1000 });
}

async function captureCommand(image, title, command, expectedFailure = null) {
  const started = Date.now();
  const output = ps(command, { CLAUDE_RG: reference.resource_group, CLAUDE_APIM: reference.apim }, expectedFailure);
  privateJson(image.replace('.png', '.json'), { command, output, utc: utc(), seconds: (Date.now() - started) / 1000 });
  await renderTranscript(terminal, image, title, `PS C:\\gateway> ${command}\n\n${output}`,
    { ...commandSource(command), outcome: expectedFailure ? 'expected_safety_refusal' : 'success' }, redactor, metadata);
}

async function waitForNamedValue(expected) {
  const start = Date.now();
  while (Date.now() - start < 600_000) {
    if (namedValue('tpm-standard') === String(expected)) return (Date.now() - start) / 1000;
    await sleep(5000);
  }
  throw new Error('Gateway did not read back the expected tier limit within ten minutes');
}

async function saveStandard(value) {
  await visit('/?source=apim&page=gateway-governance');
  await page.getByRole('button', { name: 'Edit Standard', exact: true }).click();
  await page.getByRole('dialog').getByLabel('Tokens per minute').fill(String(value));
  const started = Date.now();
  const responsePromise = page.waitForResponse((r) => r.url().endsWith('/api/v1/gateway-tiers') && r.request().method() === 'PUT');
  await page.getByRole('button', { name: 'Save and apply', exact: true }).click();
  const response = await responsePromise;
  assert.equal(response.status(), 200);
  await page.getByRole('dialog').waitFor({ state: 'hidden' });
  await waitForNamedValue(value);
  return (Date.now() - started) / 1000;
}

try {
  if (!process.argv.includes('--skip-signin-images')) {
    await page.goto(base, { waitUntil: 'networkidle', timeout: 90_000 });
    await page.getByText('Sign in with Microsoft', { exact: true }).waitFor();
    await capturePage(page, 'turnstile-01-signin.png', { route: '/', identity_kind: 'anonymous' }, redactor, metadata);
    await page.getByText('Sign in with Microsoft', { exact: true }).click();
    await page.waitForURL(/login\.microsoftonline\.com/, { timeout: 30_000 });
    await page.waitForLoadState('networkidle');
    await capturePage(page, 'turnstile-02-entra-signin.png', { route: 'https://login.microsoftonline.com/<tenant>/oauth2/v2.0/authorize', identity_kind: 'anonymous' }, redactor, metadata);
  }

  const signIn = await cliSignIn(context, page, base, process.env.TURNSTILE_SCOPE);
  assert.equal(signIn.profile.role, 'owner');
  assert.equal(signIn.profile.method, 'entra');
  assert.equal(signIn.profile.manager_scope, null);
  privateEvidence.sign_in = signIn;
  const catalog = await api(context, base, '/api/v1/enterprise-catalog');
  const entities = await api(context, base, '/api/v1/enterprise/entities');
  const tiersBefore = await api(context, base, '/api/v1/gateway-tiers');
  const period = new Date().toISOString().slice(0, 7);
  const budgetsBefore = await api(context, base, `/api/v1/budgets?period=${period}&include_users=true`);
  privateJson('before.json', { catalog, tiers: tiersBefore, budgets: budgetsBefore });
  const unitNames = new Map();
  catalog.organizations.filter((u) => u.id !== 'unassigned').forEach((unit, index) => {
    const example = ['sales', 'engineering', 'finance'][index] ?? `unit-${index + 1}`;
    unitNames.set(unit.id, example);
    pairs.push([unit.name, `claude-bu-${example}`], [unit.id, example]);
    if (unit.external_ref) pairs.push([unit.external_ref.replace(/^entra-group:/, ''), `claude-bu-${example}`]);
  });
  let teamIndex = 0;
  for (const team of catalog.departments) {
    if (team.id === 'unassigned') continue;
    const parent = unitNames.get(team.parent_id) ?? 'unit';
    const example = team.id === team.parent_id ? parent : `${parent}-${['emea', 'apac', 'amer'][teamIndex++ % 3]}`;
    pairs.push([team.name, `claude-${team.id === team.parent_id ? 'bu' : 'team'}-${example}`], [team.id, example]);
    if (team.external_ref) pairs.push([team.external_ref.replace(/^entra-group:/, ''), `claude-team-${example}`]);
  }
  entities.users.forEach((user, index) => {
    if (user.name && user.name !== user.id && !user.name.includes('@')) pairs.push([user.name, `Developer ${index + 1}`]);
  });
  pairs.push([signIn.profile.name, 'Example Owner']);
  // Job execution names contain per-deployment suffixes even when no UUID is shown.
  const status = await api(context, base, '/api/v1/gateway-apply');
  for (const execution of status.executions) pairs.push([execution.name, 'job-turnstile-apply-example']);
  redactor = new Redactor(pairs);
  privateJson('redactions.json', pairs);

  if (!process.argv.includes('--commands-only')) {
  for (const [route, image] of [
    ['budgets', 'turnstile-03-budgets.png'], ['finops-overview', 'turnstile-04-overview.png'],
    ['finops-analytics', 'turnstile-05-analytics.png'], ['finops-requests', 'turnstile-06-requests.png'],
    ['finops-governance', 'turnstile-07-governance.png'], ['gateway-governance', 'turnstile-10-governance.png'],
  ]) {
    const query = `/?source=apim&page=${route}`;
    await visit(query);
    await capturePage(page, image, ownerSource(query), redactor, metadata);
  }
  await visit('/?source=apim&page=budgets');
  await page.locator('.people-budget-panel').scrollIntoViewIfNeeded();
  await capturePage(page, 'turnstile-14-people.png', ownerSource('/?source=apim&page=budgets#people'), redactor, metadata);
  await visit('/?source=apim&page=gateway-governance');
  const firstUnit = catalog.organizations.find((u) => u.id !== 'unassigned');
  await page.getByRole('button', { name: `Edit ${firstUnit.name}`, exact: true }).click();
  await page.getByRole('dialog').getByLabel('Budget enforcement').selectOption('allowance');
  await page.getByRole('dialog').getByLabel('Allowance percent').fill('10');
  await capturePage(page, 'turnstile-15-manager-editor.png', ownerSource('/?source=apim&page=gateway-governance#unit-editor'), redactor, metadata);
  await page.getByRole('button', { name: 'Cancel', exact: true }).click();
  assert.deepEqual(catalogWrite(await api(context, base, '/api/v1/enterprise-catalog')), catalogWrite(catalog));
  await page.goto(base + '/api/v1/auth/me', { waitUntil: 'networkidle' });
  await capturePage(page, 'turnstile-13-cli-session.png', ownerSource('/api/v1/auth/me'), redactor, metadata);
  await renderTranscript(terminal, 'turnstile-16-cli-signin.png', 'Consent-free sign-in: CLI code redeemed in a real browser',
    `PS C:\\gateway> ./scripts/Open-ClaudeTurnstile.ps1 -NoBrowser -TurnstileUrl $env:TURNSTILE_URL -Scope $env:TURNSTILE_SCOPE\n\nSingle-use sign-in link: omitted, not persisted.\nBrowser session verified through GET /api/v1/auth/me:\n${JSON.stringify(signIn, null, 2)}`,
    commandSource('./scripts/Open-ClaudeTurnstile.ps1 -NoBrowser -TurnstileUrl $env:TURNSTILE_URL -Scope $env:TURNSTILE_SCOPE; browser redemption; GET /api/v1/auth/me; replay POST /api/v1/auth/code'), redactor, metadata);

  for (const route of ['finops-trends', 'models', 'apim-native-routes', 'gateway-releases', 'applications', 'settings', 'assistant', 'finops-invoke']) {
    await visit(`/?source=apim&page=${route}`);
    assert.ok(await page.locator('main').innerText(), `Page ${route} rendered nothing`);
  }

  if (!process.argv.includes('--read-only')) {
    const standard = tiersBefore.items.find((tier) => tier.id === 'standard');
    assert.ok(standard);
    const original = Number(namedValue('tpm-standard'));
    assert.equal(original, standard.tokens_per_minute, 'Turnstile/gateway baseline differs; refusing a mutation');
    let attempted = false;
    try {
      await visit('/?source=apim&page=gateway-governance');
      await page.getByRole('button', { name: 'Edit Standard', exact: true }).click();
      await page.getByRole('dialog').getByLabel('Tokens per minute').fill(String(original + 1));
      await capturePage(page, 'turnstile-11-tier-editor.png', ownerSource('/?source=apim&page=gateway-governance#tier-editor'), redactor, metadata);
      // Reload after redaction so no modified display value can enter a write.
      assert.deepEqual((await api(context, base, '/api/v1/gateway-tiers')).items, tiersBefore.items);
      attempted = true;
      const seconds = await saveStandard(original + 1);
      privateEvidence.tier_change = { before: original, changed: original + 1, seconds_to_gateway: seconds, utc: utc() };
      privateJson('journey.json', privateEvidence);
      await visit('/?source=apim&page=gateway-governance');
      await capturePage(page, 'turnstile-12-applied.png', ownerSource('/?source=apim&page=gateway-governance'), redactor, metadata);
      await captureCommand('turnstile-t06-sync-from-apply.png', 'The UI save, read independently from the gateway',
        'az apim nv show -g $env:GATEWAY_RG --service-name $env:GATEWAY_APIM --named-value-id tpm-standard --query value -o tsv');
    } finally {
      if (attempted) {
        let fallback = false;
        const start = Date.now();
        try { await saveStandard(original); }
        catch {
          fallback = true;
          const current = await api(context, base, '/api/v1/gateway-tiers');
          await api(context, base, '/api/v1/gateway-tiers', { method: 'PUT', data: {
            tiers: current.items.map((tier) => tier.id === 'standard' ? { ...tier, tokens_per_minute: original } : tier),
          } });
          await waitForNamedValue(original);
        }
        assert.equal(namedValue('tpm-standard'), String(original));
        assert.deepEqual((await api(context, base, '/api/v1/gateway-tiers')).items, tiersBefore.items);
        privateEvidence.tier_restore = { restored: original, seconds: (Date.now() - start) / 1000, api_fallback: fallback, utc: utc() };
        privateJson('journey.json', privateEvidence);
      }
    }
  }

  }
  for (const [image, title, command, expectedFailure] of [
    ['turnstile-t01-connect-show.png', 'The existing connection, read live', './scripts/Connect-ClaudeTurnstile.ps1 -Show -ResourceGroup $env:GATEWAY_RG -ApimName $env:GATEWAY_APIM'],
    ['turnstile-t02-sync-to.png', 'Current authority refuses a gateway-to-Turnstile overwrite', './scripts/Sync-ClaudeTurnstileGovernance.ps1 -WhatIf -ResourceGroup $env:GATEWAY_RG -ApimName $env:GATEWAY_APIM', /Governance is authored in Turnstile/],
    ['turnstile-t03-export.png', 'Current settled usage exported through the existing grant', './scripts/Export-ClaudeTurnstileUsage.ps1 -ResourceGroup $env:GATEWAY_RG -ApimName $env:GATEWAY_APIM -AsJson'],
    ['turnstile-t04-authority.png', 'Current governance authority, not a new grant', './scripts/Connect-ClaudeTurnstile.ps1 -Show -ResourceGroup $env:GATEWAY_RG -ApimName $env:GATEWAY_APIM'],
    ['turnstile-t05-sync-from-preview.png', 'From-Turnstile preview, no gateway write', './scripts/Sync-ClaudeTurnstileGovernance.ps1 -Direction FromTurnstile -ResourceGroup $env:GATEWAY_RG -ApimName $env:GATEWAY_APIM'],
  ]) await captureCommand(image, title, command, expectedFailure);

  for (const [image, title, command] of [
    ['turnstile-entra-1-overview.png', 'Application overview, read live through Graph',
      '$app = az ad app show --id $env:TURNSTILE_APP_ID -o json | ConvertFrom-Json; $app | Select-Object displayName,appId,signInAudience,spa | ConvertTo-Json -Depth 8'],
    ['turnstile-entra-2-expose-api.png', 'Exposed API and pre-authorized Azure CLI, read live',
      'az ad app show --id $env:TURNSTILE_APP_ID --query api -o json'],
    ['turnstile-entra-3-app-roles.png', 'Current Admin, Viewer and Manager app roles, read live',
      'az ad app show --id $env:TURNSTILE_APP_ID --query appRoles -o json'],
    ['turnstile-t08-entra-config.png', 'Current Entra configuration; no admin consent requested',
      '$app = az ad app show --id $env:TURNSTILE_APP_ID -o json | ConvertFrom-Json; $sp = az ad sp show --id $env:TURNSTILE_SP_ID -o json | ConvertFrom-Json; [ordered]@{ audience=$app.signInAudience; groupClaims=$app.groupMembershipClaims; tokenVersion=$app.api.requestedAccessTokenVersion; assignmentRequired=$sp.appRoleAssignmentRequired; redirects=$app.spa.redirectUris } | ConvertTo-Json -Depth 6'],
  ]) await captureCommand(image, title, command);
  const health = await context.request.get(base + '/health');
  assert.equal(health.status(), 200);
  await renderTranscript(terminal, 'turnstile-t07-gateway-refuses.png', 'Live health and budget safety check; no denial induced',
    `PS C:\\gateway> Invoke-RestMethod "$env:TURNSTILE_URL/health"\n${await health.text()}\n\nNo team budget was lowered. The owner's real usage was not deliberately refused.\nThe historical exhausted-budget picture is superseded; the live manager boundary is Phase 2.`,
    commandSource('Invoke-RestMethod "$env:TURNSTILE_URL/health"; compare authored budget definitions before/after'), redactor, metadata);
  const budgetDefinitions = (response) => response.items.map(({ scope_type, scope_id, token_limit, warning_threshold_percent }) =>
    ({ scope_type, scope_id, token_limit, warning_threshold_percent })).sort((a, b) => `${a.scope_type}:${a.scope_id}`.localeCompare(`${b.scope_type}:${b.scope_id}`));
  assert.deepEqual(budgetDefinitions(await api(context, base, `/api/v1/budgets?period=${period}&include_users=true`)), budgetDefinitions(budgetsBefore));
  assert.deepEqual(catalogWrite(await api(context, base, '/api/v1/enterprise-catalog')), catalogWrite(catalog));
  privateEvidence.catalog_unchanged = true;
  privateEvidence.budget_definitions_unchanged = true;
  privateEvidence.completed_at_utc = utc();
  privateJson('journey.json', privateEvidence);
} finally {
  privateJson('journey.json', privateEvidence);
  await context.request.post(base + '/api/v1/auth/logout').catch(() => {});
  await browser.close();
}
