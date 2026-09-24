// Authorized short-window UI proof: Notify -> Strict -> exact original catalog.
// Requires an existing Owner assignment and the already-configured apply job.
import fs from 'node:fs';
import assert from 'node:assert/strict';
import { chromium } from 'playwright';
import {
  api, az, captureMetadata, capturePage, catalogWrite, cliSignIn,
  privateJson, Redactor, renderTranscript, requireEnvironment, sleep, utc,
} from './lib/turnstile-live.mjs';

requireEnvironment('TURNSTILE_URL', 'TURNSTILE_SCOPE', 'GATEWAY_RG', 'GATEWAY_APIM', 'REDACTIONS_FILE');
const base = process.env.TURNSTILE_URL.replace(/\/$/, '');
const metadata = captureMetadata();
const redactor = new Redactor(JSON.parse(fs.readFileSync(process.env.REDACTIONS_FILE, 'utf8').replace(/^\uFEFF/, '')));
const command = 'az apim nv show -g $env:GATEWAY_RG --service-name $env:GATEWAY_APIM --named-value-id bu-modes --query value -o tsv';
const readMode = () => az(['apim', 'nv', 'show', '-g', process.env.GATEWAY_RG, '--service-name',
  process.env.GATEWAY_APIM, '--named-value-id', 'bu-modes', '--query', 'value', '-o', 'tsv']);
const namedValues = () => Object.fromEntries(JSON.parse(az(['apim', 'nv', 'list', '-g', process.env.GATEWAY_RG,
  '--service-name', process.env.GATEWAY_APIM, '-o', 'json'])).filter((row) => !row.secret && !row.properties?.secret)
  .map((row) => [row.name, row.value ?? row.properties?.value ?? null]));
const browser = await chromium.launch({ headless: true });
const context = await browser.newContext({ viewport: { width: 1440, height: 1000 }, locale: 'en-US' });
const page = await context.newPage();
const terminal = await context.newPage();
const result = { started_at_utc: utc(), metadata, steps: [] };
let baseline;
let gatewayBefore;
let team;
let changed = false;
const route = '/?source=apim&page=gateway-governance';

async function saveMode(mode) {
  await page.goto(base + route, { waitUntil: 'networkidle' });
  await page.getByRole('button', { name: `Edit ${team.name}`, exact: true }).click();
  await page.getByRole('dialog').getByLabel('Budget enforcement').selectOption(mode);
  const start = Date.now();
  const response = page.waitForResponse((r) => r.url().endsWith('/api/v1/enterprise-catalog') && r.request().method() === 'PUT');
  await page.getByRole('button', { name: 'Save and apply', exact: true }).click();
  assert.equal((await response).status(), 200);
  await page.getByRole('dialog').waitFor({ state: 'hidden' });
  return { mode: mode || 'unset (gateway default)', save_started_at_utc: new Date(start).toISOString(), start };
}

async function waitForEffect(step, expected) {
  let firstEffect;
  let execution;
  const since = Math.floor(step.start / 1000) * 1000;
  while (Date.now() - step.start < 600_000) {
    const value = readMode();
    if (value === expected && firstEffect === undefined) firstEffect = (Date.now() - step.start) / 1000;
    const status = await api(context, base, '/api/v1/gateway-apply');
    execution = status.executions.find((run) => Date.parse(run.started_at ?? '') >= since);
    if (execution?.status === 'Failed') throw new Error('The apply job failed; restore before claiming success');
    if (value === expected && execution?.status === 'Succeeded') {
      const measured = { ...step, expected, observed: value, save_to_effect_seconds: firstEffect,
        save_to_succeeded_seconds: (Date.now() - step.start) / 1000, verified_at_utc: utc(), execution };
      delete measured.start;
      result.steps.push(measured);
      privateJson('mode-roundtrip.json', result);
      return measured;
    }
    await sleep(5000);
  }
  throw new Error('Mode did not reach the expected named value and a succeeded apply within ten minutes');
}

