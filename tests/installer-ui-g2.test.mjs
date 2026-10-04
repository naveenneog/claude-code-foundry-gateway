import assert from 'node:assert/strict';
import { once } from 'node:events';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import { createInstallerUiServer } from '../tools/installer-ui/server.mjs';

async function startServer(extra = {}) {
  const logs = [];
  const server = await createInstallerUiServer({
    token: 'g2-test-token-with-at-least-32-bytes-0000',
    idleMs: 60_000,
    log: (line) => logs.push(line),
    ...extra,
  });
  const address = await server.listenAsync('127.0.0.1');
  const base = `http://127.0.0.1:${address.port}`;
  const boot = await fetch(`${base}/?token=${encodeURIComponent(server.token)}`, { redirect: 'manual' });
  const cookie = boot.headers.get('set-cookie')?.split(';')[0] || '';
  const session = await (await fetch(`${base}/api/session`, { headers: { cookie } })).json();
  return {
    server,
    base,
    cookie,
    csrfToken: session.csrfToken,
    logs,
    async fetch(path, options = {}) {
      const headers = { cookie, ...(options.headers || {}) };
      if (options.method === 'POST') headers['x-csrf-token'] ??= session.csrfToken;
      return fetch(`${base}${path}`, { ...options, headers });
    },
    async close() {
      await server.cleanup();
      server.close();
      await once(server, 'close').catch(() => {});
    },
  };
}

test('G0 serves index.html byte-identically at the root route', async () => {
  const app = await startServer();
  try {
    const served = await (await app.fetch('/')).text();
    const canonical = await readFile(new URL('../tools/installer-ui/index.html', import.meta.url), 'utf8');
    assert.equal(served, canonical);
    assert.equal(await (await app.fetch('/index.html')).text(), canonical);
  } finally {
    await app.close();
  }
});
