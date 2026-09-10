import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { spawnSync } from 'node:child_process';
import { setTimeout as delay } from 'node:timers/promises';
import { ARM, version, az, token, request, required, gatewayUrl, list, segment, guid, jsonFile } from './common.mjs';
import { local } from './local.mjs';
import { context, telemetry, syncAccess, setBudget, budget, bypass, importEntitlement, query } from './gateway.mjs';
import { analytics, findData, removeData } from './reports.mjs';

const resourceName = value => {
  if (!/^[a-z\d][a-z\d-]{1,62}[a-z\d]$/i.test(value)) throw new Error('Invalid Azure resource name');
  return value;
};

async function probe(base, model, credential) {
  const url = `${gatewayUrl(base)}/v1/messages`;
  const response = await fetch(url, {
    method: 'POST', redirect: 'error', signal: AbortSignal.timeout(90000),
    headers: { Authorization: `Bearer ${credential}`, 'Content-Type': 'application/json', 'anthropic-version': '2023-06-01' },
    body: JSON.stringify({ model, max_tokens: 24, messages: [{ role: 'user', content: 'Reply with exactly: OK' }] })
  });
  const result = { model, status: response.status, tier: response.headers.get('x-claude-tier'), remaining: response.headers.get('x-ratelimit-remaining-tokens'), retry_after: response.headers.get('retry-after') };
  await response.body?.cancel();
  return result;
}

async function direct(options) {
  const name = resourceName(required(options, 'resource'));
  const model = options.model || 'claude-sonnet-5';
  const report = { resource: name, model, inference: null };
  const accounts = az(['cognitiveservices', 'account', 'list']);
  const matches = accounts.filter(account => account.name === name);
  if (matches.length !== 1) throw new Error('Foundry account must resolve uniquely');
  report.deployments = az(['cognitiveservices', 'account', 'deployment', 'list', '-g', matches[0].resourceGroup, '-n', name]).map(deployment => deployment.name);
  if (!report.deployments.includes(model)) throw new Error('Requested model deployment was not found');
  if (!options['skip-live-call']) {
    report.inference = await probe(`https://${name}.services.ai.azure.com/anthropic`, model, token('https://cognitiveservices.azure.com'));
    if (report.inference.status !== 200) throw new Error(`Direct inference failed (HTTP ${report.inference.status})`);
  }
  const status = spawnSync('claude', ['auth', 'status', '--json'], { encoding: 'utf8', timeout: 15000 });
  report.cli_available = !status.error && status.status === 0;
  if (report.cli_available) {
    try { report.cli_auth = JSON.parse(status.stdout); } catch { report.cli_auth = { valid_json: false }; }
  }
  return report;
}

async function debug(options) {
  const gateway = gatewayUrl(required(options, 'gateway-base-url'));
  const result = { gateway, checks: [], clients: {} };
  for (const [name, args] of [['az', ['version']], ['claude', ['--version']], ['code', ['--version']]]) {
    const status = spawnSync(name, args, { encoding: 'utf8', timeout: 15000 });
    result.clients[name] = { installed: !status.error && status.status === 0 };
  }
  const settings = join(homedir(), '.claude/settings.json');
  if (existsSync(settings)) {
    const config = jsonFile(settings);
    result.cli_settings = { foundry: config.env?.CLAUDE_CODE_USE_FOUNDRY === '1', gateway_matches: config.env?.ANTHROPIC_FOUNDRY_BASE_URL?.replace(/\/$/, '') === gateway };
  }
  if (!options['skip-live-call']) {
    const credential = token('https://cognitiveservices.azure.com');
    for (const model of list(options.models || 'claude-sonnet-5,claude-opus-5')) result.checks.push(await probe(gateway, model, credential));
    if (result.checks.some(check => check.status !== 200)) throw new Error('One or more gateway probes failed; verify deployment names and entitlements');
  }
  if (options['app-insights-id']) result.recent_requests = await query(guid(options['app-insights-id']), 'requests | where timestamp > ago(10m) | summarize requests=count()');
  result.platform_note = 'Unix client checks; Windows CIM process and registry checks are not applicable. Recent telemetry is not proof of attribution for these probes.';
  return result;
}

async function values(options) {
  const account = az(['account', 'show']);
  const args = ['cognitiveservices', 'account', 'list'];
  if (options['resource-group']) args.push('-g', options['resource-group']);
  const resources = az(args).filter(item => item.kind === 'AIServices' && (!options.resource || item.name === options.resource));
  const found = [];
  for (const resource of resources) {
    const deployments = az(['cognitiveservices', 'account', 'deployment', 'list', '-g', resource.resourceGroup, '-n', resource.name]).filter(deployment => deployment.properties?.model?.format === 'Anthropic');
    if (deployments.length) found.push({ name: resource.name, resource_group: resource.resourceGroup, endpoint: resource.properties?.endpoint, deployments: deployments.map(deployment => ({ name: deployment.name, model: deployment.properties.model.name })) });
  }
  const result = { tenant_id: account.tenantId, subscription_id: account.id, resources: found };
  if (options.mask) {
    result.tenant_id = '[redacted]'; result.subscription_id = '[redacted]';
    result.resources = found.map(resource => ({ ...resource, name: '[redacted]', resource_group: '[redacted]', endpoint: '[redacted]' }));
  }
  return result;
}

