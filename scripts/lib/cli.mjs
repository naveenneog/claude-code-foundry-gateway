import { parseArgs } from 'node:util';

export const commands = {
  'capture-transcripts': ['Capture redacted offline command plans', 'output-path'],
  'debug-claude-code': ['Inspect clients and probe the gateway (inference unless skipped)', 'gateway-base-url models app-insights-id skip-live-call!'],
  'find-claude-user-data': ['Discover subject data; query failures are errors', 'user since'],
  'get-claude-analytics': ['Read usage analytics', 'date days'],
  'get-claude-budget': ['Read effective budgets and usage', 'user'],
  'get-claude-bypass': ['Audit direct Foundry role grants', 'foundry-account include-read!'],
  'get-claude-telemetry': ['Resolve telemetry from gateway diagnostics', 'api-id quiet!'],
  'get-foundry-values': ['Discover Foundry deployment values', 'resource mask!'],
  'import-claude-entitlement': ['Resolve a roster and add group members with --execute', 'csv from-group tier standard-group premium-group user-column tier-column report-path execute!'],
  'import-claude-memory': ['Import Markdown from --path or stdin', 'path scope destination title replace!'],
  'new-claude-code-policy': ['Generate managed settings and MDM payloads', 'config-path gateway-url opus-model sonnet-model haiku-model tier available-models desktop-tabs hardening conversation-storage config-dir otlp-endpoint capture-content! output-path'],
  'new-onboarding-email': ['Generate HTML, text and EML; optionally --send', 'config-path to display-name tier distribution-url support-contact output-path send!'],
  'remove-claude-user-data': ['Preview purge; --execute submits irreversible deletion', 'user since execute! wait!'],
  'repair-script-encoding': ['Check or repair PowerShell UTF-8 BOMs', 'root check!'],
  'set-claude-budget': ['Set, clear or list daily overrides', 'user tokens clear! list!'],
  'set-gateway-policy': ['Apply XML policy to API Management', 'policy-file api-id subscription-id'],
  'show-governance': ['Live governance checks; throttle mutation requires --execute', 'second-identity-path model skip-throttle-test! execute!'],
  'sync-claude-access': ['Synchronize group membership into gateway entitlement', 'standard-group premium-group additional-standard-oids additional-premium-oids allow-empty!'],
  'test-foundry-direct': ['Check deployments, auth and inference', 'resource model skip-live-call!']
};

export function optionsFor(command, argv) {
  const spec = commands[command];
  if (!spec) throw new Error('Unknown command');
  const options = Object.fromEntries(`help! dry-run! what-if! as-json! resource-group apim-name app-insights-name ${spec[1]}`.split(' ').filter(Boolean).map(key => [key.replace(/!$/, ''), { type: key.endsWith('!') ? 'boolean' : 'string' }]));
  return parseArgs({ args: argv, options, strict: true, allowPositionals: false }).values;
}

export function exitCodeForResult(command, result) {
  return command === 'get-claude-bypass' && result?.bypass_count > 0 ? 1 : 0;
}

export async function main(command, argv) {
  const options = optionsFor(command, argv);
  if (options.help) {
    console.log(`Usage: bash scripts/${command}.sh [options]\n${commands[command][0]}\n--dry-run: offline plan, no authentication, network or file writes\n--what-if: alias for --dry-run\n--as-json: structured output (default)\n--resource-group --apim-name --app-insights-name\n${commands[command][1].split(' ').map(key => `--${key.replace('!', '')}${key.endsWith('!') ? '' : ' <value>'}`).join('\n')}\nList values are comma-separated. Requires Node.js with built-in fetch.`);
    return;
  }
  if (options['dry-run'] || options['what-if']) {
    console.log(JSON.stringify({ command, dryRun: true, operation: commands[command][0], options, requirements: commands[command][1], effects: 'No credentials, network, subprocesses or file writes; live discovery is not performed.' }, null, 2));
    return;
  }
  const { run } = await import('./ports.mjs');
  const result = await run(command, options);
  if (result !== undefined) console.log(typeof result === 'string' ? result : JSON.stringify(result, null, 2));
  process.exitCode = exitCodeForResult(command, result);
}

if (process.argv[1]?.endsWith('/cli.mjs')) {
  main(process.argv[2], process.argv.slice(3)).catch(error => {
    console.error(`Error: ${error.message}`);
    process.exitCode = 1;
  });
}