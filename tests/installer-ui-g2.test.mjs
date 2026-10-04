import assert from 'node:assert/strict';
import { once } from 'node:events';
import { mkdir, readFile, rm } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { createInstallerUiServer } from '../tools/installer-ui/server.mjs';
import { canonicalize, createPreflightStore, preflightFingerprint, scopeCovers, scopeFromBody } from '../tools/installer-ui/preflight-record.mjs';

const stub = fileURLToPath(new URL('./installer-ui-stub.mjs', import.meta.url));
const passingAnswers = { schemaVersion: 1, SubscriptionId: '00000000-0000-4000-8000-000000000093' };

async function startServer(extra = {}) {
  const logs = [];
  const scratch = join(tmpdir(), 'p93-installer-ui-g2', `${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`);
  await rm(scratch, { recursive: true, force: true });
  await mkdir(scratch, { recursive: true });
  const log = join(scratch, 'stub.ndjson');
  const server = await createInstallerUiServer({
    token: 'g2-test-token-with-at-least-32-bytes-0000',
    stubInstaller: extra.stubInstaller || stub,
    idleMs: 60_000,
    env: { P93_INSTALLER_UI_STUB_LOG: log, ...(extra.env || {}) },
    log: (line) => logs.push(line),
    ...extra,
    env: { P93_INSTALLER_UI_STUB_LOG: log, ...(extra.env || {}) },
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
    log,
    scratch,
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
      await rm(scratch, { recursive: true, force: true });
    },
  };
}