async function governance(ctx, options) {
  const gateway = `https://${resourceName(ctx.name)}.azure-api.net/claude`;
  const model = options.model || 'claude-sonnet-5';
  const mine = token('https://cognitiveservices.azure.com');
  const checks = [await probe(gateway, model, mine)];
  if (options['second-identity-path']) {
    const second = jsonFile(options['second-identity-path']);
    const response = await fetch(`https://login.microsoftonline.com/${guid(second.tenant)}/oauth2/v2.0/token`, {
      method: 'POST', redirect: 'error', signal: AbortSignal.timeout(30000),
      body: new URLSearchParams({ client_id: guid(second.appId), client_secret: second.secret, scope: 'https://cognitiveservices.azure.com/.default', grant_type: 'client_credentials' })
    });
    if (!response.ok) throw new Error('Second identity authentication failed');
    const credential = (await response.json()).access_token;
    if (!credential) throw new Error('Second identity returned no token');
    checks.push(await probe(gateway, model, credential));
  }
  if (checks.some(check => check.status !== 200)) throw new Error('An entitled identity was not served successfully');
  let throttled = null;
  if (options.execute && !options['skip-throttle-test']) {
    if (checks[0].tier !== 'standard') throw new Error('Throttle mutation requires a standard-tier caller');
    const restore = await ctx.getValue('tpm-standard');
    await ctx.setValue('tpm-standard', '100');
    const signals = ['SIGINT', 'SIGTERM'];
    let interrupted = false;
    const stop = () => { interrupted = true; };
    signals.forEach(signal => process.on(signal, stop));
    try {
      await delay(25000);
      for (let attempt = 0; attempt < 15 && !interrupted; attempt++) {
        const response = await probe(gateway, model, mine);
        if (response.status === 429) { throttled = response; break; }
        if (response.status !== 200) throw new Error(`Unexpected throttle-test status ${response.status}`);
      }
    } finally {
      const current = await ctx.getValue('tpm-standard');
      if (current !== '100') throw new Error('Limit changed concurrently; refusing to overwrite another administrator change');
      await ctx.setValue('tpm-standard', restore);
      signals.forEach(signal => process.removeListener(signal, stop));
    }
    if (interrupted) throw new Error('Interrupted; temporary limit restored');
    if (!throttled) throw new Error('Expected throttling was not observed');
  }
  const info = await telemetry(ctx, options);
  const chargeback = await query(info.AppId, 'customMetrics | where timestamp > ago(1h) | where name in ("Prompt Tokens", "Completion Tokens") | summarize tokens=sum(valueSum) by user=tostring(customDimensions.User)');
  return { checks, throttled, throttle_test: options.execute && !options['skip-throttle-test'] ? 'executed' : 'not requested', chargeback, caveat: 'These checks do not establish that all possible bypass paths are closed.' };
}

export async function run(command, options) {
  if (['capture-transcripts', 'import-claude-memory', 'new-claude-code-policy', 'new-onboarding-email', 'repair-script-encoding'].includes(command)) return local(command, options);
  if (command === 'test-foundry-direct') return direct(options);
  if (command === 'debug-claude-code') return debug(options);
  if (command === 'get-foundry-values') return values(options);
  if (command === 'import-claude-entitlement') return importEntitlement(options);
  if (command === 'set-gateway-policy') required(options, 'policy-file');
  const ctx = await context(options);
  switch (command) {
    case 'get-claude-telemetry': {
      const info = await telemetry(ctx, options);
      return options.quiet ? info.AppId : info;
    }
    case 'sync-claude-access': return syncAccess(ctx, { 'standard-group': 'claude-code-standard-sombaner', 'premium-group': 'claude-code-premium-sombaner', ...options });
    case 'get-claude-budget': return budget(ctx, options);
    case 'set-claude-budget': return setBudget(ctx, options);
    case 'get-claude-analytics': return analytics(ctx, options);
    case 'get-claude-bypass': return bypass(ctx, options);
    case 'find-claude-user-data': return findData(ctx, options);
    case 'remove-claude-user-data': return removeData(ctx, options);
    case 'show-governance': return governance(ctx, options);
    case 'set-gateway-policy': {
      const xml = readFileSync(options['policy-file'], 'utf8');
      if (/<!DOCTYPE|<!ENTITY/i.test(xml) || !/<policies(?:\s|>)/.test(xml)) throw new Error('Expected a policy XML document without external entities');
      const uri = `${ctx.base}/apis/${segment(options['api-id'] || 'claude-foundry')}/policies/policy${version}`;
      const current = await request(uri, ARM, { envelope: true });
      const etag = current.headers.get('etag');
      if (!etag) throw new Error('Policy response has no ETag; refusing unguarded replacement');
      await request(uri, ARM, { method: 'PUT', headers: { 'If-Match': etag }, body: { properties: { format: 'rawxml', value: xml } } });
      return { applied: true, gateway: ctx.name };
    }
    default: throw new Error('Unknown command');
  }
}