async function recordState(kind, measured) {
  redactor.pairs.push([measured.execution.name, 'job-turnstile-apply-contoso']);
  await page.goto(base + route, { waitUntil: 'networkidle' });
  await page.getByText('Succeeded', { exact: true }).waitFor();
  await capturePage(page, `turnstile-mode-${kind}.png`,
    { route, identity_kind: 'owner_cli_code', state: `${kind}; independently read back from the gateway` }, redactor, metadata);
  await renderTranscript(terminal, `turnstile-mode-${kind}-apply.png`, `Live ${kind} mode and succeeded apply`,
    `PS C:\\gateway> ${command}\n${measured.observed}\n\nGET /api/v1/gateway-apply\n${JSON.stringify(measured, null, 2)}`,
    { command: `${command}; GET /api/v1/gateway-apply`, identity_kind: 'owner_cli' }, redactor, metadata);
}

try {
  const signIn = await cliSignIn(context, page, base, process.env.TURNSTILE_SCOPE);
  assert.equal(signIn.profile.role, 'owner');
  baseline = catalogWrite(await api(context, base, '/api/v1/enterprise-catalog'));
  team = baseline.departments.find((row) => row.parent_id !== row.id && row.parent_id !== 'unassigned');
  assert.ok(team, 'No existing team found');
  assert.ok(!team.attributes.enforcement || team.attributes.enforcement === 'strict', 'Chosen team is not initially strict');
  gatewayBefore = namedValues();
  assert.equal(gatewayBefore['bu-modes'], ',,', 'Another mode window may be active; do not overwrite it');
  const period = new Date().toISOString().slice(0, 7);
  const budgets = await api(context, base, `/api/v1/budgets?period=${period}&include_users=true`);
  const tiers = await api(context, base, '/api/v1/gateway-tiers');
  privateJson('mode-roundtrip-before.json', { catalog: baseline, named_values: gatewayBefore, budgets, tiers });
  result.team_id = team.id;
  result.original_attributes = team.attributes;
  changed = true;
  const notify = await waitForEffect(await saveMode('notify'), `,${team.id}=notify,`);
  await recordState('notify', notify);
  const strict = await waitForEffect(await saveMode('strict'), ',,');
  await recordState('strict', strict);
  // Explicit Strict proves the required UI round trip. If the original was unset,
  // remove only that authored attribute too, rather than leaving a changed catalog.
  if (!Object.hasOwn(team.attributes, 'enforcement')) await waitForEffect(await saveMode(''), ',,');
  assert.deepEqual(catalogWrite(await api(context, base, '/api/v1/enterprise-catalog')), baseline);
  assert.deepEqual(namedValues(), gatewayBefore);
  assert.deepEqual((await api(context, base, '/api/v1/gateway-tiers')).items, tiers.items);
  const definitions = (value) => value.items.map(({ scope_type, scope_id, token_limit, warning_threshold_percent }) =>
    [scope_type, scope_id, token_limit, warning_threshold_percent]).sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b)));
  assert.deepEqual(definitions(await api(context, base, `/api/v1/budgets?period=${period}&include_users=true`)), definitions(budgets));
  result.catalog_restored_exactly = true;
  result.all_named_values_restored_exactly = true;
  result.budgets_and_tiers_unchanged = true;
  result.completed_at_utc = utc();
  changed = false;
} finally {
  if (changed && baseline) {
    const restoreStart = Date.now();
    // Recovery runs even if screenshotting, the GUI or the status waiter failed.
    await api(context, base, '/api/v1/enterprise-catalog', { method: 'PUT', data: baseline });
    await waitForEffect({ mode: 'recovery to original', start: restoreStart,
      save_started_at_utc: new Date(restoreStart).toISOString() }, ',,');
    assert.deepEqual(catalogWrite(await api(context, base, '/api/v1/enterprise-catalog')), baseline);
    assert.deepEqual(namedValues(), gatewayBefore);
    result.recovered_in_finally = true;
  }
  privateJson('mode-roundtrip.json', result);
  await context.request.post(base + '/api/v1/auth/logout').catch(() => {});
  await browser.close();
}
console.log(JSON.stringify({ completed_at_utc: result.completed_at_utc,
  restored: result.all_named_values_restored_exactly, steps: result.steps.map(({ mode, save_to_effect_seconds, save_to_succeeded_seconds }) =>
    ({ mode, save_to_effect_seconds, save_to_succeeded_seconds })) }, null, 2));