async function postJson(app, path, body) {
  const response = await app.fetch(path, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  const text = await response.text();
  return { response, text, body: text ? JSON.parse(text) : null };
}

async function postText(app, path, body) {
  const response = await app.fetch(path, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  return { response, text: await response.text() };
}

async function waitForStubRuns(app, count) {
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    if (existsSync(app.log)) {
      const lines = (await readFile(app.log, 'utf8')).trim().split(/\r?\n/).filter(Boolean).map((line) => JSON.parse(line));
      if (lines.filter((entry) => entry.args?.includes('-Yes')).length >= count) return;
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(`timed out waiting for ${count} installer runs`);
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

test('P1 preflight record canonical form and scope coverage are deterministic', () => {
  assert.equal(canonicalize({ b: 2, a: { d: 4, c: [3, 2] } }), '{"a":{"c":[3,2],"d":4},"b":2}');
  assert.equal(preflightFingerprint({ answers: { b: 2, a: 1 }, scope: ['resource-group'], engine: 'pwsh' }), preflightFingerprint({ answers: { a: 1, b: 2 }, scope: ['resource-group'], engine: 'pwsh' }));
  assert.equal(scopeFromBody({ answers: {} }), 'full');
  assert.deepEqual(scopeFromBody({ steps: ['b', 'a', 'a'] }, ['b', 'a', 'a']), ['a', 'b']);
  assert.equal(scopeCovers('full', ['verify']), true);
  assert.equal(scopeCovers(['a', 'b'], ['a']), true);
  assert.equal(scopeCovers(['a'], ['a', 'b']), false);
  const store = createPreflightStore();
  store.replaceForAnswers({ fingerprint: 'a', answersDigest: 'd', engine: 'pwsh', scope: ['a'], time: '1' });
  store.replaceForAnswers({ fingerprint: 'b', answersDigest: 'd', engine: 'pwsh', scope: ['b'], time: '2' });
  assert.equal(store.lookup('a'), null);
  assert.equal(store.lookup('b').scope[0], 'b');
});

test('P1 run admission requires a matching passing preflight fingerprint', async () => {
  const app = await startServer();
  try {
    const noPreflight = await postJson(app, '/api/run/stream', { answers: passingAnswers, steps: ['resource-group'], fingerprint: '0'.repeat(64) });
    assert.equal(noPreflight.response.status, 409);
    assert.equal(noPreflight.body.reason, 'preflight-required');

    const failApp = await startServer({ env: { P93_INSTALLER_UI_STUB_PREFLIGHT_FAIL: '1' } });
    try {
      const failedPreflight = await postJson(failApp, '/api/preflight', { answers: passingAnswers, steps: ['resource-group'] });
      assert.equal(failedPreflight.body.preflight.result, 'FAIL');
      assert.equal(failedPreflight.body.fingerprint, undefined);
      const refused = await postJson(failApp, '/api/run/stream', { answers: passingAnswers, steps: ['resource-group'], fingerprint: '0'.repeat(64) });
      assert.equal(refused.response.status, 409);
      assert.equal(refused.body.reason, 'preflight-required');
    } finally {
      await failApp.close();
    }

    const pass = await postJson(app, '/api/preflight', { answers: passingAnswers, steps: ['resource-group'] });
    assert.equal(pass.response.status, 200);
    assert.match(pass.body.fingerprint, /^[0-9a-f]{64}$/);
    const run = await postText(app, '/api/run/stream', { answers: passingAnswers, steps: ['resource-group'], fingerprint: pass.body.fingerprint });
    assert.equal(run.response.status, 200, run.text);

    const changed = await postJson(app, '/api/run/stream', { answers: { ...passingAnswers, ResourceGroup: 'changed' }, steps: ['resource-group'], fingerprint: pass.body.fingerprint });
    assert.equal(changed.response.status, 409);
    assert.equal(changed.body.reason, 'preflight-required');

    const forged = await postJson(app, '/api/run/stream', { answers: passingAnswers, steps: ['resource-group'], fingerprint: 'f'.repeat(64) });
    assert.equal(forged.response.status, 409);
    assert.equal(forged.body.reason, 'preflight-required');
  } finally {
    await app.close();
  }
});

test('P1 fingerprints canonicalize answer keys and cover step scopes', async () => {
  const app = await startServer();
  try {
    const a = await postJson(app, '/api/preflight', { answers: { schemaVersion: 1, SubscriptionId: passingAnswers.SubscriptionId, ResourceGroup: 'rg' }, steps: ['gateway-deployment', 'resource-group', 'resource-group'] });
    const b = await postJson(app, '/api/preflight', { answers: { ResourceGroup: 'rg', SubscriptionId: passingAnswers.SubscriptionId, schemaVersion: 1 }, steps: ['resource-group', 'gateway-deployment'] });
    assert.equal(a.body.fingerprint, b.body.fingerprint);
    const wider = await postJson(app, '/api/run/stream', { answers: { ...passingAnswers, ResourceGroup: 'rg' }, steps: ['resource-group', 'gateway-deployment', 'verify'], fingerprint: a.body.fingerprint });
    assert.equal(wider.response.status, 409);
    const subset = await postText(app, '/api/run/stream', { answers: { ...passingAnswers, ResourceGroup: 'rg' }, steps: ['resource-group'], fingerprint: a.body.fingerprint });
    assert.equal(subset.response.status, 200, subset.text);
    const differentSteps = await postJson(app, '/api/preflight', { answers: { schemaVersion: 1, SubscriptionId: passingAnswers.SubscriptionId, ResourceGroup: 'rg' }, steps: ['resource-group'] });
    assert.notEqual(a.body.fingerprint, differentSteps.body.fingerprint);

    const full = await postJson(app, '/api/preflight', { answers: passingAnswers, fullRun: true });
    const selection = await postText(app, '/api/run/stream', { answers: passingAnswers, steps: ['verify'], fingerprint: full.body.fingerprint });
    assert.equal(selection.response.status, 200, selection.text);
  } finally {
    await app.close();
  }
});

test('P1 fail after pass clears the matching stored preflight and exit-code failures are not stored', async () => {
  const failAfterPass = await startServer({ env: { P93_INSTALLER_UI_STUB_PREFLIGHT_FAIL_ON_SECOND: join(tmpdir(), `p93-preflight-counter-${process.pid}-${Date.now()}`) } });
  try {
    const pass = await postJson(failAfterPass, '/api/preflight', { answers: passingAnswers, steps: ['resource-group'] });
    assert.match(pass.body.fingerprint, /^[0-9a-f]{64}$/);
    const fail = await postJson(failAfterPass, '/api/preflight', { answers: passingAnswers, steps: ['resource-group'] });
    assert.equal(fail.body.preflight.result, 'FAIL');
    const refused = await postJson(failAfterPass, '/api/run/stream', { answers: passingAnswers, steps: ['resource-group'], fingerprint: pass.body.fingerprint });
    assert.equal(refused.response.status, 409);
    assert.equal(refused.body.reason, 'preflight-required');
  } finally {
    await failAfterPass.close();
  }

  const exitOne = await startServer({ env: { P93_INSTALLER_UI_STUB_PREFLIGHT_PASS_EXIT_1: '1' } });
  try {
    const result = await postJson(exitOne, '/api/preflight', { answers: passingAnswers, steps: ['resource-group'] });
    assert.equal(result.body.preflight.result, 'PASS');
    assert.equal(result.body.exitCode, 1);
    assert.equal(result.body.fingerprint, undefined);
  } finally {
    await exitOne.close();
  }
});

test('P1 removes the plan API and script', async () => {
  const app = await startServer();
  try {
    const plan = await postJson(app, '/api/plan', { answers: passingAnswers });
    assert.equal(plan.response.status, 404);
    await assert.rejects(readFile(new URL('../scripts/Get-ClaudeInstallerUiPlan.ps1', import.meta.url), 'utf8'), /ENOENT/);
  } finally {
    await app.close();
  }
});

test('P1 browser shows fingerprint, marks stale on answer changes and reruns a covered failed step', { timeout: 60_000 }, async () => {
  const app = await startServer({ env: { P93_INSTALLER_UI_STUB_FAIL_STEP: 'gateway-deployment' } });
  const { chromium } = await import('playwright');
  let browser;
  try { browser = await chromium.launch({ channel: 'msedge', headless: true }); }
  catch { browser = await chromium.launch({ headless: true }); }
  try {
    const page = await browser.newPage();
    await page.context().addCookies([{ name: 'installer_token', value: app.server.token, domain: '127.0.0.1', path: '/', httpOnly: true, sameSite: 'Strict' }]);
    await page.route('**/api/identity', (route) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ signedIn: true, user: 'operator@example.com' }) }));
    await page.goto(`${app.base}/`);
    await page.getByRole('button', { name: 'List steps' }).click();
    await page.locator('[name="SubscriptionId"]').fill(passingAnswers.SubscriptionId);
    await page.locator('#step-list input[value="gateway-deployment"]').check();
    await page.getByRole('button', { name: 'Run preflight' }).click();
    await page.getByText(/Passing preflight [0-9a-f]{12}/).waitFor();
    await assert.doesNotReject(page.getByRole('button', { name: 'Run selected steps' }).isEnabled().then((enabled) => assert.equal(enabled, true)));
    await page.locator('[name="ResourceGroup"]').fill('changed');
    await page.getByText(/Preflight is stale/).waitFor();
    assert.equal(await page.getByRole('button', { name: 'Run selected steps' }).isDisabled(), true);
    await page.locator('[name="ResourceGroup"]').fill('');
    await page.getByRole('button', { name: 'Run preflight' }).click();
    await page.getByText(/Passing preflight [0-9a-f]{12}/).waitFor();
    await page.getByRole('button', { name: 'Run selected steps' }).click();
    await page.getByText(/summary:/).waitFor();
    assert.equal(await page.getByRole('button', { name: 'Re-run failed step' }).isEnabled(), true);
    await page.getByRole('button', { name: 'Re-run failed step' }).click();
    await waitForStubRuns(app, 2);
  } finally {
    await app.server.cleanup();
    await browser.close();
    await app.close();
  }
});

