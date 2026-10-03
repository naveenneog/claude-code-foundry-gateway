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

let schema;
let identity = {};
let lastFailedStep = '';
let businessUnits = [];

function byId(id) {
  return document.getElementById(id);
}

function appendText(parent, text, tag = 'span', className = '') {
  const node = document.createElement(tag);
  node.textContent = text;
  if (className) node.className = className;
  parent.append(node);
  return node;
}

async function postJson(path, body) {
  if (location.protocol === 'file:') throw new Error('Server mode is not running. Use the generated commands.');
  const res = await fetch(path, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
  const text = await res.text();
  let data;
  try { data = JSON.parse(text); } catch { data = { text }; }
  if (!res.ok) throw new Error(data.error || text);
  return data;
}

async function loadSchema() {
  const carried = byId('schema-json')?.textContent?.trim();
  if (carried) return JSON.parse(carried);
  return (await fetch('./api/schema')).json();
}

function renderField(parent, name, property) {
  const label = document.createElement('label');
  label.dataset.answer = name;
  appendText(label, property.title || name);
  let field;
  if (property.enum || property.type === 'boolean') {
    field = document.createElement('select');
    const unset = document.createElement('option');
    unset.value = '';
    unset.textContent = 'not set (the installer default)';
    field.append(unset);
    const values = property.type === 'boolean' ? ['true', 'false'] : property.enum;
    for (const item of values) {
      const option = document.createElement('option');
      option.value = item;
      option.textContent = item;
      field.append(option);
    }
  } else {
    field = document.createElement('input');
    field.type = property.type === 'integer' || property.type === 'number' ? 'number' : 'text';
  }
  field.name = name;
  if (property.pattern) field.pattern = property.pattern;
  label.append(field);
  if (property['x-remedy']) appendText(label, property['x-remedy'], 'span', 'small');
  parent.append(label);
}

function collectAnswers() {
  const entries = new Map();
  for (const field of document.querySelectorAll('[name]')) entries.set(field.name, field.value);
  syncBusinessUnitsFromEditor();
  return collectAnswersFromEntries(schema, entries, byId('business-units').value);
}

function renderCommands(commands) {
  const root = byId('commands');
  clearChildren(root);
  for (const [title, value] of [['PowerShell preflight', commands.powershell], ['PowerShell run', commands.powershellRun], ['Bash preflight', commands.bash], ['Bash run', commands.bashRun]]) {
    appendText(root, title, 'h3');
    appendText(root, value, 'pre');
  }
  appendText(root, 'Answers the bash installer does not apply', 'h3');
  const ul = document.createElement('ul');
  for (const item of commands.bashDoesNotApply || []) appendText(ul, item, 'li');
  root.append(ul);
}

function clearChildren(node) {
  while (node.firstChild) node.removeChild(node.firstChild);
}

function markFields(checks, map) {
  for (const node of document.querySelectorAll('.problem')) node.classList.remove('problem');
  for (const check of checks) {
    if (check.result === 'PASS') continue;
    for (const field of map[check.id] || []) {
      const root = field.startsWith('BusinessUnits.') ? byId('business-units') : document.querySelector(`[name="${CSS.escape(field)}"]`);
      root?.closest('label')?.classList.add('problem');
      if (root?.id === 'business-units') root.classList.add('problem');
    }
  }
}

function renderPreflight(result) {
  const container = byId('preflight-output');
  clearChildren(container);
  const checks = result.preflight?.checks || result.preflight || [];
  const table = document.createElement('table');
  const header = document.createElement('tr');
  for (const text of ['Check', 'Result', 'Message', 'Remedy']) appendText(header, text, 'th');
  table.append(header);
  for (const check of checks) {
    const row = document.createElement('tr');
    appendText(row, check.id || '', 'td');
    appendText(row, check.result || '', 'td', check.result === 'PASS' ? 'passed' : 'failed');
    appendText(row, check.message || '', 'td');
    appendText(row, check.remedy || '', 'td');
    table.append(row);
  }
  container.append(table);
  markFields(checks, result.fieldsByCheckId || fieldsByCheckId(schema));
}

function renderSteps(payload) {
  const parent = byId('step-list');
  clearChildren(parent);
  const steps = Array.isArray(payload) ? payload : payload.steps || [];
  for (const step of steps) {
    const label = document.createElement('label');
    const input = document.createElement('input');
    input.type = 'checkbox';
    input.value = step.id;
    label.append(input);
    appendText(label, ` ${step.id} - ${step.title || ''}`);
    parent.append(label);
  }
}

function selectedSteps() {
  return [...document.querySelectorAll('#step-list input:checked')].map((input) => input.value);
}

function defaultBusinessUnit(parent = '') {
  return { id: '', group: '', parent, monthlyUsdBudget: 0, mode: 'Strict' };
}

function orderedBusinessUnits() {
  return [...businessUnits.filter((u) => !u.parent), ...businessUnits.filter((u) => u.parent)];
}

function syncBusinessUnitsFromEditor() {
  businessUnits = [...document.querySelectorAll('[data-bu-index]')].map((row) => {
    const unit = {
      id: row.querySelector('[data-bu-field="id"]').value.trim(),
      group: row.querySelector('[data-bu-field="group"]').value.trim(),
      monthlyUsdBudget: Number(row.querySelector('[data-bu-field="monthlyUsdBudget"]').value),
      mode: row.querySelector('[data-bu-field="mode"]').value,
    };
    const parent = row.dataset.parent || '';
    if (parent) unit.parent = parent;
    if (unit.mode === 'Allowance') unit.percent = Number(row.querySelector('[data-bu-field="percent"]').value);
    return unit;
  });
  businessUnits = orderedBusinessUnits();
  byId('business-units').value = businessUnits.length ? JSON.stringify(businessUnits, null, 2) : '';
  renderBusinessUnitValidation();
}

function renderBusinessUnitValidation() {
  const problems = validateBusinessUnits(businessUnits);
  byId('business-unit-problems').textContent = problems.join('\n');
  return problems;
}

function businessUnitField(row, label, field, value, type = 'text') {
  const wrapper = document.createElement('label');
  appendText(wrapper, label);
  const input = document.createElement('input');
  input.dataset.buField = field;
  input.type = type;
  input.value = value ?? '';
  wrapper.append(input);
  row.append(wrapper);
  return input;
}

function renderBusinessUnitEditor() {
  const tree = byId('business-unit-tree');
  clearChildren(tree);
  const parentSelect = byId('team-parent');
  clearChildren(parentSelect);
  for (const unit of businessUnits.filter((u) => !u.parent)) {
    const option = document.createElement('option');
    option.value = unit.id;
    option.textContent = unit.id || '(unit without id)';
    parentSelect.append(option);
  }
  businessUnits = orderedBusinessUnits();
  businessUnits.forEach((unit, index) => {
    const row = document.createElement('fieldset');
    row.dataset.buIndex = String(index);
    row.dataset.parent = unit.parent || '';
    appendText(row, unit.parent ? `Team under ${unit.parent}` : 'Business unit', 'legend');
    businessUnitField(row, 'Id', 'id', unit.id);
    businessUnitField(row, 'Entra group', 'group', unit.group);
    businessUnitField(row, 'Monthly USD budget', 'monthlyUsdBudget', unit.monthlyUsdBudget, 'number');
    const modeLabel = document.createElement('label');
    appendText(modeLabel, 'Mode');
    const mode = document.createElement('select');
    mode.dataset.buField = 'mode';
    for (const value of ['Strict', 'Allowance', 'Notify']) {
      const option = document.createElement('option');
      option.value = value;
      option.textContent = value;
      option.selected = unit.mode === value;
      mode.append(option);
    }
    modeLabel.append(mode);
    row.append(modeLabel);
    const percent = businessUnitField(row, 'Allowance percent', 'percent', unit.percent ?? '', 'number');
    percent.closest('label').hidden = unit.mode !== 'Allowance';
    mode.onchange = () => { percent.closest('label').hidden = mode.value !== 'Allowance'; syncBusinessUnitsFromEditor(); };
    const remove = document.createElement('button');
    remove.type = 'button';
    remove.textContent = 'Remove';
    remove.onclick = () => { businessUnits.splice(index, 1); renderBusinessUnitEditor(); syncBusinessUnitsFromEditor(); };
    row.append(remove);
    row.oninput = () => syncBusinessUnitsFromEditor();
    tree.append(row);
  });
  byId('business-units').value = businessUnits.length ? JSON.stringify(businessUnits, null, 2) : '';
  renderBusinessUnitValidation();
}

async function streamRun(body) {
  const res = await fetch('./api/run/stream', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
  if (!res.ok) throw new Error((await res.json()).error || 'run failed');
  const output = byId('run-output');
  output.textContent = '';
  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buffer = '';
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    const lines = buffer.split(/\r?\n/);
    buffer = lines.pop() || '';
    for (const line of lines) {
      if (!line) continue;
      const event = JSON.parse(line);
      output.textContent += `${event.type}: ${event.stepId || ''} ${event.event || ''} ${event.line || event.message || ''}\n`;
      if (event.type === 'summary') {
        lastFailedStep = event.failedStepId || '';
        byId('rerun').disabled = !lastFailedStep;
        if (event.resumeCommand) output.textContent += `Resume: ${event.resumeCommand}\n`;
      }
    }
  }
}

async function refreshIdentity() {
  if (location.protocol === 'file:') {
    identity = { signedIn: false, signInCommand: 'az login --use-device-code' };
    byId('identity').textContent = 'Static fallback: Azure reads and installer runs need the generated commands.';
    return;
  }
  identity = await (await fetch('./api/identity')).json();
  const target = byId('identity');
  target.textContent = identity.signedIn
    ? `Signed-in account: ${identity.user}; tenant ${identity.tenantId}; subscription ${identity.subscriptionName} (${identity.subscriptionId}).`
    : `Signed-in account: not signed in. ${identity.signInCommand || 'Run az login --use-device-code.'}`;
}

async function main() {
  schema = await loadSchema();
  for (const [section, names] of Object.entries(fieldGroups)) {
    const parent = byId(section);
    for (const name of names) if (schema.properties[name]) renderField(parent, name, schema.properties[name]);
  }
  byId('refresh-identity').onclick = () => refreshIdentity();
  byId('signin').onclick = () => { byId('signin-command').textContent = identity.signInCommand || 'az login --use-device-code'; };
  byId('preflight').onclick = async () => renderPreflight(await postJson('./api/preflight', { answers: collectAnswers() }));
  byId('steps').onclick = async () => renderSteps(await (await fetch('./api/steps')).json());
  byId('plan').onclick = async () => { byId('plan-output').textContent = JSON.stringify(await postJson('./api/plan', { answers: collectAnswers() }), null, 2); };
  byId('run').onclick = async () => {
    const steps = selectedSteps();
    if (!steps.length) throw new Error('Select at least one step, or use Full run.');
    await streamRun({ answers: collectAnswers(), steps });
  };
  byId('full-run').onclick = async () => {
    const answers = collectAnswers();
    const resourceGroup = answers.ResourceGroup || '(not set)';
    if (!globalThis.confirm(`Run the full installer as ${identity.user || 'the current account'} against resource group ${resourceGroup}?`)) return;
    await streamRun({ answers, steps: [], fullRun: true, confirmFullRun: true, account: identity });
  };
  byId('rerun').onclick = async () => { if (lastFailedStep) await streamRun({ answers: collectAnswers(), steps: [lastFailedStep] }); };
  byId('download').onclick = () => {
    const blob = new Blob([JSON.stringify(collectAnswers(), null, 2) + '\n'], { type: 'application/json' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = 'answers.json';
    a.click();
    URL.revokeObjectURL(a.href);
  };
  byId('add-unit').onclick = () => { syncBusinessUnitsFromEditor(); businessUnits.push(defaultBusinessUnit()); renderBusinessUnitEditor(); };
  byId('add-team').onclick = () => { syncBusinessUnitsFromEditor(); const parent = byId('team-parent').value; if (parent) businessUnits.push(defaultBusinessUnit(parent)); renderBusinessUnitEditor(); };
  byId('business-units').addEventListener('input', () => {
    const text = byId('business-units').value.trim();
    businessUnits = text ? JSON.parse(text) : [];
    renderBusinessUnitEditor();
  });
  renderBusinessUnitEditor();
  try { renderCommands(await postJson('./api/commands', { answersPath: './answers.json' })); }
  catch { renderCommands(buildPortableCommands(schema, './answers.json')); }
  void refreshIdentity().catch((error) => { byId('identity').textContent = error.message; });
}

main().catch((error) => { byId('errors').textContent = error.message; });

})();
