import { readFileSync } from 'node:fs';
import { ARM, GRAPH, INSIGHTS, version, az, request, pages, guid, segment, list, overrides, positive, userId, groupId, groupMembers, required, write, choice } from './common.mjs';

export async function context(options) {
  const account = az(['account', 'show']);
  const subscription = guid(options['subscription-id'] || account.id);
  const resourceGroup = options['resource-group'] || process.env.CLAUDE_RG || 'rg-contosohub';
  let name = options['apim-name'];
  if (!name) {
    const gateways = az(['apim', 'list', '-g', resourceGroup]);
    if (gateways.length !== 1) throw new Error('Pass --apim-name when the resource group does not contain exactly one gateway');
    name = gateways[0].name;
  }
  const base = `${ARM}/subscriptions/${subscription}/resourceGroups/${segment(resourceGroup)}/providers/Microsoft.ApiManagement/service/${segment(name)}`;
  const snapshots = new Map();
  return {
    account, subscription, resourceGroup, name, base,
    async getValue(key) {
      const result = await request(`${base}/namedValues/${segment(key)}${version}`, ARM, { envelope: true });
      const value = result.data.properties?.value;
      if (typeof value !== 'string') throw new Error(`Missing named value: ${key}`);
      snapshots.set(key, result.headers.get('etag'));
      return value;
    },
    async setValue(key, value) {
      if (!snapshots.has(key)) await this.getValue(key);
      const etag = snapshots.get(key);
      if (!etag) throw new Error(`No ETag for ${key}; refusing an unguarded update`);
      await request(`${base}/namedValues/${segment(key)}${version}`, ARM, { method: 'PUT', headers: { 'If-Match': etag }, body: { properties: { displayName: key, value, secret: false } } });
      snapshots.delete(key);
    }
  };
}

export async function telemetry(ctx, options) {
  const api = options['api-id'] || 'claude-foundry';
  let diagnostic = await request(`${ctx.base}/apis/${segment(api)}/diagnostics/applicationinsights${version}`, ARM, { optional: true });
  let scope = `api/${api}`;
  if (!diagnostic?.properties?.loggerId) {
    diagnostic = await request(`${ctx.base}/diagnostics/applicationinsights${version}`, ARM, { optional: true });
    scope = 'service';
  }
  let componentId;
  if (diagnostic?.properties?.loggerId) {
    const logger = await request(`${ARM}${diagnostic.properties.loggerId}${version}`);
    componentId = logger.properties?.resourceId;
  }
  if (!componentId && (options['app-insights-name'] || process.env.CLAUDE_APPINSIGHTS)) componentId = `/subscriptions/${ctx.subscription}/resourceGroups/${segment(ctx.resourceGroup)}/providers/Microsoft.Insights/components/${segment(options['app-insights-name'] || process.env.CLAUDE_APPINSIGHTS)}`;
  if (!componentId?.startsWith('/subscriptions/')) throw new Error('Cannot resolve Application Insights from gateway diagnostics');
  const component = await request(`${ARM}${componentId}?api-version=2020-02-02`);
  return { Gateway: ctx.name, AppInsights: component.name, AppId: guid(component.properties.AppId), DiagnosticScope: scope, MetricsEnabled: Boolean(diagnostic?.properties?.metrics), WorkspaceResourceId: component.properties.WorkspaceResourceId };
}

export async function query(appId, kql) {
  const result = await request(`${INSIGHTS}/v1/apps/${guid(appId)}/query`, INSIGHTS, { method: 'POST', body: { query: kql } });
  const table = result.tables?.[0];
  if (!table || !Array.isArray(table.rows) || !Array.isArray(table.columns)) throw new Error('Invalid query response');
  return table.rows.map(row => Object.fromEntries(table.columns.map((column, index) => [column.name, row[index]])));
}

export async function syncAccess(ctx, options, members = groupMembers) {
  const desired = {};
  for (const tier of ['premium', 'standard']) {
    const group = options[`${tier}-group`];
    desired[tier] = new Set([
      ...(group ? (await members(group)).map(user => guid(user.id)) : []),
      ...list(options[`additional-${tier}-oids`]).map(guid)
    ]);
  }
  for (const id of desired.premium) desired.standard.delete(id);
  for (const tier of ['standard', 'premium']) {
    const old = await ctx.getValue(`allow-${tier}`);
    if (!options['allow-empty'] && !desired[tier].size && list(old).length) throw new Error(`Refusing to empty ${tier}; pass --allow-empty deliberately`);
  }
  for (const tier of ['standard', 'premium']) await ctx.setValue(`allow-${tier}`, `,${[...desired[tier]].sort().join(',')},`);
  return { standard: desired.standard.size, premium: desired.premium.size, synchronized: true };
}

