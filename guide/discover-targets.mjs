// Read-only discovery. Parameters select the same real options shown in the numbered UI.
import fs from 'node:fs';
import { discoverTargets } from './lib/azure-targets.mjs';
const args = process.argv.slice(2);
const options = {};
let output;
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--non-interactive') { options.nonInteractive = true; continue; }
  const value = args[++i];
  if (!value) throw new Error('A parameter value is required');
  const key = args[i - 1];
  if (key === '--output') output = value;
  else if (key === '--resources') options.required = value.split(',');
  else {
    const name = { '--subscription': 'subscription', '--resource-group': 'resourceGroup',
      '--apim-name': 'apimName', '--foundry': 'foundry', '--app-insights': 'appInsights',
      '--workspace': 'workspace', '--vnet': 'vnet', '--subnet': 'subnet', '--key-vault': 'keyVault',
      '--dns-zone': 'dnsZone', '--workbook': 'workbook' }[key];
    if (!name) throw new Error(`Unknown parameter ${key}`);
    options[name] = value;
  }
}
const selected = await discoverTargets(options);
if (output) fs.writeFileSync(output, JSON.stringify(selected, null, 2));
else console.log(JSON.stringify(selected, null, 2));
