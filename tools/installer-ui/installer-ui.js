(function(){
'use strict';
const { buildPortableCommands, collectAnswersFromEntries, fieldGroups, isFieldActive, validateAnswers, validateBusinessUnits, isPlainObject } = globalThis.ClaudeInstallerUiModel;

let schema;
let identity = {};
let lastFailedStep = '';
let businessUnits = [];
let csrfToken = '';
let sessionMode = 'live';
let sessionReason = '';
let activeRunId = '';
let activeStepId = '';
let lastRunSeq = 0;
let preflightFingerprint = '';
let preflightStale = true;
let validationProblems = [];
const deploymentChoices = new Set();
const maxRunOutputLines = 2000;
let runOutputLines = [];
let removedRunOutputLines = 0;

function byId(id) { return document.getElementById(id); }
function clearChildren(node) { while (node?.firstChild) node.removeChild(node.firstChild); }
function appendText(parent, text, tag = 'span', className = '') { const node = document.createElement(tag); node.textContent = text; if (className) node.className = className; parent.append(node); return node; }
function liveMode() { return location.protocol !== 'file:' && sessionMode === 'live'; }

async function postJson(path, body) {
  if (location.protocol === 'file:') throw new Error('Server mode is not running. Use the generated commands.');
  const res = await fetch(path, { method: 'POST', headers: { 'content-type': 'application/json', 'x-csrf-token': csrfToken }, body: JSON.stringify(body) });
  const text = await res.text();
  let data;
  try { data = JSON.parse(text); } catch { data = { text }; }
  if (!res.ok) { const error = new Error(data.error || text); error.data = data; throw error; }
  return data;
}

async function loadSchema() {
  const carried = byId('schema-json')?.textContent?.trim();
  if (carried) return JSON.parse(carried);
  return (await fetch('./api/schema')).json();
}

function createErrorNode(id) {
  const node = document.createElement('div');
  node.id = id;
  node.className = 'field-error';
  node.setAttribute('role', 'alert');
  return node;
}

function labelFor(name, property) {
  const label = document.createElement('label');
  label.dataset.answer = name;
  appendText(label, property.title || name);
  return label;
}

function renderField(parent, name, property) {
  const label = labelFor(name, property);
  let field;
  if (property.enum || property.type === 'boolean') {
    field = document.createElement('select');
    const unset = document.createElement('option');
    unset.value = '';
    unset.textContent = 'not set (the installer default)';
    field.append(unset);
    const values = property.type === 'boolean' ? ['true', 'false'] : property.enum;
    for (const item of values) { const option = document.createElement('option'); option.value = item; option.textContent = item; field.append(option); }
  } else {
    field = document.createElement('input');
    field.type = property.type === 'integer' || property.type === 'number' ? 'text' : 'text';
    if (property.type === 'integer' || property.type === 'number') field.inputMode = 'numeric';
  }
  field.name = name;
  field.id = `field-${name.replace(/[^A-Za-z0-9_-]/g, '-')}`;
  field.setAttribute('aria-describedby', `${field.id}-error`);
  label.append(field);
  if (property['x-remedy']) appendText(label, property['x-remedy'], 'span', 'small');
  label.append(createErrorNode(`${field.id}-error`));
  parent.append(label);
  if (name === 'SubscriptionId') renderPrefillControl(label, 'subscriptions', name, 'Read subscriptions');
  if (name === 'FoundryAccount') renderPrefillControl(label, 'foundryAccounts', name, 'Read Foundry accounts');
}

function renderPrefillControl(label, kind, name, text) {
  const button = document.createElement('button');
  button.type = 'button';
  button.dataset.prefillKind = kind;
  button.textContent = text;
  const select = document.createElement('select');
  select.dataset.prefillSelect = name;
  select.hidden = true;
  label.append(button, select);
}

function renderModelList(parent, name, property) {
  const label = labelFor(name, property);
  const select = document.createElement('select');
  select.multiple = true;
  select.dataset.modelSelect = name;
  select.setAttribute('aria-describedby', `field-${name}-error`);
  const input = document.createElement('input');
  input.name = name;
  input.id = `field-${name}`;
  input.placeholder = 'deployment names, comma-separated';
  input.setAttribute('aria-describedby', `field-${name}-error`);
  label.append(select, input, createErrorNode(`field-${name}-error`));
  parent.append(label);
}

function renderPendingDeployment(parent, property) {
  const fieldset = document.createElement('fieldset');
  fieldset.dataset.answer = 'PendingClaudeDeployment';
  appendText(fieldset, property.title || 'Claude deployment to create', 'legend');
  const enableLabel = document.createElement('label');
  const enable = document.createElement('input');
  enable.type = 'checkbox';
  enable.id = 'pending-deployment-enabled';
  enableLabel.append(enable); appendText(enableLabel, ' Create a deployment during install');
  fieldset.append(enableLabel);
  const fields = document.createElement('div');
  fields.id = 'pending-deployment-fields';
  fields.hidden = true;
  for (const [field, node] of Object.entries(schema.$defs.PendingClaudeDeployment.properties)) renderNestedField(fields, `PendingClaudeDeployment.${field}`, node);
  enable.addEventListener('change', () => { fields.hidden = !enable.checked; markPreflightStale(); validateCurrentAnswers(); });
  fieldset.append(fields);
  parent.append(fieldset);
}

function renderNestedField(parent, name, node) {
  const property = node.$ref ? { ...schema.$defs[node.$ref.replace(/^#\/\$defs\//, '')], ...node } : node;
  const label = labelFor(name, property);
  const input = document.createElement('input');
  input.name = name;
  input.id = `field-${name.replace(/[^A-Za-z0-9_-]/g, '-')}`;
  input.type = 'text';
  label.append(input, createErrorNode(`${input.id}-error`));
  parent.append(label);
}

function renderGroupedFields() {
  for (const group of Object.values(fieldGroups)) {
    const parent = byId(group.target);
    for (const name of group.fields) {
      if (name === 'BusinessUnits') continue;
      const property = schema.properties[name];
      if (!property) continue;
      if (name === 'StandardModels' || name === 'PremiumModels') renderModelList(parent, name, property);
      else if (name === 'PendingClaudeDeployment') renderPendingDeployment(parent, property);
      else renderField(parent, name, property);
    }
  }
}

function currentEntryMap() {
  const entries = new Map();
  for (const field of document.querySelectorAll('[name]')) {
    const root = field.closest('label, fieldset');
    if (root?.hidden || field.closest('[hidden]')) continue;
    entries.set(field.name, field.value);
  }
  return entries;
}

function collectAnswers() {
  syncBusinessUnitsFromEditor();
  return collectAnswersFromEntries(schema, currentEntryMap(), byId('business-units').value);
}

function refreshConditionalVisibility() {
  const entries = currentEntryMap();
  for (const node of document.querySelectorAll('[data-answer]')) {
    const name = node.dataset.answer;
    if (!schema.properties[name] || name === 'PendingClaudeDeployment') continue;
    const active = isFieldActive(schema, name, entries);
    if (node.hidden !== !active) node.hidden = !active;
  }
  const addressMode = document.querySelector('[name="AddressMode"]')?.value || '';
  if (addressMode !== 'custom') {
    for (const node of document.querySelectorAll('[data-answer^="Address"]')) {
      if (node.dataset.answer !== 'AddressMode') node.hidden = true;
    }
  }
}

function validateCurrentAnswers() {
  let answers;
  try { answers = collectAnswers(); }
  catch (error) { validationProblems = [{ checkId: 'answers.schema', path: 'BusinessUnits', message: error.message, remedy: 'Correct the JSON view.' }]; renderValidationProblems(); return validationProblems; }
  validationProblems = validateAnswers(schema, answers, 'Install-ClaudeGateway.ps1');
  renderValidationProblems();
  return validationProblems;
}

function renderValidationProblems() {
  for (const field of document.querySelectorAll('[aria-invalid]')) field.removeAttribute('aria-invalid');
  for (const node of document.querySelectorAll('.field-error')) node.textContent = '';
  const errors = byId('errors');
  clearChildren(errors);
  if (validationProblems.length) {
    const list = document.createElement('ul');
    for (const p of validationProblems) {
      appendText(list, `${p.path || 'answers'}: ${p.message} ${p.remedy || ''}`.trim(), 'li');
      const rootName = String(p.path || '').split(/[.\[]/)[0];
      const field = rootName === 'BusinessUnits' ? byId('business-units') : document.querySelector(`[name="${CSS.escape(rootName)}"], [name^="${CSS.escape(rootName)}."]`);
      if (field) {
        field.setAttribute('aria-invalid', 'true');
        const described = field.getAttribute('aria-describedby');
        const err = described ? byId(described.split(/\s+/)[0]) : null;
        if (err) err.textContent = `${p.message} ${p.remedy || ''}`.trim();
      }
    }
    errors.append(list);
  }
  refreshCommands();
  updateRunAdmission();
  return validationProblems;
}

function markPreflightStale() {
  preflightStale = true;
  preflightFingerprint = '';
  refreshConditionalVisibility();
  validateCurrentAnswers();
}

function hasBlockingProblems() { return validationProblems.length > 0; }
function updateRunAdmission() {
  const admitted = liveMode() && preflightFingerprint && !preflightStale && !hasBlockingProblems();
  for (const id of ['run', 'full-run', 'rerun']) { const button = byId(id); if (button) button.disabled = id === 'rerun' ? (!lastFailedStep || !admitted) : !admitted; }
  for (const id of ['preflight', 'download']) { const button = byId(id); if (button) button.disabled = hasBlockingProblems(); }
  const state = byId('preflight-state');
  if (!state) return;
  if (hasBlockingProblems()) state.textContent = `${preflightStale ? 'Preflight is stale. ' : ''}Validation problems block download, preflight, run and command copying.`;
  else if (!liveMode()) state.textContent = `Static fallback: ${sessionReason || 'use the generated commands.'}`;
  else if (admitted) state.textContent = `Passing preflight ${preflightFingerprint.slice(0, 12)} is current.`;
  else if (preflightStale) state.textContent = 'Preflight is stale. Run preflight after changing answers or steps.';
  else state.textContent = 'No passing preflight yet.';
}

function renderCommands(commands) {
  const root = byId('commands'); clearChildren(root);
  if (hasBlockingProblems()) { appendText(root, 'Commands are unavailable until validation problems are fixed.', 'p', 'failed'); return; }
  for (const [title, value] of [['PowerShell preflight', commands.powershell], ['PowerShell run', commands.powershellRun]]) { appendText(root, title, 'h3'); appendText(root, value, 'pre'); }
  appendText(root, 'PowerShell applies every current answer and selected step.', 'p');
  if (commands.bash && commands.bashRun) { for (const [title, value] of [['Bash preflight', commands.bash], ['Bash run', commands.bashRun]]) { appendText(root, title, 'h3'); appendText(root, value, 'pre'); } return; }
  appendText(root, 'Bash commands are not shown because bash does not apply the following current inputs.', 'p');
  const ul = document.createElement('ul');
  for (const item of commands.bashDoesNotApply || []) appendText(ul, `answer ${item}`, 'li');
  for (const item of commands.bashStepsNotApply || []) appendText(ul, `step ${item}`, 'li');
  root.append(ul);
}

function refreshCommands() {
  if (!schema) return;
  let answers = { schemaVersion: 1 };
  try { answers = collectAnswers(); } catch { }
  renderCommands(buildPortableCommands(schema, './answers.json', { progressPath: './install-progress.ndjson', steps: selectedSteps(), fullRun: !selectedSteps().length, presentAnswers: Object.keys(answers).filter((key) => key !== 'schemaVersion') }));
}

function markFields(checks) {
  for (const check of checks) {
    if (check.result === 'PASS') continue;
    for (const problem of check.problems || []) {
      const p = { path: problem.path || '', message: problem.message || check.message || '', remedy: problem.remedy || check.remedy || '' };
      const rootName = String(p.path).split(/[.\[]/)[0];
      const field = rootName === 'BusinessUnits' ? byId('business-units') : document.querySelector(`[name="${CSS.escape(rootName)}"]`);
      field?.setAttribute('aria-invalid', 'true');
    }
  }
}

function renderPreflight(result) {
  const container = byId('preflight-output'); clearChildren(container);
  const checks = result.preflight?.checks || result.preflight || [];
  const table = document.createElement('table'); const header = document.createElement('tr');
  for (const text of ['Check', 'Result', 'Message', 'Remedy']) appendText(header, text, 'th'); table.append(header);
  for (const check of checks) { const row = document.createElement('tr'); appendText(row, check.id || '', 'td'); appendText(row, check.result || '', 'td', check.result === 'PASS' ? 'passed' : 'failed'); appendText(row, check.message || '', 'td'); appendText(row, check.remedy || '', 'td'); table.append(row); }
  container.append(table); markFields(checks);
  if (result.preflight?.result === 'PASS' && result.fingerprint) { preflightFingerprint = result.fingerprint; preflightStale = false; } else { preflightFingerprint = ''; preflightStale = false; }
  updateRunAdmission();
}
function showPreflightError(error) { const container = byId('preflight-output'); clearChildren(container); appendText(container, error.message || String(error), 'p', 'failed'); }

function renderSteps(payload) {
  const parent = byId('step-list'); clearChildren(parent);
  const steps = Array.isArray(payload) ? payload : payload.steps || [];
  for (const step of steps) { const label = document.createElement('label'); const input = document.createElement('input'); input.type = 'checkbox'; input.value = step.id; input.addEventListener('change', markPreflightStale); label.append(input); appendText(label, ` ${step.id} - ${step.title || ''}`); parent.append(label); }
}
function selectedSteps() { return [...document.querySelectorAll('#step-list input:checked')].map((input) => input.value); }
function defaultBusinessUnit(parent = '') { return { id: '', group: '', parent, monthlyUsdBudget: 0, mode: 'Strict' }; }
function orderedBusinessUnits() { return [...businessUnits.filter((u) => !u.parent), ...businessUnits.filter((u) => u.parent)]; }

function syncBusinessUnitsFromEditor() {
  businessUnits = [...document.querySelectorAll('[data-bu-index]')].map((row) => {
    const unit = { id: row.querySelector('[data-bu-field="id"]').value.trim(), group: row.querySelector('[data-bu-field="group"]').value.trim(), monthlyUsdBudget: Number(row.querySelector('[data-bu-field="monthlyUsdBudget"]').value), mode: row.querySelector('[data-bu-field="mode"]').value };
    const parent = row.dataset.parent || ''; if (parent) unit.parent = parent;
    if (unit.mode === 'Allowance') unit.percent = Number(row.querySelector('[data-bu-field="percent"]').value);
    return unit;
  });
  businessUnits = orderedBusinessUnits();
  byId('business-units').value = businessUnits.length ? JSON.stringify(businessUnits, null, 2) : '';
  renderBusinessUnitValidation();
}
function renderBusinessUnitValidation() { const problems = validateBusinessUnits(businessUnits); byId('business-unit-problems').textContent = problems.join('\n'); return problems; }
function refreshTeamParentOptions() { const parentSelect = byId('team-parent'); const current = parentSelect.value; clearChildren(parentSelect); for (const unit of businessUnits.filter((u) => !u.parent && u.id)) { const option = document.createElement('option'); option.value = unit.id; option.textContent = unit.id; option.selected = unit.id === current; parentSelect.append(option); } }
function businessUnitField(row, label, field, value, type = 'text') { const wrapper = document.createElement('label'); appendText(wrapper, label); const input = document.createElement('input'); input.dataset.buField = field; input.type = type === 'number' ? 'text' : type; input.value = value ?? ''; wrapper.append(input); row.append(wrapper); return input; }
function renderBusinessUnitEditor() {
  const tree = byId('business-unit-tree'); clearChildren(tree); businessUnits = orderedBusinessUnits(); refreshTeamParentOptions();
  businessUnits.forEach((unit, index) => {
    const row = document.createElement('fieldset'); row.dataset.buIndex = String(index); row.dataset.parent = unit.parent || ''; appendText(row, unit.parent ? `Team under ${unit.parent}` : 'Business unit', 'legend');
    businessUnitField(row, 'Id', 'id', unit.id); businessUnitField(row, 'Entra group', 'group', unit.group); businessUnitField(row, 'Monthly USD budget', 'monthlyUsdBudget', unit.monthlyUsdBudget, 'number');
    const modeLabel = document.createElement('label'); appendText(modeLabel, 'Mode'); const mode = document.createElement('select'); mode.dataset.buField = 'mode';
    for (const value of ['Strict', 'Allowance', 'Notify']) { const option = document.createElement('option'); option.value = value; option.textContent = value; option.selected = unit.mode === value; mode.append(option); }
    modeLabel.append(mode); row.append(modeLabel); const percent = businessUnitField(row, 'Allowance percent', 'percent', unit.percent ?? '', 'number'); percent.closest('label').hidden = unit.mode !== 'Allowance';
    mode.onchange = () => { percent.closest('label').hidden = mode.value !== 'Allowance'; syncBusinessUnitsFromEditor(); markPreflightStale(); };
    const remove = document.createElement('button'); remove.type = 'button'; remove.textContent = 'Remove'; remove.onclick = () => { businessUnits.splice(index, 1); renderBusinessUnitEditor(); syncBusinessUnitsFromEditor(); markPreflightStale(); };
    row.append(remove); row.oninput = () => { syncBusinessUnitsFromEditor(); validateCurrentAnswers(); }; tree.append(row);
  });
  byId('business-units').value = businessUnits.length ? JSON.stringify(businessUnits, null, 2) : ''; refreshTeamParentOptions(); renderBusinessUnitValidation();
}

async function streamRun(body) { if (hasBlockingProblems()) return; const res = await fetch('./api/run/stream', { method: 'POST', headers: { 'content-type': 'application/json', 'x-csrf-token': csrfToken }, body: JSON.stringify(body) }); if (!res.ok) throw new Error((await res.json()).error || 'run failed'); await readRunStream(res); }
function appendRunLine(text) { const output = byId('run-output'); runOutputLines.push(text); if (runOutputLines.length > maxRunOutputLines) { const removed = runOutputLines.length - maxRunOutputLines; runOutputLines.splice(0, removed); removedRunOutputLines += removed; } const shown = removedRunOutputLines ? [`Earlier run output lines were removed (${removedRunOutputLines}).`, ...runOutputLines] : runOutputLines; output.textContent = `${shown.join('\n')}\n`; }
async function readRunStream(res) {
  const output = byId('run-output'); if (!activeRunId) { output.textContent = ''; runOutputLines = []; removedRunOutputLines = 0; }
  const reader = res.body.getReader(); const decoder = new TextDecoder(); let buffer = '';
  for (;;) { const { value, done } = await reader.read(); if (done) break; buffer += decoder.decode(value, { stream: true }); const lines = buffer.split(/\r?\n/); buffer = lines.pop() || ''; for (const line of lines) { if (!line) continue; const event = JSON.parse(line); lastRunSeq = event.seq || lastRunSeq; if (event.type === 'progress' && event.event === 'started') activeStepId = event.stepId || activeStepId; appendRunLine(`${event.type}: ${event.stepId || ''} ${event.event || ''} ${event.line || event.message || ''}`); if (event.type === 'summary') { activeRunId = ''; activeStepId = ''; byId('stop-run').disabled = true; lastFailedStep = event.failedStepId || ''; updateRunAdmission(); if (event.resumeCommand) appendRunLine(`Resume: ${event.resumeCommand}`); } } }
}
async function refreshRunStatus() { if (location.protocol === 'file:') return; const status = await (await fetch('./api/run/status')).json(); if (status.id && status.state === 'running') { activeRunId = status.id; activeStepId = status.currentStepId || status.steps?.[0] || ''; byId('stop-run').disabled = false; const res = await fetch(`./api/run/attach?after=${lastRunSeq}`); await readRunStream(res); } }
async function refreshIdentity() { if (!liveMode()) { identity = { signedIn: false, signInCommand: 'az login --use-device-code' }; byId('identity').textContent = `Static fallback: ${sessionReason || 'Azure reads and installer runs need the generated commands.'}`; return; } identity = await (await fetch('./api/identity')).json(); const target = byId('identity'); target.textContent = identity.signedIn ? `Signed-in account: ${identity.user}; tenant ${identity.tenantId}; subscription ${identity.subscriptionName} (${identity.subscriptionId}).` : `Signed-in account: not signed in. ${identity.signInCommand || 'Run az login --use-device-code.'}`; }

async function loadPrefill(kind) {
  const body = { kind };
  if (kind === 'foundryAccounts' || kind === 'deployments') body.subscriptionId = document.querySelector('[name="SubscriptionId"]')?.value || '';
  if (kind === 'deployments') {
    body.foundryAccount = document.querySelector('[name="FoundryAccount"]')?.value || '';
    body.foundryResourceGroup = document.querySelector('[name="FoundryResourceGroup"]')?.value || '';
  }
  const result = await postJson('./api/prefill', body);
  if (result.field || result.error) {
    const error = new Error(result.error || 'Prefill failed');
    error.data = { field: result.field || (kind === 'subscriptions' ? 'SubscriptionId' : 'FoundryAccount'), error: result.error || 'Prefill failed', remedy: result.remedy || 'Type the value manually.' };
    throw error;
  }
  return result;
}
function showFieldError(field, message, remedy) { const input = document.querySelector(`[name="${CSS.escape(field)}"]`); input?.setAttribute('aria-invalid', 'true'); const err = input ? byId((input.getAttribute('aria-describedby') || '').split(/\s+/)[0]) : null; if (err) err.textContent = `${message} ${remedy || ''}`.trim(); }
function showPrefillError(error, fallbackField) {
  const data = error?.data || {};
  showFieldError(data.field || fallbackField, data.error || error.message || 'Prefill failed', data.remedy || 'Type the value manually.');
}
function fillPrefillSelect(select, items, valueKey, label) { clearChildren(select); const empty = document.createElement('option'); empty.value = ''; empty.textContent = 'choose…'; select.append(empty); for (const item of items) { const option = document.createElement('option'); option.value = item[valueKey]; option.textContent = label(item); option.dataset.item = JSON.stringify(item); select.append(option); } select.hidden = false; }
async function handlePrefillClick(event) {
  const button = event.target.closest('[data-prefill-kind]'); if (!button || !liveMode()) return;
  const kind = button.dataset.prefillKind; const field = button.closest('label')?.querySelector('[name]'); const select = button.closest('label')?.querySelector('[data-prefill-select]');
  try {
    const data = await loadPrefill(kind);
    if (kind === 'subscriptions') fillPrefillSelect(select, data.subscriptions || [], 'id', (item) => `${item.name} (${item.id})`);
    if (kind === 'foundryAccounts') fillPrefillSelect(select, data.foundryAccounts || [], 'name', (item) => `${item.name} / ${item.resourceGroup}`);
    field?.focus();
  } catch (error) { showPrefillError(error, field?.name || 'SubscriptionId'); }
}
async function handlePrefillChoice(event) {
  const select = event.target.closest('[data-prefill-select]'); if (!select || !select.value) return;
  const item = JSON.parse(select.selectedOptions[0].dataset.item || '{}');
  try {
    if (select.dataset.prefillSelect === 'SubscriptionId') { document.querySelector('[name="SubscriptionId"]').value = item.id || ''; markPreflightStale(); const data = await loadPrefill('foundryAccounts'); const accountSelect = document.querySelector('[data-prefill-select="FoundryAccount"]'); fillPrefillSelect(accountSelect, data.foundryAccounts || [], 'name', (x) => `${x.name} / ${x.resourceGroup}`); }
    if (select.dataset.prefillSelect === 'FoundryAccount') { document.querySelector('[name="FoundryAccount"]').value = item.name || ''; document.querySelector('[name="FoundryResourceGroup"]').value = item.resourceGroup || ''; markPreflightStale(); const data = await loadPrefill('deployments'); updateDeploymentChoices(data.deployments || []); }
  } catch (error) {
    showPrefillError(error, select.dataset.prefillSelect || 'SubscriptionId');
  }
}
function updateDeploymentChoices(deployments) { for (const item of deployments) deploymentChoices.add(item.name); for (const select of document.querySelectorAll('[data-model-select]')) { const chosen = new Set([...select.selectedOptions].map((o) => o.value)); clearChildren(select); for (const name of deploymentChoices) { const option = document.createElement('option'); option.value = name; option.textContent = name; option.selected = chosen.has(name); select.append(option); } } }
function syncModelInput(event) { const select = event.target.closest('[data-model-select]'); if (!select) return; const input = select.closest('label').querySelector('input[name]'); const selected = [...select.selectedOptions].map((o) => o.value); const manual = input.value.split(',').map((x) => x.trim()).filter((x) => x && !deploymentChoices.has(x)); input.value = [...selected, ...manual].join(', '); markPreflightStale(); }

async function main() {
  schema = await loadSchema();
  globalThis.ClaudeInstallerUiCollectAnswers = collectAnswers;
  globalThis.ClaudeInstallerUiValidateAnswers = validateCurrentAnswers;
  if (location.protocol !== 'file:') { const session = await (await fetch('./api/session')).json(); csrfToken = session.csrfToken; sessionMode = session.mode || 'live'; sessionReason = session.reason || ''; } else sessionMode = 'static';
  renderGroupedFields();
  byId('refresh-identity').onclick = () => refreshIdentity(); byId('signin').onclick = () => { byId('signin-command').textContent = identity.signInCommand || 'az login --use-device-code'; };
  document.addEventListener('click', handlePrefillClick); document.addEventListener('change', handlePrefillChoice); document.addEventListener('change', syncModelInput);
  document.addEventListener('input', (event) => { if (event.target?.id === 'business-units') { preflightStale = true; preflightFingerprint = ''; updateRunAdmission(); return; } if (event.target?.closest('#business-unit-tree') || event.target?.matches('[name], #business-units')) markPreflightStale(); });
  document.addEventListener('change', (event) => { if (event.target?.matches('[name], #step-list input')) markPreflightStale(); });
  byId('preflight').onclick = async () => { try { if (validateCurrentAnswers().length) return; const steps = selectedSteps(); renderPreflight(await postJson('./api/preflight', { answers: collectAnswers(), ...(steps.length ? { steps } : { fullRun: true }) })); } catch (error) { showPreflightError(error); } };
  byId('steps').onclick = async () => renderSteps(await (await fetch('./api/steps')).json());
  byId('run').onclick = async () => { const steps = selectedSteps(); if (!steps.length) throw new Error('Select at least one step, or use Full run.'); activeRunId = ''; byId('stop-run').disabled = false; await streamRun({ answers: collectAnswers(), steps, fingerprint: preflightFingerprint }); };
  byId('full-run').onclick = async () => { const answers = collectAnswers(); const resourceGroup = answers.ResourceGroup || '(not set)'; if (!globalThis.confirm(`Run the full installer as ${identity.user || 'the current account'} against resource group ${resourceGroup}?`)) return; activeRunId = ''; byId('stop-run').disabled = false; await streamRun({ answers, steps: [], fullRun: true, confirmFullRun: true, account: identity, fingerprint: preflightFingerprint }); };
  byId('rerun').onclick = async () => { if (lastFailedStep) await streamRun({ answers: collectAnswers(), steps: [lastFailedStep], fingerprint: preflightFingerprint }); };
  byId('stop-run').onclick = async () => { const status = await (await fetch('./api/run/status')).json(); const runId = status.id || activeRunId; const step = status.currentStepId || activeStepId || 'the current step'; if (!runId || !globalThis.confirm(`Stop run at ${step}? Running the same steps again resumes from the install checkpoint.`)) return; const result = await postJson('./api/run/stop', { runId }); appendRunLine(`stopped: ${result.message}`); };
  byId('download').onclick = () => { if (validateCurrentAnswers().length) return; const blob = new Blob([JSON.stringify(collectAnswers(), null, 2) + '\n'], { type: 'application/json' }); const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = 'answers.json'; a.click(); URL.revokeObjectURL(a.href); };
  byId('add-unit').onclick = () => { syncBusinessUnitsFromEditor(); businessUnits.push(defaultBusinessUnit()); renderBusinessUnitEditor(); markPreflightStale(); };
  byId('add-team').onclick = () => { syncBusinessUnitsFromEditor(); refreshTeamParentOptions(); const parent = byId('team-parent').value; if (!parent) { byId('business-unit-problems').textContent = 'Give a business unit an id before adding a team.'; return; } businessUnits.push(defaultBusinessUnit(parent)); renderBusinessUnitEditor(); markPreflightStale(); };
  byId('business-units').addEventListener('input', () => { const text = byId('business-units').value.trim(); let candidate; try { candidate = text ? JSON.parse(text) : []; } catch (error) { byId('business-unit-problems').textContent = `JSON parse error: ${error.message}`; return; } if (!Array.isArray(candidate) || candidate.some((item) => !isPlainObject(item))) { byId('business-unit-problems').textContent = 'BusinessUnits JSON must be an array of objects.'; return; } businessUnits = candidate; renderBusinessUnitEditor(); markPreflightStale(); });
  renderBusinessUnitEditor(); refreshConditionalVisibility(); validateCurrentAnswers(); updateRunAdmission();
  if (!liveMode()) { for (const id of ['preflight', 'steps', 'run', 'full-run', 'rerun', 'stop-run', 'refresh-identity', 'signin']) byId(id).hidden = true; for (const node of document.querySelectorAll('[data-prefill-kind], [data-prefill-select]')) node.hidden = true; }
  refreshCommands(); void refreshIdentity().catch((error) => { byId('identity').textContent = error.message; }); void refreshRunStatus().catch(() => {});
}

main().catch((error) => { byId('errors').textContent = error.message; });
})();
