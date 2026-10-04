(function(){
'use strict';
const { buildPortableCommands, collectAnswersFromEntries, fieldGroups, fieldsByCheckId, validateBusinessUnits } = globalThis.ClaudeInstallerUiModel;

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
const maxRunOutputLines = 2000;
let runOutputLines = [];
let removedRunOutputLines = 0;

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
  const res = await fetch(path, { method: 'POST', headers: { 'content-type': 'application/json', 'x-csrf-token': csrfToken }, body: JSON.stringify(body) });
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

function markPreflightStale() {
  preflightStale = true;
  preflightFingerprint = '';
  updateRunAdmission();
}

function updateRunAdmission() {
  const liveMode = location.protocol !== 'file:' && sessionMode === 'live';
  const admitted = liveMode && preflightFingerprint && !preflightStale;
  for (const id of ['run', 'full-run', 'rerun']) {
    const button = byId(id);
    if (button) button.disabled = id === 'rerun' ? (!lastFailedStep || !admitted) : !admitted;
  }
  const state = byId('preflight-state');
  if (!state) return;
  if (!liveMode) state.textContent = `Static fallback: ${sessionReason || 'use the generated commands.'}`;
  else if (admitted) state.textContent = `Passing preflight ${preflightFingerprint.slice(0, 12)} is current.`;
  else if (preflightStale) state.textContent = 'Preflight is stale. Run preflight after changing answers or steps.';
  else state.textContent = 'No passing preflight yet.';
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
  if (result.preflight?.result === 'PASS' && result.fingerprint) {
    preflightFingerprint = result.fingerprint;
    preflightStale = false;
  } else {
    preflightFingerprint = '';
    preflightStale = false;
  }
  updateRunAdmission();
}

function showPreflightError(error) {
  const container = byId('preflight-output');
  clearChildren(container);
  appendText(container, error.message || String(error), 'p', 'failed');
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
    input.addEventListener('change', markPreflightStale);
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

function refreshTeamParentOptions() {
  const parentSelect = byId('team-parent');
  const current = parentSelect.value;
  clearChildren(parentSelect);
  for (const unit of businessUnits.filter((u) => !u.parent && u.id)) {
    const option = document.createElement('option');
    option.value = unit.id;
    option.textContent = unit.id;
    option.selected = unit.id === current;
    parentSelect.append(option);
  }
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
  businessUnits = orderedBusinessUnits();
  refreshTeamParentOptions();
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
    mode.onchange = () => { percent.closest('label').hidden = mode.value !== 'Allowance'; syncBusinessUnitsFromEditor(); markPreflightStale(); };
    const remove = document.createElement('button');
    remove.type = 'button';
    remove.textContent = 'Remove';
    remove.onclick = () => { businessUnits.splice(index, 1); renderBusinessUnitEditor(); syncBusinessUnitsFromEditor(); markPreflightStale(); };
    row.append(remove);
    row.oninput = () => syncBusinessUnitsFromEditor();
    tree.append(row);
  });
  byId('business-units').value = businessUnits.length ? JSON.stringify(businessUnits, null, 2) : '';
  refreshTeamParentOptions();
  renderBusinessUnitValidation();
}

async function streamRun(body) {
  const res = await fetch('./api/run/stream', { method: 'POST', headers: { 'content-type': 'application/json', 'x-csrf-token': csrfToken }, body: JSON.stringify(body) });
  if (!res.ok) throw new Error((await res.json()).error || 'run failed');
  await readRunStream(res);
}

function appendRunLine(text) {
  const output = byId('run-output');
  runOutputLines.push(text);
  if (runOutputLines.length > maxRunOutputLines) {
    const removed = runOutputLines.length - maxRunOutputLines;
    runOutputLines.splice(0, removed);
    removedRunOutputLines += removed;
  }
  const shown = removedRunOutputLines ? [`Earlier run output lines were removed (${removedRunOutputLines}).`, ...runOutputLines] : runOutputLines;
  output.textContent = `${shown.join('\n')}\n`;
}

async function readRunStream(res) {
  const output = byId('run-output');
  if (!activeRunId) {
    output.textContent = '';
    runOutputLines = [];
    removedRunOutputLines = 0;
  }
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
      lastRunSeq = event.seq || lastRunSeq;
      if (event.type === 'progress' && event.event === 'started') activeStepId = event.stepId || activeStepId;
      appendRunLine(`${event.type}: ${event.stepId || ''} ${event.event || ''} ${event.line || event.message || ''}`);
      if (event.type === 'summary') {
        activeRunId = '';
        activeStepId = '';
        byId('stop-run').disabled = true;
        lastFailedStep = event.failedStepId || '';
        updateRunAdmission();
        if (event.resumeCommand) appendRunLine(`Resume: ${event.resumeCommand}`);
      }
    }
  }
}

async function refreshRunStatus() {
  if (location.protocol === 'file:') return;
  const status = await (await fetch('./api/run/status')).json();
  if (status.id && status.state === 'running') {
    activeRunId = status.id;
    activeStepId = status.currentStepId || status.steps?.[0] || '';
    byId('stop-run').disabled = false;
    const res = await fetch(`./api/run/attach?after=${lastRunSeq}`);
    await readRunStream(res);
  }
}

