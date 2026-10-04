import { createHash, timingSafeEqual } from 'node:crypto';

export const maxBodyBytes = 256 * 1024;

export function quotePowerShell(value) {
  return `'${String(value).replaceAll("'", "''")}'`;
}

export function quoteBash(value) {
  return `'${String(value).replaceAll("'", "'\"'\"'")}'`;
}

export function tokenHash(token) {
  return createHash('sha256').update(token).digest();
}

export function constantTimeTokenEquals(actual, expectedHash) {
  if (!actual) return false;
  const actualHash = tokenHash(actual);
  return actualHash.length === expectedHash.length && timingSafeEqual(actualHash, expectedHash);
}

export function parseCookies(header) {
  const cookies = new Map();
  for (const part of String(header || '').split(';')) {
    const index = part.indexOf('=');
    if (index > 0) cookies.set(part.slice(0, index).trim(), decodeURIComponent(part.slice(index + 1).trim()));
  }
  return cookies;
}

export function contentSecurityPolicy() {
  return "default-src 'self'; base-uri 'none'; object-src 'none'; frame-ancestors 'none'; form-action 'none'; script-src 'self'; style-src 'self'";
}

export function send(res, status, body, headers = {}) {
  const text = typeof body === 'string' ? body : JSON.stringify(body);
  res.writeHead(status, {
    'content-type': typeof body === 'string' && body.startsWith('<!doctype') ? 'text/html; charset=utf-8' : 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(text),
    'content-security-policy': contentSecurityPolicy(),
    'x-content-type-options': 'nosniff',
    'referrer-policy': 'no-referrer',
    ...headers,
  });
  res.end(text);
}

export function sendText(res, status, text, contentType, headers = {}) {
  res.writeHead(status, {
    'content-type': contentType,
    'content-length': Buffer.byteLength(text),
    'content-security-policy': contentSecurityPolicy(),
    'x-content-type-options': 'nosniff',
    'referrer-policy': 'no-referrer',
    ...headers,
  });
  res.end(text);
}

export function isAllowedHost(host, port, extraHosts = []) {
  const value = String(host || '').toLowerCase();
  const withPort = value.includes(':') ? value : `${value}:${port}`;
  const allowed = new Set([
    `127.0.0.1:${port}`,
    `localhost:${port}`,
    `[::1]:${port}`,
    ...extraHosts.map((h) => {
      const lower = h.toLowerCase();
      return lower.includes(':') ? lower : `${lower}:${port}`;
    }),
  ]);
  return allowed.has(value) || allowed.has(withPort);
}

export function isLoopbackBind(host) {
  return host === '127.0.0.1' || host === 'localhost' || host === '::1' || host === '[::1]';
}

export function assertSameOrigin(req) {
  const expected = `http://${req.headers.host}`;
  const origin = req.headers.origin;
  if (origin && origin !== expected) {
    const error = new Error('same-origin request required');
    error.status = 403;
    throw error;
  }
  const fetchSite = req.headers['sec-fetch-site'];
  if (fetchSite && fetchSite !== 'same-origin' && fetchSite !== 'none') {
    const error = new Error('same-origin request required');
    error.status = 403;
    throw error;
  }
}

export async function readJsonBody(req) {
  let total = 0;
  const chunks = [];
  for await (const chunk of req) {
    total += chunk.length;
    if (total > maxBodyBytes) {
      const error = new Error('request body is too large');
      error.status = 413;
      throw error;
    }
    chunks.push(chunk);
  }
  const raw = Buffer.concat(chunks).toString('utf8');
  if (!raw) return {};
  try {
    return JSON.parse(raw);
  } catch {
    const error = new Error('request body is not valid JSON');
    error.status = 400;
    throw error;
  }
}