test('P1 business-unit button changes mark a passing preflight stale', async () => {
  const app = await startServer();
  const { chromium } = await import('playwright');
  let browser;
  try { browser = await chromium.launch({ channel: 'msedge', headless: true }); }
  catch { browser = await chromium.launch({ headless: true }); }
  try {
    const page = await browser.newPage();
    await page.context().addCookies([{ name: 'installer_token', value: app.server.token, domain: '127.0.0.1', path: '/', httpOnly: true, sameSite: 'Strict' }]);
    await page.route('**/api/identity', (route) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ signedIn: true, user: 'operator@example.com' }) }));
    await page.goto(`${app.base}/`);
    await page.getByRole('button', { name: 'List steps' }).click();
    await page.locator('[name="SubscriptionId"]').fill(passingAnswers.SubscriptionId);
    await page.locator('#step-list input[value="resource-group"]').check();
    await page.getByRole('button', { name: 'Run preflight' }).click();
    await page.getByText(/Passing preflight [0-9a-f]{12}/).waitFor();
    assert.equal(await page.getByRole('button', { name: 'Run selected steps' }).isEnabled(), true);
    await page.getByRole('button', { name: 'Add unit' }).click();
    await page.getByText(/Preflight is stale/).waitFor();
    assert.equal(await page.getByRole('button', { name: 'Run selected steps' }).isDisabled(), true);
  } finally {
    await browser.close();
    await app.close();
  }
});

