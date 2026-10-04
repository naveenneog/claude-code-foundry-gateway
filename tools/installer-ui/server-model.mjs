import { readFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createContext, runInContext } from 'node:vm';

const here = dirname(fileURLToPath(import.meta.url));
export const root = resolve(here, '..', '..');
const schemaPath = join(root, 'schemas', 'claude-gateway.answers.schema.json');
const redactionPath = join(root, 'scripts', 'ClaudeInstallResume.ps1');
const uiModelPath = join(here, 'ui-model.js');
const prefillKinds = new Set(['subscriptions', 'foundryAccounts', 'deployments']);
const prefillParameters = [['-SubscriptionId', 'subscriptionId', 'SubscriptionId'], ['-FoundryAccount', 'foundryAccount', 'FoundryAccount'], ['-FoundryResourceGroup', 'foundryResourceGroup', 'FoundryResourceGroup']];
let redactionRules;
let uiModel;

export async function loadSchema() {
  return JSON.parse(await readFile(schemaPath, 'utf8'));
}

export async function loadRedactionRules() {
  if (redactionRules) return redactionRules;
  const source = await readFile(redactionPath, 'utf8');
  const match = source.match(/^\s*\$json = '(\[[^']*\])'/m);
  if (!match) throw new Error('redaction rules not found in scripts/ClaudeInstallResume.ps1');
  redactionRules = JSON.parse(match[1]).map((rule) => ({
    name: rule.name,
    regex: new RegExp(rule.pattern, 'gi'),
  }));
  return redactionRules;
}

export async function redactText(text) {
  let output = String(text ?? '');
  for (const rule of await loadRedactionRules()) {
    output = output.replace(rule.regex, (...args) => {
      const groups = args.at(-1);
      return `${groups?.keep ?? ''}[redacted]`;
    });
  }
  return output;
}

export function scrubLocalPaths(text) {
  let output = String(text ?? '');
  for (const [prefix, label] of [[root, '<checkout>'], [homedir(), '~']]) {
    if (!prefix) continue;
    const source = prefix.replace(/[\\/]+$/, '').replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace(/\\\\|\//g, '[\\\\/]');
    output = output.replace(new RegExp(source, 'gi'), () => label);
  }
  return output;
}

function requestProblem(field, message, remedy) {
  const error = new Error(message);
  error.status = 400;
  error.field = field;
  error.remedy = remedy;
  return error;
}

export function prefillArguments(body) {
  const kind = body.kind ?? 'subscriptions';
  if (typeof kind !== 'string' || !prefillKinds.has(kind)) {
    throw requestProblem('kind', 'kind is not subscriptions, foundryAccounts or deployments.', 'Ask for subscriptions, foundryAccounts or deployments.');
  }
  const args = [`-Kind:${kind}`];
  for (const [parameter, key, field] of prefillParameters) {
    const value = body[key];
    if (value === undefined || value === null || value === '') continue;
    if (typeof value !== 'string') throw requestProblem(field, `${field} is not text.`, `Give ${field} as text.`);
    args.push(`${parameter}:${value}`);
  }
  return args;
}

export async function loadUiModel() {
  if (uiModel) return uiModel;
  const context = createContext({ globalThis: {} });
  runInContext(await readFile(uiModelPath, 'utf8'), context);
  uiModel = context.globalThis.ClaudeInstallerUiModel;
  return uiModel;
}

export async function installerArguments(options) {
  return (await loadUiModel()).installerArguments(options);
}

export function fieldsByCheckId(schema) {
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
