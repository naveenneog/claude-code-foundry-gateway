import { buildPortableCommands, collectAnswersFromEntries, fieldGroups, fieldsByCheckId, validateBusinessUnits } from './ui-model.mjs';

let schema;
let identity = {};
let lastFailedStep = '';

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
  return collectAnswersFromEntries(schema, entries, byId('business-units').value);
}

function renderCommands(commands) {
  byId('commands').textContent = JSON.stringify(commands, null, 2);
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
  byId('business-units').addEventListener('input', () => {
    const text = byId('business-units').value.trim();
    byId('business-unit-problems').textContent = text ? validateBusinessUnits(JSON.parse(text)).join('\n') : '';
  });
  try { renderCommands(await postJson('./api/commands', { answersPath: './answers.json' })); }
  catch { renderCommands(buildPortableCommands(schema, './answers.json')); }
  void refreshIdentity().catch((error) => { byId('identity').textContent = error.message; });
}

main().catch((error) => { byId('errors').textContent = error.message; });