export async function setBudget(ctx, options) {
  const map = overrides(await ctx.getValue('quota-overrides'));
  if (options.list) return Object.fromEntries(map);
  const id = await userId(required(options, 'user'));
  if (options.clear) map.delete(id);
  else map.set(id, positive(required(options, 'tokens')));
  await ctx.setValue('quota-overrides', `,${[...map].map(([key, value]) => `${key}=${value}`).join(',')},`);
  return { object_id: id, tokens_per_day: map.get(id) ?? null };
}

export async function budget(ctx, options) {
  const limits = {};
  for (const key of ['tpm-standard', 'quota-standard', 'tpm-premium', 'quota-premium', 'quota-org', 'quota-overrides', 'allow-standard', 'allow-premium']) limits[key] = await ctx.getValue(key);
  const override = overrides(limits['quota-overrides']);
  const info = await telemetry(ctx, options);
  if (!info.MetricsEnabled) throw new Error('Token metrics are disabled; spend is unknown');
  const usage = await query(info.AppId, 'customMetrics | where timestamp >= startofmonth(now()) | where name in ("Prompt Tokens", "Completion Tokens") | extend uid=tostring(customDimensions.UserId), upn=tostring(customDimensions.User) | summarize tokens=sum(valueSum), upn=take_any(upn) by uid');
  const spent = new Map(usage.map(row => [row.uid, row]));
  const seen = new Set(), developers = [];
  for (const tier of ['premium', 'standard']) {
    for (const id of list(limits[`allow-${tier}`]).map(guid)) {
      if (seen.has(id)) continue;
      seen.add(id);
      const row = spent.get(id);
      const tierDefault = positive(limits[`quota-${tier}`]);
      developers.push({ object_id: id, upn: row?.upn || null, tier, effective: { tokens_per_minute: positive(limits[`tpm-${tier}`]), tokens_per_day: override.get(id) ?? tierDefault, tokens_per_day_from: override.has(id) ? 'override' : 'tier', tier_default_per_day: tierDefault }, month_to_date: { tokens: row?.tokens ?? 0, cost_reported: false } });
    }
  }
  const filtered = options.user ? developers.filter(row => row.object_id === options.user.toLowerCase() || row.upn?.toLowerCase() === options.user.toLowerCase()) : developers;
  if (options.user && !filtered.length) throw new Error('No entitled developer matched the filter');
  return { gateway: ctx.name, organisation: { tokens_per_month: positive(limits['quota-org']), month_to_date: usage.reduce((sum, row) => sum + Number(row.tokens), 0), soft_cap: true, per_gateway: true }, developers: filtered };
}

export async function foundry(ctx, options) {
  let name = options['foundry-account'];
  if (!name) {
    const backends = await pages(`${ctx.base}/backends${version}`, ARM);
    const names = [...new Set(backends.map(item => {
      try { return new URL(item.properties.url).hostname.match(/^([a-z\d-]+)\.services\.ai\.azure\.com$/i)?.[1]; } catch { return null; }
    }).filter(Boolean))];
    if (names.length !== 1) throw new Error('Pass --foundry-account: gateway backend discovery is ambiguous');
    name = names[0];
  }
  const accounts = az(['cognitiveservices', 'account', 'list']);
  const matches = accounts.filter(account => account.name === name);
  if (matches.length !== 1) throw new Error('Foundry account lookup is ambiguous');
  return matches[0];
}

