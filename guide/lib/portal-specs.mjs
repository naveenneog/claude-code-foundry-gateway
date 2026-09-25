// Pure schema and discovery planning. No Azure, browser, or filesystem writes.
import fs from 'node:fs';
import path from 'node:path';

export const DISCOVERY_TYPES = Object.freeze({
  gateway: 'Microsoft.ApiManagement/service',
  foundry: 'Microsoft.CognitiveServices/accounts',
  workspace: 'Microsoft.OperationalInsights/workspaces',
  'app-insights': 'Microsoft.Insights/components',
  vnet: 'Microsoft.Network/virtualNetworks',
  'key-vault': 'Microsoft.KeyVault/vaults',
  'private-dns': 'Microsoft.Network/privateDnsZones',
  workbook: 'Microsoft.Insights/workbooks',
});
const ENV = /^[A-Z][A-Z0-9_]{0,99}$/;
const ID = /^[a-z][a-z0-9-]{0,79}$/;
const RESOURCE_TYPE = /^Microsoft\.[A-Za-z]+\/[A-Za-z][A-Za-z0-9/]+$/;
const LITERAL_TARGET = /\/subscriptions\/|\/resourceGroups\/|https?:\/\/|[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}/i;
const BLOCKED_ACTION = /^(?:sign in|log in|login|enter password|next|continue|yes|approve|accept|consent|grant admin consent|save|delete|remove|create|deploy|start|run|execute|confirm)\b/i;
const object = (value) => value && typeof value === 'object' && !Array.isArray(value);
const text = (value) => typeof value === 'string' && value.trim().length > 0;

export function isBlockedAction(value) {
  return BLOCKED_ACTION.test(String(value).trim());
}

export function safeOutput(value) {
  return typeof value === 'string' && /^[A-Za-z0-9_./-]+\.png$/.test(value)
    && !value.startsWith('/') && !value.split('/').some((part) => part === '..' || part === '.')
    && !value.includes('//');
}

function unknownKeys(value, allowed, label, errors) {
  for (const key of Object.keys(value)) if (!allowed.includes(key)) errors.push(`${label}: unknown field ${key}`);
}

function locatorProblems(value, label, errors, allowActionOptions = false) {
  if (!object(value)) { errors.push(`${label}: expected an object`); return; }
  unknownKeys(value, allowActionOptions ? ['text', 'selector', 'exact', 'waitFor', 'settle'] : ['text', 'selector', 'exact'], label, errors);
  if (Number(text(value.text)) + Number(text(value.selector)) !== 1)
    errors.push(`${label}: exactly one non-empty text or selector is required`);
  if (value.text && (value.text.length > 300 || LITERAL_TARGET.test(value.text)))
    errors.push(`${label}: wait/click text must not embed deployment identifiers`);
  if (value.selector && (value.selector.length > 500 || LITERAL_TARGET.test(value.selector)))
    errors.push(`${label}: selector must not embed deployment identifiers`);
  if (value.exact !== undefined && typeof value.exact !== 'boolean') errors.push(`${label}: exact must be boolean`);
}

function settleProblems(value, label, errors) {
  if (value !== undefined && (!Number.isInteger(value) || value < 0 || value > 60_000))
    errors.push(`${label}: settle must be an integer from 0 to 60000 milliseconds`);
}

