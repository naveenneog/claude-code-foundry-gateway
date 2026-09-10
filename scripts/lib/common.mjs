import { spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync, openSync, closeSync, fstatSync, fchmodSync, ftruncateSync, constants } from 'node:fs';
import { dirname } from 'node:path';

export const ARM = 'https://management.azure.com';
export const GRAPH = 'https://graph.microsoft.com';
export const INSIGHTS = 'https://api.applicationinsights.io';
export const version = '?api-version=2024-05-01';
export const required = (options, key) => {
  if (typeof options[key] !== 'string' || !options[key].trim()) throw new Error(`--${key} is required`);
  return options[key].trim();
};
export function guid(value) {
  if (!/^[a-f\d]{8}(?:-[a-f\d]{4}){3}-[a-f\d]{12}$/i.test(value)) throw new Error('Expected an object ID in GUID format');
  return value.toLowerCase();
}
export function positive(value) {
  if (!/^\d+$/.test(String(value)) || !Number.isSafeInteger(Number(value)) || Number(value) < 1) throw new Error('Expected a positive safe integer');
  return Number(value);
}
export function gatewayUrl(value) {
  const url = new URL(value);
  if (url.protocol !== 'https:' || url.username || url.password || url.hash || url.search || /[\r\n\\]/.test(value)) throw new Error('URL must be HTTPS without credentials, query or fragment');
  return url.href.replace(/\/$/, '');
}
export const segment = value => encodeURIComponent(String(value));
export const list = value => String(value ?? '').split(',').map(item => item.trim()).filter(Boolean);
export function overrides(value) {
  const result = new Map();
  for (const pair of list(value)) {
    const [identity, tokens, extra] = pair.split('=');
    if (extra !== undefined || result.has(guid(identity))) throw new Error('Malformed or duplicate override');
    result.set(guid(identity), positive(tokens));
  }
  return result;
}
export function az(args) {
  const result = spawnSync('az', [...args, '--only-show-errors', '-o', 'json'], {
    encoding: 'utf8', timeout: 120000, maxBuffer: 16 * 1024 * 1024,
    env: { ...process.env, AZURE_EXTENSION_USE_DYNAMIC_INSTALL: 'no' }
  });
  if (result.error || result.status !== 0) throw new Error(`Azure CLI ${args.slice(0, 2).join(' ')} failed; check login and permissions`);
  try { return JSON.parse(result.stdout); } catch { throw new Error('Azure CLI returned invalid JSON'); }
}
export function token(resource) {
  const value = az(['account', 'get-access-token', '--resource', resource]).accessToken;
  if (typeof value !== 'string' || !value || /\s/.test(value)) throw new Error('Azure CLI returned no usable token');
  return value;
}
export async function request(uri, origin = ARM, options = {}) {
  const url = new URL(uri);
  if (url.origin !== origin || url.protocol !== 'https:' || url.username || url.password || url.hash) throw new Error('Refusing authenticated request outside the trusted origin');
  const credential = options.token ? await options.token() : token(options.resource || origin);
  const response = await (options.fetch || fetch)(url, {
    method: options.method || 'GET', redirect: 'error', signal: AbortSignal.timeout(120000),
    headers: { Authorization: `Bearer ${credential}`, 'Content-Type': 'application/json', ...options.headers },
    body: options.body === undefined ? undefined : JSON.stringify(options.body)
  });
  if (response.status === 404 && options.optional) return null;
  if (!response.ok) {
    const error = new Error(`Request to ${url.hostname} failed (HTTP ${response.status}); response body withheld`);
    error.status = response.status;
    throw error;
  }
  const text = await response.text();
  let data;
  try { data = text ? JSON.parse(text) : {}; } catch { throw new Error('Service returned malformed JSON'); }
  if (data.error) throw new Error('Service returned a partial or failed result');
  return options.envelope ? { data, headers: response.headers } : data;
}
export async function pages(uri, origin = GRAPH) {
  const values = [], seen = new Set();
  while (uri) {
    if (seen.has(uri) || seen.size >= 10000) throw new Error('Invalid pagination cycle or excessive page count');
    seen.add(uri);
    const page = await request(uri, origin);
    if (!Array.isArray(page.value)) throw new Error('Invalid list response');
    values.push(...page.value);
    uri = page['@odata.nextLink'] || page.nextLink;
  }
  return values;
}
export async function userId(value) {
  if (/^[\da-f-]{36}$/i.test(value)) return guid(value);
  const escaped = value.replace(/'/g, "''");
  const users = await pages(`${GRAPH}/v1.0/users?$filter=${segment(`userPrincipalName eq '${escaped}' or mail eq '${escaped}' or otherMails/any(mail:mail eq '${escaped}')`)}&$select=id`);
  if (users.length !== 1) throw new Error('User lookup must resolve exactly one object; pass an object ID');
  return guid(users[0].id);
}
export async function groupId(value) {
  if (/^[\da-f-]{36}$/i.test(value)) return guid(value);
  const groups = await pages(`${GRAPH}/v1.0/groups?$filter=${segment(`displayName eq '${value.replace(/'/g, "''")}'`)}&$select=id`);
  if (groups.length !== 1) throw new Error('Group lookup must resolve exactly one group; pass its object ID');
  return guid(groups[0].id);
}
export async function groupMembers(value, transitive = true) {
  const id = await groupId(value);
  return (await pages(`${GRAPH}/v1.0/groups/${id}/${transitive ? 'transitiveMembers' : 'members'}/microsoft.graph.user?$select=id,userPrincipalName`)).map(user => ({ ...user, id: guid(user.id) }));
}
export function jsonFile(file) { return JSON.parse(readFileSync(file, 'utf8').replace(/^\uFEFF/, '')); }
export function write(file, text) {
  mkdirSync(dirname(file), { recursive: true, mode: 0o700 });
  const descriptor = openSync(file, constants.O_WRONLY | constants.O_CREAT | constants.O_NOFOLLOW | constants.O_NONBLOCK, 0o600);
  try {
    const info = fstatSync(descriptor);
    if (!info.isFile() || info.nlink !== 1) throw new Error('Refusing non-regular or multiply linked output');
    fchmodSync(descriptor, 0o600);
    ftruncateSync(descriptor, 0);
    writeFileSync(descriptor, text);
  } finally { closeSync(descriptor); }
}
export const escapeXml = value => String(value).replace(/[&<>"']/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&apos;' })[char]);
export const choice = (value, allowed) => {
  if (!allowed.includes(value)) throw new Error(`Expected one of: ${allowed.join(', ')}`);
  return value;
};