test('P1 preflight lists steps only when a step scope is requested', async () => {
  const app = await startServer();
  try {
    await postJson(app, '/api/preflight', { answers: passingAnswers, fullRun: true });
    let calls = (await readFile(app.log, 'utf8')).trim().split(/\r?\n/).filter(Boolean).map((line) => JSON.parse(line));
    assert.equal(calls.length, 1);
    assert.ok(calls[0].args.includes('-Preflight'));
    await postJson(app, '/api/preflight', { answers: passingAnswers, steps: ['resource-group'] });
    calls = (await readFile(app.log, 'utf8')).trim().split(/\r?\n/).filter(Boolean).map((line) => JSON.parse(line));
    assert.equal(calls.length, 3);
    assert.ok(calls.some((entry) => entry.args.includes('-ListSteps')));
  } finally {
    await app.close();
  }
});

test('E1 missing pwsh puts the server and page in static mode without spawning children', async () => {
  const app = await startServer({ pwsh: 'pwsh-missing-for-p93' });
  try {
    const session = await (await app.fetch('/api/session')).json();
    assert.equal(session.mode, 'static');
    assert.match(session.reason, /pwsh-missing-for-p93/);
    assert.match(app.logs.join('\n'), /pwsh-missing-for-p93/);
    for (const [method, route, body] of [
      ['GET', '/api/steps'],
      ['GET', '/api/identity'],
      ['POST', '/api/prefill', { kind: 'subscriptions' }],
      ['POST', '/api/preflight', { answers: passingAnswers }],
      ['POST', '/api/run/stream', { answers: passingAnswers, steps: ['resource-group'], fingerprint: '0'.repeat(64) }],
      ['POST', '/api/run/stop', { runId: 'x' }],
    ]) {
      const response = method === 'POST' ? await postJson(app, route, body) : { response: await app.fetch(route), body: null };
      const payload = response.body || await response.response.json();
      assert.equal(response.response.status, 503, route);
      assert.match(payload.reason, /pwsh/);
    }
    await assert.rejects(readFile(app.log, 'utf8'));

    const { chromium } = await import('playwright');
    let browser;
    try { browser = await chromium.launch({ channel: 'msedge', headless: true }); }
    catch { browser = await chromium.launch({ headless: true }); }
    try {
      const page = await browser.newPage();
      await page.context().addCookies([{ name: 'installer_token', value: app.server.token, domain: '127.0.0.1', path: '/', httpOnly: true, sameSite: 'Strict' }]);
      await page.goto(`${app.base}/`);
      await page.locator('#preflight-state').getByText(/Static fallback/).waitFor();
      const hidden = await page.evaluate(() => ['preflight', 'steps', 'run', 'full-run', 'stop-run'].map((id) => document.getElementById(id).hidden));
      assert.deepEqual(hidden, [true, true, true, true, true]);
    } finally {
      await browser.close();
    }
  } finally {
    await app.close();
  }
});
