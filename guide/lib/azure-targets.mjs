import { createInterface } from 'node:readline/promises';
import { stdin, stdout } from 'node:process';
import { az, ps } from './turnstile-live.mjs';

export function chosenOption(options, requested, preferred, nonInteractive) {
  const matches = (value) => options.filter((item) => item.id === value || item.name === value);
  if (requested) {
    const found = matches(requested);
    if (found.length !== 1) throw new Error('The requested value is missing or ambiguous in the discovered options');
    return found[0];
  }
  if (options.length === 1) return options[0];
  const defaults = preferred ? matches(preferred) : [];
  if (nonInteractive) {
    if (defaults.length === 1) return defaults[0];
    throw new Error('Multiple discovered options: pass an explicit parameter for non-interactive use');
  }
  return null;
}

export async function choose(label, options, requested, preferred, nonInteractive = !stdin.isTTY) {
  const flag = { subscription: '--subscription', 'resource group': '--resource-group',
    'API Management instance': '--apim-name', foundry: '--foundry',
    appInsights: '--app-insights', workspace: '--workspace', vnet: '--vnet',
    subnet: '--subnet', keyVault: '--key-vault', dnsZone: '--dns-zone',
    workbook: '--workbook', 'upstream endpoint': '--upstream' }[label] ?? `--${label}`;
  if (!options.length) throw new Error(`No accessible ${label} found. Check the signed-in subscription and pass ${flag} after discovering an accessible resource.`);
  let selected;
  try { selected = chosenOption(options, requested, preferred, nonInteractive); }
  catch (error) { throw new Error(`${error.message}. Select ${label} with ${flag}.`); }
  if (selected) return selected;
  const defaultIndex = Math.max(0, options.findIndex((item) => item.id === preferred || item.name === preferred));
  console.log(`\nChoose ${label}:`);
  options.forEach((item, index) => console.log(`  ${index + 1}. ${item.name} (${item.resourceGroup ?? item.id})${index === defaultIndex ? ' [default]' : ''}`));
  const input = createInterface({ input: stdin, output: stdout });
  try {
    const answer = await input.question(`Selection [${defaultIndex + 1}]: `);
    const index = answer.trim() ? Number(answer) - 1 : defaultIndex;
    if (!Number.isInteger(index) || !options[index]) throw new Error('Choose a numbered option from the discovered list');
    return options[index];
  } finally { input.close(); }
}

const types = {
  foundry: 'Microsoft.CognitiveServices/accounts',
  appInsights: 'Microsoft.Insights/components',
  workspace: 'Microsoft.OperationalInsights/workspaces',
  vnet: 'Microsoft.Network/virtualNetworks',
  keyVault: 'Microsoft.KeyVault/vaults',
  dnsZone: 'Microsoft.Network/privateDnsZones',
  workbook: 'Microsoft.Insights/workbooks',
};

export async function discoverTargets(options = {}) {
  const nonInteractive = options.nonInteractive ?? !stdin.isTTY;
  const required = options.required ?? ['apim'];
  const subscriptions = JSON.parse(az(['account', 'list', '-o', 'json'])).filter((s) => s.state === 'Enabled');
  const current = JSON.parse(az(['account', 'show', '-o', 'json']));
  const subscription = await choose('subscription', subscriptions, options.subscription, current.id, nonInteractive);
  // Do not change the shared CLI account selection; scope ARM queries explicitly.
  const scopedAz = (args) => JSON.parse(az([...args, '--subscription', subscription.id, '-o', 'json']));
  const recordedGroup = ps('& ./scripts/Get-ClaudeGatewayTarget.ps1 ResourceGroup 3>$null');
  const recordedApim = ps('& ./scripts/Get-ClaudeGatewayTarget.ps1 ApimName 3>$null');
  const groups = scopedAz(['group', 'list']);
  const group = await choose('resource group', groups,
    options.resourceGroup ?? process.env.GATEWAY_RG ?? process.env.CLAUDE_RG,
    recordedGroup, nonInteractive);
  const result = { subscriptionId: subscription.id, tenantId: subscription.tenantId, resourceGroup: group.name };
  if (required.includes('apim')) {
    const gateways = scopedAz(['apim', 'list', '--resource-group', group.name]);
    result.apim = await choose('API Management instance', gateways,
      options.apimName ?? process.env.GATEWAY_APIM ?? process.env.APIM_NAME ?? process.env.CLAUDE_APIM,
      recordedApim, nonInteractive);
  }
  for (const key of required.filter((key) => key in types)) {
    const resources = scopedAz(['resource', 'list', '--resource-type', types[key]]);
    const local = resources.filter((resource) => resource.resourceGroup?.toLowerCase() === group.name.toLowerCase());
    result[key] = await choose(key, resources, options[key],
      local.length === 1 ? local[0].id : undefined, nonInteractive);
  }
  if (required.includes('subnet')) {
    if (!result.vnet) throw new Error('Subnet discovery requires vnet discovery');
    result.subnet = await choose('subnet', scopedAz(['network', 'vnet', 'subnet', 'list',
      '--resource-group', result.vnet.resourceGroup, '--vnet-name', result.vnet.name]),
    options.subnet, undefined, nonInteractive);
  }
  if (result.apim) {
    const all = scopedAz(['apim', 'nv', 'list', '--resource-group', group.name, '--service-name', result.apim.name]);
    result.namedValues = all.filter((item) => !item.secret && !item.properties?.secret);
  }
  return result;
}
