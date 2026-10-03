(function(){
'use strict';
const fieldGroups = {
  foundation: ['SubscriptionId', 'FoundryAccount', 'FoundryResourceGroup', 'ResourceGroup', 'Location', 'NamePrefix', 'PublisherEmail', 'Sku'],
  access: ['StandardGroup', 'PremiumGroup', 'TpmStandard', 'QuotaStandard', 'TpmPremium', 'QuotaPremium', 'QuotaOrg', 'CallsPerMinute', 'StandardModels', 'PremiumModels'],
  optional: ['AddressMode', 'AddressHostname', 'AddressCertificateSource', 'AddressKeyVaultCertificateId', 'AddressPfxPath', 'AddressDnsMode', 'DesktopSignInKind', 'DesktopEntraClientId', 'DeployProjection', 'EntitlementStore', 'monitoring.enabled', 'reports.enabled'],
};

function coerceAnswerValue(property, raw) {
  if (raw === undefined || raw === null || raw === '') return undefined;
  if (property.type === 'integer') return Number.parseInt(String(raw), 10);
  if (property.type === 'number') return Number(raw);
  if (property.type === 'boolean') {
    if (raw === true || raw === 'true') return true;
    if (raw === false || raw === 'false') return false;
    return undefined;
  }
  if (property.type === 'array') {
    if (Array.isArray(raw)) return raw.filter((item) => String(item).trim()).map(String);
    return String(raw).split(',').map((item) => item.trim()).filter(Boolean);
  }
  return String(raw);
}

function collectAnswersFromEntries(schema, entries, businessUnitsText = '') {
  const out = { schemaVersion: 1 };
  for (const [name, property] of Object.entries(schema.properties || {})) {
    if (!entries.has(name)) continue;
    const value = coerceAnswerValue(property, entries.get(name));
    if (value !== undefined && !(Array.isArray(value) && value.length === 0)) out[name] = value;
  }
  const text = String(businessUnitsText || '').trim();
  if (text) out.BusinessUnits = JSON.parse(text);
  return out;
}

function fieldsByCheckId(schema) {
  const map = {};
  for (const [name, property] of Object.entries(schema.properties || {})) {
    const id = property['x-checkId'];
    if (!id) continue;
    map[id] ??= [];
    map[id].push(name);
  }
  const unit = schema?.$defs?.BusinessUnit;
  for (const [name, property] of Object.entries(unit?.properties || {})) {
    const id = property['x-checkId'];
    if (!id) continue;
    map[id] ??= [];
    map[id].push(`BusinessUnits.${name}`);
  }
  return map;
}

function validateBusinessUnits(units) {
  const problems = [];
  if (!Array.isArray(units)) return ['BusinessUnits is not a list'];
  const ids = new Set();
  for (const [index, unit] of units.entries()) {
    const label = `BusinessUnits[${index}]`;
    if (!/^[a-z0-9][a-z0-9-]*$/.test(String(unit.id || '')) || String(unit.id || '').length > 64) problems.push(`${label}.id is not lower-case letters, digits and hyphens, max 64`);
    if (ids.has(unit.id)) problems.push(`${label}.id duplicates another unit`);
    ids.add(unit.id);
    if (!unit.group || /[',:]/.test(String(unit.group))) problems.push(`${label}.group name contains ', comma or colon`);
    if (unit.parent && !/^[a-z0-9][a-z0-9-]*$/.test(String(unit.parent))) problems.push(`${label}.parent is not a business-unit id`);
    if (typeof unit.monthlyUsdBudget !== 'number' || unit.monthlyUsdBudget < 0 || unit.monthlyUsdBudget > 100000000) problems.push(`${label}.monthlyUsdBudget is outside the monthly budget range`);
    if (!['Strict', 'Allowance', 'Notify'].includes(unit.mode)) problems.push(`${label}.mode is not Strict, Allowance or Notify`);
    if (unit.mode === 'Allowance' && (!Number.isInteger(unit.percent) || unit.percent < 1 || unit.percent > 100)) problems.push(`${label}.percent is required for Allowance and must be 1-100`);
    if (unit.mode !== 'Allowance' && unit.percent !== undefined) problems.push(`${label}.percent applies only with Allowance`);
  }

  for (const unit of units) {
    if (unit.parent && !ids.has(unit.parent)) problems.push(`${unit.id || 'unit'} parent ${unit.parent} is not defined`);
    const parent = units.find((candidate) => candidate.id === unit.parent);
    if (parent?.parent) problems.push(`${unit.id} is deeper than two levels`);
  }
  return problems;
}

function quotePowerShell(value) {
  return `'${String(value).replaceAll("'", "''")}'`;
}

function quoteBash(value) {
  return `'${String(value).replaceAll("'", "'\"'\"'")}'`;
}

function buildPortableCommands(schema, answersPath = './answers.json') {
  const psPath = answersPath.replaceAll('/', '\\');
  const bashPath = answersPath.replaceAll('\\', '/');
  const bashDoesNotApply = [];
  for (const [name, property] of Object.entries(schema.properties || {})) {
    if (Array.isArray(property['x-appliedBy']) && !property['x-appliedBy'].includes('install-claude-gateway.sh')) bashDoesNotApply.push(name);
  }
  return {
    powershell: `.\\Install-ClaudeGateway.ps1 -AnswersPath ${quotePowerShell(psPath)} -Preflight -Json`,
    powershellRun: `.\\Install-ClaudeGateway.ps1 -AnswersPath ${quotePowerShell(psPath)} -Yes -ProgressPath .\\install-progress.ndjson`,
    bash: `./install-claude-gateway.sh --answers-file ${quoteBash(bashPath)} --preflight --json`,
    bashRun: `./install-claude-gateway.sh --answers-file ${quoteBash(bashPath)} --yes --progress-file ./install-progress.ndjson`,
    bashDoesNotApply,
    cloudShell: 'Manage files > Upload answers.json, then paste the PowerShell or bash command above.',
  };
}
globalThis.ClaudeInstallerUiModel = { buildPortableCommands, coerceAnswerValue, collectAnswersFromEntries, fieldGroups, fieldsByCheckId, validateBusinessUnits };
})();