async function refreshIdentity() {
  if (location.protocol === 'file:' || sessionMode !== 'live') {
    identity = { signedIn: false, signInCommand: 'az login --use-device-code' };
    byId('identity').textContent = `Static fallback: ${sessionReason || 'Azure reads and installer runs need the generated commands.'}`;
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
  if (location.protocol !== 'file:') {
    const session = await (await fetch('./api/session')).json();
    csrfToken = session.csrfToken;
    sessionMode = session.mode || 'live';
    sessionReason = session.reason || '';
  } else {
    sessionMode = 'static';
  }
  for (const [section, names] of Object.entries(fieldGroups)) {
    const parent = byId(section);
    for (const name of names) if (schema.properties[name]) renderField(parent, name, schema.properties[name]);
  }
  byId('refresh-identity').onclick = () => refreshIdentity();
  byId('signin').onclick = () => { byId('signin-command').textContent = identity.signInCommand || 'az login --use-device-code'; };
  document.addEventListener('input', (event) => {
    if (event.target?.closest('#business-unit-tree') || event.target?.matches('[name], #business-units')) markPreflightStale();
  });
  document.addEventListener('change', (event) => {
    if (event.target?.matches('[name], #step-list input')) markPreflightStale();
  });
  byId('preflight').onclick = async () => {
    try {
      const steps = selectedSteps();
      renderPreflight(await postJson('./api/preflight', { answers: collectAnswers(), ...(steps.length ? { steps } : { fullRun: true }) }));
    }
    catch (error) { showPreflightError(error); }
  };
  byId('steps').onclick = async () => renderSteps(await (await fetch('./api/steps')).json());
  byId('run').onclick = async () => {
    const steps = selectedSteps();
    if (!steps.length) throw new Error('Select at least one step, or use Full run.');
    activeRunId = '';
    byId('stop-run').disabled = false;
    await streamRun({ answers: collectAnswers(), steps, fingerprint: preflightFingerprint });
  };
  byId('full-run').onclick = async () => {
    const answers = collectAnswers();
    const resourceGroup = answers.ResourceGroup || '(not set)';
    if (!globalThis.confirm(`Run the full installer as ${identity.user || 'the current account'} against resource group ${resourceGroup}?`)) return;
    activeRunId = '';
    byId('stop-run').disabled = false;
    await streamRun({ answers, steps: [], fullRun: true, confirmFullRun: true, account: identity, fingerprint: preflightFingerprint });
  };
  byId('rerun').onclick = async () => { if (lastFailedStep) await streamRun({ answers: collectAnswers(), steps: [lastFailedStep], fingerprint: preflightFingerprint }); };
  byId('stop-run').onclick = async () => {
    const status = await (await fetch('./api/run/status')).json();
    const runId = status.id || activeRunId;
    const step = status.currentStepId || activeStepId || 'the current step';
    if (!runId || !globalThis.confirm(`Stop run at ${step}? Running the same steps again resumes from the install checkpoint.`)) return;
    const result = await postJson('./api/run/stop', { runId });
    appendRunLine(`stopped: ${result.message}`);
  };
  byId('download').onclick = () => {
    const blob = new Blob([JSON.stringify(collectAnswers(), null, 2) + '\n'], { type: 'application/json' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = 'answers.json';
    a.click();
    URL.revokeObjectURL(a.href);
  };
  byId('add-unit').onclick = () => { syncBusinessUnitsFromEditor(); businessUnits.push(defaultBusinessUnit()); renderBusinessUnitEditor(); markPreflightStale(); };
  byId('add-team').onclick = () => {
    syncBusinessUnitsFromEditor();
    refreshTeamParentOptions();
    const parent = byId('team-parent').value;
    if (!parent) {
      byId('business-unit-problems').textContent = 'Give a business unit an id before adding a team.';
      return;
    }
    businessUnits.push(defaultBusinessUnit(parent));
    renderBusinessUnitEditor();
    markPreflightStale();
  };
  byId('business-units').addEventListener('input', () => {
    const text = byId('business-units').value.trim();
    try {
      businessUnits = text ? JSON.parse(text) : [];
    } catch (error) {
      byId('business-unit-problems').textContent = `JSON parse error: ${error.message}`;
      return;
    }
    renderBusinessUnitEditor();
    markPreflightStale();
  });
  renderBusinessUnitEditor();
  updateRunAdmission();
  if (sessionMode !== 'live') {
    for (const id of ['preflight', 'steps', 'run', 'full-run', 'rerun', 'stop-run', 'refresh-identity', 'signin']) byId(id).hidden = true;
  }
  try { renderCommands(await postJson('./api/commands', { answersPath: './answers.json' })); }
  catch { renderCommands(buildPortableCommands(schema, './answers.json')); }
  void refreshIdentity().catch((error) => { byId('identity').textContent = error.message; });
  void refreshRunStatus().catch(() => {});
}

main().catch((error) => { byId('errors').textContent = error.message; });

})();