export function specProblems(document, file = 'spec') {
  const errors = [];
  if (!object(document)) return [`${file}: expected an object`];
  unknownKeys(document, ['version', 'steps'], file, errors);
  if (document.version !== 1) errors.push(`${file}: version must be 1`);
  if (!Array.isArray(document.steps) || !document.steps.length) return [...errors, `${file}: steps must be a non-empty array`];
  for (const [index, step] of document.steps.entries()) {
    const label = `${file} step ${index + 1}`;
    if (!object(step)) { errors.push(`${label}: expected an object`); continue; }
    unknownKeys(step, ['id', 'output', 'target', 'blade', 'entraBlade', 'waitFor', 'clicks', 'settle', 'redaction'], label, errors);
    if (!ID.test(step.id ?? '')) errors.push(`${label}: id must be a stable lower-case slug`);
    if (!safeOutput(step.output)) errors.push(`${label}: output must be a safe repository-relative PNG path`);
    const target = step.target;
    if (!object(target)) { errors.push(`${label}: target discovery is required`); continue; }
    unknownKeys(target, ['discover', 'resourceType', 'tags', 'nameFilterEnv', 'selectionKey'], `${label} target`, errors);
    const entra = ['entra-app', 'entra-group'].includes(target.discover);
    if (!(target.discover in DISCOVERY_TYPES) && !entra && target.discover !== 'resource')
      errors.push(`${label}: unknown discovery kind`);
    if (target.resourceType !== undefined && (!RESOURCE_TYPE.test(target.resourceType) || target.discover !== 'resource'))
      errors.push(`${label}: resourceType is supported only for generic resource discovery`);
    if (target.discover === 'resource' && (!RESOURCE_TYPE.test(target.resourceType ?? '') || (!target.tags && !target.nameFilterEnv)))
      errors.push(`${label}: generic resource requires resourceType plus tags or nameFilterEnv`);
    if (target.nameFilterEnv !== undefined && !ENV.test(target.nameFilterEnv)) errors.push(`${label}: nameFilterEnv must name an environment variable, not a resource`);
    if (entra && !target.nameFilterEnv) errors.push(`${label}: Entra discovery requires nameFilterEnv`);
    if (target.selectionKey !== undefined && !ID.test(target.selectionKey)) errors.push(`${label}: invalid selectionKey`);
    if (target.tags !== undefined) {
      if (!object(target.tags) || !Object.keys(target.tags).length) errors.push(`${label}: tags must be a non-empty object`);
      else for (const [key, value] of Object.entries(target.tags)) {
        if (!text(key) || !text(value) || key.length > 128 || value.length > 256 || LITERAL_TARGET.test(value))
          errors.push(`${label}: tag selector must be a logical tag, not a literal resource id or URL`);
      }
    }
    if (entra) {
      if (step.blade !== undefined) errors.push(`${label}: Entra steps use entraBlade, not an ARM blade path`);
      if (!object(step.entraBlade)) errors.push(`${label}: entraBlade is required`);
      else {
        unknownKeys(step.entraBlade, ['kind', 'name'], `${label} entraBlade`, errors);
        if (!['app-registration', 'enterprise-application', 'group'].includes(step.entraBlade.kind)
          || !/^[A-Za-z][A-Za-z0-9]{0,79}$/.test(step.entraBlade.name ?? ''))
          errors.push(`${label}: invalid Entra blade`);
        if ((target.discover === 'entra-group') !== (step.entraBlade.kind === 'group'))
          errors.push(`${label}: Entra target/blade kinds disagree`);
      }
    } else {
      if (step.entraBlade !== undefined) errors.push(`${label}: ARM resources cannot have entraBlade`);
      if (typeof step.blade !== 'string' || !/^\/[A-Za-z0-9/._-]*$/.test(step.blade) || step.blade.includes('..'))
        errors.push(`${label}: blade must be an appended path, never a URL or resource id`);
    }
    locatorProblems(step.waitFor, `${label} waitFor`, errors);
    settleProblems(step.settle, label, errors);
    if (step.clicks !== undefined) {
      if (!Array.isArray(step.clicks) || step.clicks.length > 12) errors.push(`${label}: clicks must contain at most 12 read-only navigation actions`);
      else step.clicks.forEach((click, clickIndex) => {
        const name = `${label} click ${clickIndex + 1}`;
        locatorProblems(click, name, errors, true);
        if (object(click)) {
          if (isBlockedAction(click.text)) errors.push(`${name}: authentication/commit actions are not allowed`);
          if (click.waitFor) locatorProblems(click.waitFor, `${name} waitFor`, errors);
          settleProblems(click.settle, name, errors);
        }
      });
    }
    if (!object(step.redaction)) errors.push(`${label}: redaction rules are required`);
    else {
      unknownKeys(step.redaction, ['mapEnv', 'hideSelectors'], `${label} redaction`, errors);
      if (!ENV.test(step.redaction.mapEnv ?? '')) errors.push(`${label}: redaction.mapEnv must name a private replacement-map variable`);
      if (step.redaction.hideSelectors !== undefined && (!Array.isArray(step.redaction.hideSelectors)
        || step.redaction.hideSelectors.some((selector) => !text(selector) || selector.length > 500 || LITERAL_TARGET.test(selector))))
        errors.push(`${label}: invalid hideSelectors`);
    }
  }
  return errors;
}

