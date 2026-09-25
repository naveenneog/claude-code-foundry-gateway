import assert from 'node:assert/strict';
import test from 'node:test';
import { buildAumProofScenarios } from '../guide/aum-proof-receipts.mjs';

const utc = '2026-09-25T03:45:17Z';
const event = (step, data) => ({ step, utc, data });
const request = (phase, status, notice = '') => event('claude.request', {
  phase, status, notice, utc, body: 'PRIVATE-MODEL-RESPONSE', model: 'PRIVATE-DEPLOYMENT',
});
function fixture() {
  const scope = (organizations, departments, writable) => ({
    organizations: Array.from({ length: organizations }, () => ({ id: 'PRIVATE-UNIT' })),
    departments: Array.from({ length: departments }, () => ({ id: 'PRIVATE-TEAM' })),
    writable_department_ids: Array.from({ length: writable }, () => 'PRIVATE-TEAM'),
  });
  return {
    gateway: { transport: 'direct-http-with-Azure-CLI-token', events: [
      request('entitled', 200), request('strict-refusal', 403),
      request('allowance-over-nominal', 200, 'PRIVATE-TEAM;mode=allowance:100;status=estimated-over-budget'),
      request('allowance-refusal', 403),
      request('notify-serves-over-budget', 200, 'PRIVATE-TEAM;mode=notify;status=usage-reported'),
      event('allowance.plan', { nominal_limit: 163, effective_limit: 326, allowance_percent: 100 }),
      event('attribution', { matching_requests: 17, usage: { requests: 17, prompt_tokens: 221,
        completion_tokens: 68, usd: 0.001122, unpriced_rows: 0, cost_is_estimate: true } }),
      event('warning.fact', [{ schema_version: 1, kind: 'budget.warning', scope_id: 'PRIVATE-TEAM',
        occurred_at: utc, period_start_utc: '2026-09-01T00:00:00Z', period_end_utc: '2026-10-01T00:00:00Z',
        token_limit: 1, threshold_percent: 80, observed_usage: '357', usage_unit: 'tokens',
        usage_basis: 'prompt_completion_only', source: 'ClaudeCost', id: 'PRIVATE-FACT' }]),
      event('proof.passed', { strict: true, allowance: true, notify: true, real_claude: true,
        attribution: true, not_an_aum_client_claim: true }),
      event('finished', { mutations_closed: true, restoration_errors: [] }),
    ] },
    gatewayClose: { NamedValuesExact: true, SavedQueryExact: true, MembershipsExact: true,
      AdminPreserved: true, OriginalTestPolicyExact: true, ReferenceTouched: false, GroupsDeleted: 5, Utc: utc },
    manager: { state: 'restored', restoration_errors: [], receipts: [
      { phase: 'team-claims', utc, roles: ['AUM.Manager'], groups: ['PRIVATE-GROUP'] },
      { phase: 'unit-claims', utc, roles: ['AUM.Manager'], groups: ['PRIVATE-GROUP'] },
      { phase: 'team-manager', utc, state: 'passed', profile: { access: 'manager',
        id: 'PRIVATE-PERSON', manager_scope: scope(0, 1, 0) } },
      { phase: 'unit-manager', utc, state: 'passed', profile: { access: 'manager',
        manager_scope: scope(1, 2, 2) } },
      { phase: 'person-budget', utc, state: 'changed-and-restored', scope_id: 'PRIVATE-PERSON' },
      ...Array.from({ length: 4 }, () => ({ phase: 'forbidden', utc, status: 403, path: 'PRIVATE-PATH' })),
      { phase: 'restored-admin', utc, state: 'passed', memberships_exact: true, assignment_tuples_exact: true,
        roles: ['AUM.Admin'], profile: { access: 'admin', manager_scope: null } },
    ] },
    managerVerified: { State: 'restored', MembershipCount: 14, DirectAssignmentTupleCount: 22,
      GroupsVerifiedAbsent: 3, NamedValuesExact: true, VerifiedUtc: utc },
  };
}
test('builds three measured, explicitly non-client receipts using only whitelisted fields', () => {
  const scenarios = buildAumProofScenarios(fixture());
  assert.equal(scenarios.length, 3);
  const text = JSON.stringify(scenarios);
  assert.doesNotMatch(text, /PRIVATE-/);
  assert.match(text, /direct HTTP/i);
  assert.match(text, /not native AUM/i);
  assert.match(text, /0\.001122/);
  assert.match(text, /357/);
  assert.match(text, /14 memberships/);
  assert.match(text, /22 direct/);
});
test('refuses missing or failed enforcement and restoration evidence', () => {
  for (const change of [
    f => { f.gatewayClose.OriginalTestPolicyExact = false; },
    f => { f.gatewayClose.ReferenceTouched = true; },
    f => { f.gateway.events = f.gateway.events.filter(e => e.data.phase !== 'strict-refusal'); },
    f => { f.gateway.events.find(e => e.step === 'finished').data.restoration_errors.push('failed'); },
    f => { f.managerVerified.NamedValuesExact = false; },
    f => { f.manager.restoration_errors.push('failed'); },
  ]) {
    const f = fixture(); change(f);
    assert.throws(() => buildAumProofScenarios(f));
  }
});
test('refuses wider manager claims, unrestricted manager scope and incomplete negatives', () => {
  for (const change of [
    f => { f.manager.receipts[0].roles.push('AUM.Admin'); },
    f => { f.manager.receipts[1].roles.push('AUM.Viewer'); },
    f => { f.manager.receipts[2].profile.manager_scope = null; },
    f => { f.manager.receipts = f.manager.receipts.filter(r => r.phase !== 'forbidden'); },
  ]) {
    const f = fixture(); change(f);
    assert.throws(() => buildAumProofScenarios(f));
  }
});
test('rejects identities smuggled through time, numeric, source and warning fields', () => {
  for (const [field, value] of [
    ['occurred_at', 'PRIVATE-IDENTITY'], ['observed_usage', '1 PRIVATE-IDENTITY'],
    ['source', 'PRIVATE-SOURCE'], ['usage_basis', 'cache-inclusive'], ['schema_version', 2],
  ]) {
    const f = fixture();
    f.gateway.events.find(e => e.step === 'warning.fact').data[0][field] = value;
    assert.throws(() => buildAumProofScenarios(f));
  }
});
