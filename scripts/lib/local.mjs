import { readFileSync, readdirSync, existsSync, copyFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { homedir } from 'node:os';
import { randomUUID } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { required, gatewayUrl, list, jsonFile, write, escapeXml, choice, request, GRAPH } from './common.mjs';

function plist(value) {
  if (typeof value === 'boolean') return value ? '<true/>' : '<false/>';
  if (typeof value === 'number') return `<integer>${value}</integer>`;
  if (Array.isArray(value)) return `<array>${value.map(plist).join('')}</array>`;
  if (value && typeof value === 'object') return `<dict>${Object.entries(value).map(([key, entry]) => `<key>${escapeXml(key)}</key>${plist(entry)}`).join('')}</dict>`;
  return `<string>${escapeXml(value)}</string>`;
}

function policy(options) {
  const config = options['config-path'] ? jsonFile(options['config-path']) : {};
  const gateway = gatewayUrl(options['gateway-url'] || config.gatewayUrl);
  const sonnet = options['sonnet-model'] || config.models?.find(model => model.includes('sonnet')) || 'claude-sonnet-5';
  const opus = options['opus-model'] || config.models?.find(model => model.includes('opus')) || 'claude-opus-5';
  const haiku = options['haiku-model'] || sonnet;
  const tier = choice(options.tier || 'standard', ['standard', 'premium']);
  const hardening = choice(options.hardening || 'basic', ['none', 'basic', 'strict']);
  const tabs = choice(options['desktop-tabs'] || 'default', ['default', 'chat-only', 'no-cowork']);
  const env = { CLAUDE_CODE_USE_FOUNDRY: '1', ANTHROPIC_FOUNDRY_BASE_URL: gateway, ANTHROPIC_DEFAULT_OPUS_MODEL: opus, ANTHROPIC_DEFAULT_SONNET_MODEL: sonnet, ANTHROPIC_DEFAULT_HAIKU_MODEL: haiku };
  const settings = { env, availableModels: [...new Set(options['available-models'] ? list(options['available-models']) : tier === 'premium' ? [opus, sonnet, haiku] : [sonnet, haiku])] };
  if (hardening !== 'none') settings.permissions = { deny: ['Read(./.env)', 'Read(./.env.*)', 'Read(./secrets/**)', 'Read(**/id_rsa)', 'Read(**/*.pem)'] };
  if (hardening === 'strict') {
    settings.permissions.disableBypassPermissionsMode = 'disable';
    settings.allowManagedPermissionRulesOnly = true;
  }
  const storage = choice(options['conversation-storage'] || 'local', ['local', 'redirected', 'audited']);
  if (storage === 'redirected') env.CLAUDE_CONFIG_DIR = required(options, 'config-dir');
  if (storage === 'audited') {
    Object.assign(env, { CLAUDE_CODE_ENABLE_TELEMETRY: '1', OTEL_LOGS_EXPORTER: 'otlp', OTEL_METRICS_EXPORTER: 'otlp', OTEL_EXPORTER_OTLP_PROTOCOL: 'grpc', OTEL_EXPORTER_OTLP_ENDPOINT: gatewayUrl(required(options, 'otlp-endpoint')) });
    if (options['capture-content']) Object.assign(env, { OTEL_LOG_USER_PROMPTS: '1', OTEL_LOG_ASSISTANT_RESPONSES: '1' });
  }
  const base = join(options['output-path'] || './policy-claude-code', 'claude-code');
  const text = JSON.stringify(settings, null, 2);
  write(`${base}.managed-settings.json`, text + '\n');
  write(`${base}.desktop-settings.json`, JSON.stringify({ chatTabEnabled: true, coworkTabEnabled: tabs === 'default', isClaudeCodeForDesktopEnabled: tabs !== 'chat-only' }, null, 2));
  const escaped = JSON.stringify(settings).replace(/\\/g, '\\\\').replace(/"/g, '\\"');
  write(`${base}.reg`, Buffer.from(`\uFEFFWindows Registry Editor Version 5.00\r\n\r\n[HKEY_LOCAL_MACHINE\\SOFTWARE\\Policies\\ClaudeCode]\r\n"Settings"="${escaped}"\r\n`, 'utf16le'));
  write(`${base}.intune-omauri.csv`, `"OMA-URI","Data type","Value"\r\n"./Device/Vendor/MSFT/Policy/Config/ClaudeCode/Settings","String","${JSON.stringify(settings).replace(/"/g, '""')}"\r\n`);
  const profile = { PayloadDisplayName: 'Claude Code managed settings', PayloadIdentifier: 'com.anthropic.claudecode.foundry', PayloadType: 'Configuration', PayloadUUID: randomUUID(), PayloadVersion: 1, PayloadScope: 'System', PayloadContent: [{ PayloadType: 'com.anthropic.claudecode', PayloadIdentifier: 'com.anthropic.claudecode.foundry.settings', PayloadUUID: randomUUID(), PayloadVersion: 1, ...settings }] };
  write(`${base}.mobileconfig`, `<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">${plist(profile)}</plist>\n`);
  write(`${base}.apply.sh`, `#!/usr/bin/env bash
set -euo pipefail
case "$(uname -s)" in
  Darwin) destination='/Library/Application Support/ClaudeCode' ;;
  Linux) destination='/etc/claude-code' ;;
  *) printf 'Unsupported platform\\n' >&2; exit 1 ;;
esac
case "\${1:---dry-run}" in
  --dry-run) printf 'Would install managed-settings.json in %s\\n' "$destination"; exit 0 ;;
  --execute) ;;
  *) printf 'Usage: bash claude-code.apply.sh [--dry-run|--execute]\\n' >&2; exit 2 ;;
esac
if [[ -L "$destination" || -L "$destination/managed-settings.json" ]]; then
  printf 'Refusing symbolic link destination\\n' >&2; exit 1
fi
mkdir -p "$destination"
install -m 644 "$(dirname "$0")/claude-code.managed-settings.json" "$destination/managed-settings.json"
`);
  write(`${base}.apply.ps1`, `[CmdletBinding(SupportsShouldProcess = $true)]
param()
$ErrorActionPreference = 'Stop'
$destination = 'C:\\Program Files\\ClaudeCode'
if ($PSCmdlet.ShouldProcess($destination, 'Install managed settings; requires an elevated shell')) {
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    Copy-Item (Join-Path $PSScriptRoot 'claude-code.managed-settings.json') (Join-Path $destination 'managed-settings.json') -Force
}
`);
  write(join(options['output-path'] || './policy-claude-code', 'README.md'), 'Deploy one managed policy source per platform. JSON: /Library/Application Support/ClaudeCode/managed-settings.json on macOS; /etc/claude-code/managed-settings.json on Linux. Windows: C:\\Program Files\\ClaudeCode\\managed-settings.json or the registry payload. Review content-capture privacy before deployment. Gateway model allowlists must match this tier. Desktop settings are a separate managed payload.\n');
  return { output: resolve(base), tier, storage, settings };
}

function memory(options) {
  const source = readFileSync(options.path || 0, 'utf8').replace(/^\uFEFF/, '').replace(/^```(?:markdown|md)?\s*\n([\s\S]*?)\n```\s*$/, '$1').trim();
  if (!source) throw new Error('Memory input is empty');
  const scope = choice(options.scope || 'user', ['user', 'managed', 'project']);
  const destination = options.destination || (scope === 'user' ? join(homedir(), '.claude/CLAUDE.md') : scope === 'project' ? join(process.cwd(), 'CLAUDE.md') : process.platform === 'darwin' ? '/Library/Application Support/ClaudeCode/CLAUDE.md' : '/etc/claude-code/CLAUDE.md');
  const start = '<!-- claude-memory-import: begin -->', end = '<!-- claude-memory-import: end -->';
  const block = `${start}\n## ${options.title || 'Imported memory'}\n\n${source}\n${end}`;
  const old = existsSync(destination) ? readFileSync(destination, 'utf8') : '';
  const from = old.indexOf(start), to = old.indexOf(end, from);
  if (from >= 0 && to < from) throw new Error('Existing memory has an incomplete import block');
  const result = options.replace ? block : from >= 0 ? old.slice(0, from) + block + old.slice(to + end.length) : `${old.trimEnd()}${old ? '\n\n' : ''}${block}\n`;
  if (old) copyFileSync(destination, `${destination}.${randomUUID()}.bak`);
  write(destination, result);
  return { destination, imported: true };
}

async function email(options) {
  const config = jsonFile(required(options, 'config-path'));
  gatewayUrl(config.gatewayUrl);
  const to = required(options, 'to');
  if (!/^[^\s<>@,;]+@[^\s<>@,;]+$/.test(to)) throw new Error('Expected one email address without headers');
  const name = options['display-name'] || to.split('@')[0];
  const distribution = options['distribution-url'] ? gatewayUrl(options['distribution-url']) : null;
  const tier = choice(options.tier || 'standard', ['standard', 'premium']);
  const shellQuote = value => `'${value.replace(/'/g, `'"'"'`)}'`;
  const download = distribution ? `curl --proto '=https' --fail --show-error ${shellQuote(distribution + '/setup-claude-workstation.sh')} -o setup-claude-workstation.sh\n` : '';
  const command = `${download}bash setup-claude-workstation.sh --config ./claude-gateway.json --gateway-url ${shellQuote(config.gatewayUrl)}`;
  const text = `Hello ${name},\n\nYour Claude gateway is ${config.gatewayUrl}. Confirm this address with your administrator before setup.\nTier: ${tier}. Daily token limit: ${config.tiers?.[tier]?.tokensPerDay ?? 'confirm with your administrator'}.\n\nUse the attached claude-gateway.json and the setup script supplied by your administrator.\n${command}\n\nReview downloaded scripts before running them. Your organisation controls telemetry and optional content capture. Support: ${options['support-contact'] || 'your platform team'}.\n`;
  const html = `<html><body><pre>${escapeXml(text)}</pre></body></html>`;
  const output = options['output-path'] || './onboarding';
  const base = join(output, to.replace(/[^a-z\d]/gi, '-'));
  write(`${base}.txt`, text);
  write(`${base}.html`, html);
  const boundary = `claude-${randomUUID()}`;
  const attachment = Buffer.from(JSON.stringify(config, null, 2)).toString('base64').match(/.{1,76}/g).join('\r\n');
  write(`${base}.eml`, `To: ${to}\r\nSubject: Claude gateway onboarding\r\nMIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary="${boundary}"\r\n\r\n--${boundary}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n${Buffer.from(html).toString('base64').match(/.{1,76}/g).join('\r\n')}\r\n--${boundary}\r\nContent-Type: application/json; name="claude-gateway.json"\r\nContent-Disposition: attachment; filename="claude-gateway.json"\r\nContent-Transfer-Encoding: base64\r\n\r\n${attachment}\r\n--${boundary}--\r\n`);
  if (options.send) await request(`${GRAPH}/v1.0/me/sendMail`, GRAPH, { method: 'POST', body: { message: { subject: 'Claude gateway onboarding', body: { contentType: 'HTML', content: html }, toRecipients: [{ emailAddress: { address: to } }], attachments: [{ '@odata.type': '#microsoft.graph.fileAttachment', name: 'claude-gateway.json', contentType: 'application/json', contentBytes: Buffer.from(JSON.stringify(config)).toString('base64') }] }, saveToSentItems: true } });
  return { output: resolve(base), sent: Boolean(options.send) };
}

function repair(options) {
  const files = [];
  function visit(directory) {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      if (entry.isSymbolicLink() || ['node_modules', '.git'].includes(entry.name)) continue;
      const path = join(directory, entry.name);
      if (entry.isDirectory()) visit(path);
      else if (entry.name.endsWith('.ps1')) {
        const bytes = readFileSync(path);
        new TextDecoder('utf-8', { fatal: true }).decode(bytes);
        if (bytes.some(byte => byte > 127) && !bytes.subarray(0, 3).equals(Buffer.from([239, 187, 191]))) {
          files.push(path);
          if (!options.check) write(path, Buffer.concat([Buffer.from([239, 187, 191]), bytes]));
        }
      }
    }
  }
  visit(options.root || process.cwd());
  if (options.check && files.length) throw new Error(`UTF-8 BOM missing in ${files.length} PowerShell file(s)`);
  return { repaired: files };
}

export async function local(command, options) {
  if (command === 'new-claude-code-policy') return policy(options);
  if (command === 'import-claude-memory') return memory(options);
  if (command === 'new-onboarding-email') return email(options);
  if (command === 'repair-script-encoding') return repair(options);
  if (command === 'capture-transcripts') {
    const { commands } = await import('./cli.mjs');
    const output = options['output-path'] || './docs/transcripts';
    for (const name of Object.keys(commands)) {
      const result = spawnSync(process.execPath, [fileURLToPath(new URL('./cli.mjs', import.meta.url)), name, '--dry-run'], { encoding: 'utf8', timeout: 5000 });
      if (result.error || result.status !== 0) throw new Error(`Offline transcript failed for ${name}`);
      write(join(output, `${name}.txt`), `$ bash scripts/${name}.sh --dry-run\n${result.stdout}`);
    }
    return { output, mode: 'offline', transcripts: Object.keys(commands).length };
  }
  throw new Error('Unknown local command');
}