export const BUILTIN_STEPS = [
  { id: 'gateway-overview', output: 'docs/guide/a3-apim-overview.png', target: { discover: 'gateway', selectionKey: 'gateway' },
    blade: '/overview', waitFor: { text: 'Gateway URL' }, settle: 1500, redaction: { mapEnv: 'PORTAL_REDACTIONS_FILE' } },
  { id: 'gateway-identity', output: 'docs/guide/a4-identity.png', target: { discover: 'gateway', selectionKey: 'gateway' },
    blade: '/identity', waitFor: { text: 'System assigned' }, settle: 1500, redaction: { mapEnv: 'PORTAL_REDACTIONS_FILE' } },
  { id: 'gateway-named-values', output: 'docs/guide/a6-named-values.png', target: { discover: 'gateway', selectionKey: 'gateway' },
    blade: '/namedValues', waitFor: { text: 'Named values' }, settle: 1500, redaction: { mapEnv: 'PORTAL_REDACTIONS_FILE' } },
];

export function loadSteps(root, { builtins = BUILTIN_STEPS } = {}) {
  const directory = path.join(root, 'guide', 'captures');
  const steps = [...builtins.map((step) => ({ ...step, specFile: 'built-in' }))];
  const errors = specProblems({ version: 1, steps: builtins }, 'built-in');
  if (fs.existsSync(directory)) for (const file of fs.readdirSync(directory).filter((file) => file.endsWith('.json')).sort()) {
    let document;
    try { document = JSON.parse(fs.readFileSync(path.join(directory, file), 'utf8').replace(/^\uFEFF/, '')); }
    catch { errors.push(`${file}: invalid JSON`); continue; }
    errors.push(...specProblems(document, file));
    if (Array.isArray(document.steps)) steps.push(...document.steps.map((step) => ({ ...step, specFile: file })));
  }
  for (const property of ['id', 'output']) {
    const seen = new Set();
    for (const step of steps) {
      if (seen.has(step[property])) errors.push(`duplicate ${property}: ${step[property]}`);
      seen.add(step[property]);
    }
  }
  if (errors.length) throw new Error(errors.join('\n'));
  return steps;
}

export function selectSteps(steps, ids = []) {
  if (!ids.length) return steps;
  const unknown = ids.filter((id) => !steps.some((step) => step.id === id));
  if (unknown.length) throw new Error(`Unknown --only id(s): ${unknown.join(', ')}`);
  return steps.filter((step) => ids.includes(step.id));
}

export function documentationProblems(steps, references) {
  return steps.filter((step) => !references.has(step.output))
    .map((step) => `${step.id}: output is not referenced by a document: ${step.output}`);
}

export function documentedOutputs(root) {
  const docs = [];
  const walk = (directory) => {
    if (!fs.existsSync(directory)) return;
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const file = path.join(directory, entry.name);
      if (entry.isDirectory()) walk(file);
      else if (entry.name.endsWith('.md')) docs.push(file);
    }
  };
  walk(path.join(root, 'docs'));
  walk(path.join(root, 'guide'));
  docs.push(...fs.readdirSync(root).filter((file) => file.endsWith('.md')).map((file) => path.join(root, file)));
  const outputs = new Set();
  for (const file of docs) {
    const body = fs.readFileSync(file, 'utf8');
    for (const match of body.matchAll(/!?\[[^\]]*\]\(([^)]+\.png)\)/g)) {
      if (!/^https?:\/\//.test(match[1])) outputs.add(path.relative(root, path.resolve(path.dirname(file), match[1])).replaceAll('\\', '/'));
    }
    for (const match of body.matchAll(/`(docs\/[A-Za-z0-9_./-]+\.png)`/g)) outputs.add(match[1]);
  }
  return outputs;
}
