// Read-only final proof against the baseline saved by capture-turnstile-live.mjs.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { chromium } from 'playwright';
import {
  api, az, captureMetadata, capturePage, catalogWrite, cliSignIn, evidenceDir,
  privateJson, Redactor, requireEnvironment, utc,
} from './lib/turnstile-live.mjs';

requireEnvironment('TURNSTILE_URL', 'TURNSTILE_SCOPE', 'GATEWAY_RG', 'GATEWAY_APIM');
const base = process.env.TURNSTILE_URL.replace(/\/$/, '');
const baselineFile = process.env.TURNSTILE_BASELINE_FILE || path.join(evidenceDir, 'before.json');
const before = JSON.parse(fs.readFileSync(baselineFile));
const redactor = new Redactor(JSON.parse(fs.readFileSync(path.join(evidenceDir, 'redactions.json'))));
const metadata = captureMetadata();
const browser = await chromium.launch({ headless: true });
const context = await browser.newContext({ viewport: { width: 1440, height: 1000 }, locale: 'en-US' });
const page = await context.newPage();
try {
  const login = await cliSignIn(context, page, base, process.env.TURNSTILE_SCOPE);
  assert.equal(login.profile.role, 'owner');
  assert.equal(login.profile.method, 'entra');
  assert.equal(login.profile.manager_scope, null);
  const catalog = await api(context, base, '/api/v1/enterprise-catalog');
  const tiers = await api(context, base, '/api/v1/gateway-tiers');
  const budgets = await api(context, base, `/api/v1/budgets?period=${before.budgets.period}&include_users=true`);
  const definitions = (value) => value.items.map(({ scope_type, scope_id, token_limit, warning_threshold_percent }) =>
    [scope_type, scope_id, token_limit, warning_threshold_percent]).sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b)));
  assert.deepEqual(catalogWrite(catalog), catalogWrite(before.catalog));
  assert.deepEqual(tiers.items, before.tiers.items);
  assert.deepEqual(definitions(budgets), definitions(before.budgets));
  const gatewayValue = Number(az(['apim', 'nv', 'show', '-g', process.env.GATEWAY_RG,
    '--service-name', process.env.GATEWAY_APIM, '--named-value-id', 'tpm-standard', '--query', 'value', '-o', 'tsv']));
  assert.equal(gatewayValue, tiers.items.find((tier) => tier.id === 'standard').tokens_per_minute);
  const applied = await api(context, base, '/api/v1/gateway-apply');
  assert.equal(applied.executions[0]?.status, 'Succeeded', 'Wait for the restore apply to finish before final capture');
  await page.goto(base + '/api/v1/auth/me', { waitUntil: 'networkidle' });
  const responseBody = await page.locator('pre').textContent();
  const renderedProfile = JSON.parse(responseBody);
  assert.deepEqual(renderedProfile, login.profile);
  await page.locator('pre').evaluate((element) => {
    element.textContent = JSON.stringify(JSON.parse(element.textContent), null, 2);
  });
  await page.addStyleTag({ content: 'pre { font: 18px/1.7 Consolas, monospace; padding: 24px; margin: 0; white-space: pre-wrap; }' });
  await capturePage(page, 'turnstile-13-cli-session.png', { route: '/api/v1/auth/me', identity_kind: 'owner_cli_code' },
    redactor, metadata, page.locator('pre'));
  await page.goto(base + '/?source=apim&page=gateway-governance', { waitUntil: 'networkidle' });
  await page.getByRole('heading', { name: 'Tiers', exact: true }).waitFor();
  await page.getByText('Succeeded', { exact: true }).waitFor();
  await capturePage(page, 'turnstile-12-applied.png', {
    route: '/?source=apim&page=gateway-governance', identity_kind: 'owner_cli_code',
    state: 'restored tier; latest apply succeeded; named value independently verified',
  }, redactor, metadata);
  privateJson('final-verification.json', {
    utc: utc(), login, catalog_restored_exactly: true, tiers_restored_exactly: true,
    budget_definitions_unchanged: true, standard_tpm: gatewayValue, latest_apply: applied.executions[0],
  });
  console.log(`Final readback verified at ${utc()}: catalog, tiers, budgets and gateway TPM match the baseline`);
} finally {
  await context.request.post(base + '/api/v1/auth/logout');
  assert.equal((await context.request.get(base + '/api/v1/auth/me')).status(), 401);
  await browser.close();
}
