import { readFileSync } from 'node:fs';
import { setTimeout as delay } from 'node:timers/promises';
import { ARM, request, positive, required, userId, pages } from './common.mjs';
import { telemetry, query } from './gateway.mjs';

export function analyticsEnvelope(rows, tenantId) {
  const groups = new Map();
  const count = value => value === null || value === undefined || value === '' ? null : Math.round(Number(value));
  for (const row of rows) {
    const key = JSON.stringify([row.date, row.actor]);
    if (!groups.has(key)) groups.set(key, {
      date: new Date(row.date).toISOString().replace('.000Z', 'Z'), actor: { type: 'user_actor', email_address: row.actor }, organization_id: tenantId, customer_type: 'foundry', terminal_type: row.terminal_type || null,
      core_metrics: { num_sessions: count(row.num_sessions), lines_of_code: { added: count(row.lines_added), removed: count(row.lines_removed) }, commits_by_claude_code: count(row.commits), pull_requests_by_claude_code: count(row.pull_requests) },
      tool_actions: { edit_tool: { accepted: count(row.tool_accepted), rejected: count(row.tool_rejected) } }, model_breakdown: []
    });
    groups.get(key).model_breakdown.push({ model: row.model, tokens: { input: count(row.tokens_input), output: count(row.tokens_output), cache_read: count(row.tokens_cache_read), cache_creation: null }, estimated_cost: { currency: 'USD', amount: row.estimated_cost_usd === undefined || row.estimated_cost_usd === '' || row.estimated_cost_usd === null ? null : Number(row.estimated_cost_usd), is_estimate: true } });
  }
  return { data: [...groups.values()], has_more: false, next_page: null };
}

export function analyticsQuery(options) {
  const days = positive(options.days || 1);
  const end = options.date || new Date(Date.now() - 86400000).toISOString().slice(0, 10);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(end) || Number.isNaN(Date.parse(end)) || new Date(end).toISOString().slice(0, 10) !== end) throw new Error('Date must be a valid yyyy-MM-dd');
  const start = new Date(Date.parse(end) - (days - 1) * 86400000).toISOString().slice(0, 10);
  return readFileSync(new URL('../../analytics/claude-code-daily.kql', import.meta.url), 'utf8').replace(/^\s*\/\/.*$/gm, '').replace('let _day = startofday(ago(1d));', `let _day = datetime(${start});`).replace('let _next = _day + 1d;', `let _next = _day + ${days}d;`);
}

export async function analytics(ctx, options) {
  const kql = analyticsQuery(options);
  const info = await telemetry(ctx, options);
  if (!info.MetricsEnabled) throw new Error('Metrics are disabled; analytics would be incomplete');
  return analyticsEnvelope(await query(info.AppId, kql), ctx.account.tenantId);
}

export async function findData(ctx, options) {
  const id = await userId(required(options, 'user'));
  const since = positive(options.since || 90);
  const info = await telemetry(ctx, options);
  if (!info.WorkspaceResourceId?.startsWith('/subscriptions/')) throw new Error('Cannot resolve telemetry workspace');
  const plans = new Map((await pages(`${ARM}${info.WorkspaceResourceId}/tables?api-version=2022-10-01`, ARM)).map(table => [table.name, table.properties.plan]));
  const definitions = [['customMetrics', 'AppMetrics'], ['customEvents', 'AppEvents'], ['requests', 'AppRequests'], ['traces', 'AppTraces'], ['AppGenAIContent', 'AppGenAIContent']];
  const findings = [];
  for (const [table, workspaceTable] of definitions) {
    if (!plans.has(workspaceTable)) continue;
    const content = table === 'AppGenAIContent';
    const time = content ? 'TimeGenerated' : 'timestamp';
    const column = content ? 'Attributes' : 'customDimensions';
    const rows = await query(info.AppId, `${table}\n| where ${time} > ago(${since}d)\n| where tostring(${column}.UserId) == "${id}"\n| summarize rows=count(), earliest=min(${time}), latest=max(${time})`);
    if (rows.length !== 1 || typeof rows[0].rows !== 'number') throw new Error('Compliance query returned an incomplete result');
    if (rows[0].rows) findings.push({ table, workspace_table: workspaceTable, column: content ? 'Attributes' : 'Properties', key: 'UserId', ...rows[0], plan: plans.get(workspaceTable), purgeable: plans.get(workspaceTable) === 'Analytics' });
  }
  return { subject: { object_id: id, upn: options.user === id ? null : options.user }, workspace: { app_insights: info.AppInsights, app_id: info.AppId, workspace_resource_id: info.WorkspaceResourceId }, window_days: since, findings, total_rows: findings.reduce((sum, row) => sum + row.rows, 0) };
}

export async function removeData(ctx, options) {
  const data = await findData(ctx, options);
  if (!options.execute) return { ...data, execute: false, message: 'Preview only; --execute submits irreversible purge requests.' };
  if (data.findings.some(row => !row.purgeable)) throw new Error('Some matching tables cannot be purged; no deletion requests submitted');
  const operations = [];
  for (const row of data.findings) {
    const result = await request(`${ARM}${data.workspace.workspace_resource_id}/purge?api-version=2023-09-01`, ARM, { method: 'POST', envelope: true, body: { table: row.workspace_table, filters: [{ column: row.column, key: row.key, operator: '==', value: data.subject.object_id }, { column: 'TimeGenerated', operator: '>', value: new Date(Date.now() - data.window_days * 86400000).toISOString() }] } });
    const statusUrl = result.headers.get('x-ms-status-location');
    operations.push({ table: row.workspace_table, operation: result.data, status_url: statusUrl });
    if (options.wait) {
      if (!statusUrl) throw new Error('Purge accepted without a status URL; cannot confirm completion');
      const deadline = Date.now() + 600000;
      let completed = false;
      while (Date.now() < deadline) {
        const state = await request(statusUrl, ARM);
        if (String(state.status).toLowerCase() === 'completed') { completed = true; break; }
        if (['failed', 'canceled'].includes(String(state.status).toLowerCase())) throw new Error('Purge operation failed');
        await delay(10000);
      }
      if (!completed) throw new Error('Purge wait timed out; submission is not confirmation of deletion');
    }
  }
  return { subject: data.subject, operations, submitted: true, completed: Boolean(options.wait) };
}