export async function bypass(ctx, options) {
  const account = await foundry(ctx, options);
  const service = await request(`${ctx.base}${version}`);
  const assignments = az(['role', 'assignment', 'list', '--scope', account.id, '--include-inherited', '--all']);
  const findings = [];
  for (const assignment of assignments) {
    if (assignment.principalId === service.identity?.principalId) continue;
    const role = await request(`${ARM}${assignment.roleDefinitionId}?api-version=2022-04-01`);
    const permissions = role.properties.permissions || [];
    const relevant = permissions.flatMap(permission => (permission.dataActions || []).filter(action => action === '*' || /Microsoft\.CognitiveServices\//i.test(action)));
    if (!relevant.length) continue;
    const exclusions = permissions.flatMap(permission => permission.notDataActions || []);
    const conditional = Boolean(assignment.condition) || exclusions.length > 0;
    const grade = conditional ? 'review' : relevant.every(action => /\/read$/i.test(action)) ? 'read' : relevant.some(action => action === '*' || /^Microsoft\.CognitiveServices\/\*$/i.test(action)) ? 'full' : 'partial';
    findings.push({ principal_id: assignment.principalId, principal_type: assignment.principalType, role: role.properties.roleName, scope: assignment.scope, assignment_id: assignment.id, grade, data_actions: relevant, not_data_actions: exclusions, condition: assignment.condition || null });
  }
  return { gateway: ctx.name, foundry: account.name, full: findings.filter(row => row.grade === 'full'), partial: findings.filter(row => row.grade === 'partial'), review: findings.filter(row => row.grade === 'review'), read: findings.filter(row => row.grade === 'read'), bypass_count: findings.filter(row => row.grade !== 'read').length };
}

export function csvRows(text) {
  const rows = [], row = [];
  let field = '', quoted = false, closed = false;
  for (let index = 0; index < text.length; index++) {
    const char = text[index];
    if (quoted) {
      if (char === '"' && text[index + 1] === '"') { field += '"'; index++; }
      else if (char === '"') { quoted = false; closed = true; }
      else field += char;
    } else if (char === '"' && !field && !closed) quoted = true;
    else if (char === ',' || char === '\n' || char === '\r') {
      row.push(field); field = ''; closed = false;
      if (char !== ',') { rows.push([...row]); row.length = 0; if (char === '\r' && text[index + 1] === '\n') index++; }
    } else {
      if (closed || char === '"') throw new Error('Malformed CSV quoting');
      field += char;
    }
  }
  if (quoted) throw new Error('Unterminated CSV field');
  if (field || row.length || closed) { row.push(field); rows.push(row); }
  const headers = rows.shift()?.map(value => value.replace(/^\uFEFF/, '').trim());
  if (!headers?.length || headers.some(header => !header) || new Set(headers).size !== headers.length) throw new Error('Missing or duplicate CSV headers');
  return rows.filter(record => record.some(Boolean)).map(record => {
    if (record.length !== headers.length) throw new Error('CSV row has the wrong field count');
    return Object.fromEntries(headers.map((key, index) => [key, record[index]]));
  });
}

export async function importEntitlement(options, services = { userId, groupId, groupMembers, request }) {
  if (Boolean(options.csv) === Boolean(options['from-group'])) throw new Error('Specify exactly one of --csv or --from-group');
  const tier = choice(options.tier || 'standard', ['standard', 'premium']);
  let roster;
  if (options.csv) {
    const rows = csvRows(readFileSync(options.csv, 'utf8'));
    if (!rows.length) throw new Error('Roster has no rows');
    const headers = Object.keys(rows[0]);
    const column = (explicit, candidates) => explicit || candidates.map(candidate => headers.find(header => header.toLowerCase() === candidate)).find(Boolean);
    const userColumn = column(options['user-column'], ['userprincipalname', 'upn', 'email', 'emailaddress', 'mail', 'user', 'member', 'signinname']) || headers[0];
    const tierColumn = column(options['tier-column'], ['tier', 'claudetier', 'level', 'plan']);
    if (!headers.includes(userColumn) || (tierColumn && !headers.includes(tierColumn))) throw new Error('Requested roster column does not exist');
    roster = rows.map(row => ({ user: row[userColumn].trim(), tier: (row[tierColumn] || tier).trim().toLowerCase() }));
  } else roster = (await services.groupMembers(options['from-group'])).map(user => ({ user: user.id, tier }));
  const resolved = new Map();
  for (const row of roster) {
    if (!row.user) throw new Error('Roster row has no user identifier');
    choice(row.tier, ['standard', 'premium']);
    const id = await services.userId(row.user);
    if (resolved.get(id)?.tier !== 'premium') resolved.set(id, { object_id: id, user: row.user, tier: row.tier });
  }
  const reports = [];
  for (const name of ['standard', 'premium']) {
    const entries = [...resolved.values()].filter(row => row.tier === name);
    if (!entries.length) continue;
    const target = await services.groupId(options[`${name}-group`] || (name === 'standard' ? 'claude-code-standard-sombaner' : 'claude-code-premium-sombaner'));
    const current = new Set((await services.groupMembers(target, false)).map(user => user.id));
    for (const row of entries) {
      reports.push({ ...row, group: target, status: current.has(row.object_id) ? 'already-member' : 'would-add' });
    }
  }
  for (const row of reports) {
    if (row.status !== 'would-add' || !options.execute) continue;
    await services.request(`${GRAPH}/v1.0/groups/${row.group}/members/$ref`, GRAPH, { method: 'POST', body: { '@odata.id': `${GRAPH}/v1.0/directoryObjects/${row.object_id}` } });
    row.status = 'added';
  }
  if (options['report-path']) {
    const headers = ['object_id', 'user', 'tier', 'group', 'status'];
    const quoted = value => `"${String(value).replace(/"/g, '""')}"`;
    write(options['report-path'], [headers, ...reports.map(row => headers.map(key => row[key]))].map(row => row.map(quoted).join(',')).join('\r\n') + '\r\n');
  }
  return reports;
}