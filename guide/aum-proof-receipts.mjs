// Only validated numbers, UTC times and fixed labels may leave private receipts.
const requireProof = (condition, message) => {
  if (!condition) throw new Error(`Unverified AUM evidence: ${message}`);
};
const stamp = value => {
  requireProof(typeof value === 'string' && /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,7})?Z$/.test(value)
    && Number.isFinite(Date.parse(value)), 'UTC timestamp');
  return value;
};
const count = value => {
  requireProof(Number.isSafeInteger(value) && value >= 0, 'nonnegative integer');
  return String(value);
};
const allTrue = (object, fields) => fields.forEach(field =>
  requireProof(object?.[field] === true, field));
const find = (rows, predicate, label) => {
  const row = rows.find(predicate);
  requireProof(row, label);
  return row;
};

export function buildAumProofScenarios({ gateway, gatewayClose, manager, managerVerified }) {
  requireProof(gateway.transport === 'direct-http-with-Azure-CLI-token', 'HTTP provenance');
  const event = step => find(gateway.events, e => e.step === step, step);
  allTrue(event('proof.passed').data, [
    'strict', 'allowance', 'notify', 'real_claude', 'attribution', 'not_an_aum_client_claim',
  ]);
  requireProof(event('finished').data.mutations_closed === true
    && event('finished').data.restoration_errors.length === 0, 'gateway restoration');
  allTrue(gatewayClose, ['NamedValuesExact', 'SavedQueryExact', 'MembershipsExact',
    'AdminPreserved', 'OriginalTestPolicyExact']);
  requireProof(gatewayClose.ReferenceTouched === false, 'reference isolation');
  const request = (phase, status, notice) => find(gateway.events, e =>
    e.step === 'claude.request' && e.data.phase === phase && e.data.status === status
    && (!notice || e.data.notice.includes(notice)), phase).data;
  const requests = [
    [request('entitled', 200), '200  Real Claude response; standard entitlement'],
    [request('strict-refusal', 403), '403  Strict limit exhausted'],
    [request('allowance-over-nominal', 200, 'mode=allowance:100;status=estimated-over-budget'),
      '200  Allowance:100 above nominal; advisory notice'],
    [request('allowance-refusal', 403), '403  Allowance effective limit exhausted'],
    [request('notify-serves-over-budget', 200, 'mode=notify;status=usage-reported'),
      '200  Notify above nominal; usage-reported notice'],
  ];
  const allowance = event('allowance.plan').data;
  const attribution = event('attribution').data;
  const usage = attribution.usage;
  requireProof(usage.cost_is_estimate === true && Number.isFinite(usage.usd)
    && usage.usd >= 0, 'estimated cost');
  const modes = requests.map(([r, label]) => `${stamp(r.utc)}  ${label}`).join('\n')
    + `\n\nContoso team allowance: ${count(allowance.nominal_limit)} nominal / `
    + `${count(allowance.effective_limit)} effective tokens`
    + `\nAttributed: ${count(attribution.matching_requests)} requests; `
    + `${count(usage.prompt_tokens)} prompt + ${count(usage.completion_tokens)} completion tokens`
    + `\nEstimated USD ${usage.usd.toFixed(6)}; ${count(usage.unpriced_rows)} unpriced rows`
    + `\n\n${stamp(gatewayClose.Utc)}  Configuration, policy and memberships exact`
    + `\n${count(gatewayClose.GroupsDeleted)} temporary groups deleted; reference untouched`;

  const warningEvent = event('warning.fact');
  const fact = find(warningEvent.data, f => f.kind === 'budget.warning', 'warning fact');
  requireProof(fact.schema_version === 1 && fact.usage_unit === 'tokens'
    && fact.usage_basis === 'prompt_completion_only'
    && ['ClaudeCost', 'ClaudeChargeback'].includes(fact.source), 'warning schema and basis');
  requireProof(typeof fact.observed_usage === 'string'
    && /^(0|[1-9][0-9]*)(\.[0-9]+)?$/.test(fact.observed_usage), 'decimal warning usage');
  const warning = `${stamp(fact.occurred_at)}  Scheduled warning created`
    + `\n${stamp(warningEvent.utc)}  Observed through the service API`
    + `\n\nSchema 1 | budget.warning | Contoso team`
    + `\nUTC period: [${stamp(fact.period_start_utc)}, ${stamp(fact.period_end_utc)})`
    + `\nNominal limit: ${count(fact.token_limit)} tokens`
    + `\nWarning threshold: ${count(fact.threshold_percent)}%`
    + `\nObserved usage: ${fact.observed_usage} tokens`
    + `\nBasis: prompt_completion_only | Source: ${fact.source}`
    + '\n\nImmutable fact, not an email delivery receipt.';

  requireProof(manager.state === 'restored' && manager.restoration_errors.length === 0
    && managerVerified.State === 'restored', 'manager restoration');
  allTrue(managerVerified, ['NamedValuesExact']);
  const phase = name => find(manager.receipts, r => r.phase === name, name);
  for (const name of ['team-claims', 'unit-claims']) {
    const claims = phase(name);
    requireProof(claims.roles.length === 1 && claims.roles[0] === 'AUM.Manager'
      && claims.groups.length > 0, 'Manager-only claims');
    stamp(claims.utc);
  }
  const team = phase('team-manager'), unit = phase('unit-manager');
  for (const row of [team, unit]) {
    requireProof(row.state === 'passed' && row.profile.access === 'manager'
      && row.profile.manager_scope, 'server-authenticated manager scope');
  }
  const teamScope = team.profile.manager_scope, unitScope = unit.profile.manager_scope;
  requireProof(teamScope.organizations.length === 0 && teamScope.departments.length === 1
    && teamScope.writable_department_ids.length === 0, 'team-only scope');
  requireProof(unitScope.organizations.length === 1 && unitScope.departments.length > 0
    && unitScope.writable_department_ids.length === unitScope.departments.length, 'unit scope');
  const person = phase('person-budget'), admin = phase('restored-admin');
  requireProof(person.state === 'changed-and-restored', 'person write restoration');
  allTrue(admin, ['memberships_exact', 'assignment_tuples_exact']);
  requireProof(admin.state === 'passed' && admin.profile.access === 'admin'
    && admin.profile.manager_scope === null && admin.roles.includes('AUM.Admin'), 'restored Admin');
  const forbidden = manager.receipts.filter(r => r.phase === 'forbidden' && r.status === 403);
  requireProof(forbidden.length >= 4, 'four manager denial boundaries');
  const managers = `${stamp(phase('team-claims').utc)}  Fresh AUM.Manager-only team claims`
    + '\nServer scope: 0 units / 1 team / 0 writable teams'
    + `\n${stamp(person.utc)}  Person budget changed and restored`
    + `\n\n${stamp(phase('unit-claims').utc)}  Fresh AUM.Manager-only unit claims`
    + `\nServer scope: 1 unit / ${count(unitScope.departments.length)} teams / `
    + `${count(unitScope.writable_department_ids.length)} writable teams`
    + `\n${stamp(unit.utc)}  Team budget write passed`
    + `\n${count(forbidden.length)} protected-operation checks returned 403`
    + `\n\n${stamp(admin.utc)}  Fresh Admin / unrestricted server scope restored`
    + `\n${count(managerVerified.MembershipCount)} memberships and `
    + `${count(managerVerified.DirectAssignmentTupleCount)} direct assignment tuples exact`
    + `\n${stamp(managerVerified.VerifiedUtc)}  Named values exact; `
    + `${count(managerVerified.GroupsVerifiedAbsent)} temporary groups verified absent`;
  const provenance = 'Measured direct HTTP with Azure CLI tokens; not native AUM commands/TUI or portal screenshots.';
  return [
    ['aum-12-live-modes', 'Real Claude enforcement and attribution', modes,
      `${provenance} Counters and notices are approximate; these are observed transitions, not exact financial ceilings.`],
    ['aum-13-live-warning', 'The warning timer produced a versioned fact', warning,
      `${provenance} The scheduled Function ran; no local timer invocation or email delivery is claimed.`],
    ['aum-14-live-managers', 'Manager-only authority and exact restoration', managers, provenance],
  ];
}
