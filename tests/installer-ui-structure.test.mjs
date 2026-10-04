import assert from 'node:assert/strict';
import { once } from 'node:events';
import { readdir, readFile } from 'node:fs/promises';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { createContext, runInContext } from 'node:vm';
import { createInstallerUiServer } from '../tools/installer-ui/server.mjs';

test('the form uses fixed script routes and no string-built DOM insertion sinks', async () => {
  const html = await readFile(new URL('../tools/installer-ui/index.html', import.meta.url), 'utf8');
  assert.match(html, /<script defer src="\.\/ui-model\.js"><\/script>\s*<script defer src="\.\/installer-ui-business-units\.js"><\/script>\s*<script defer src="\.\/installer-ui-prefill\.js"><\/script>\s*<script defer src="\.\/installer-ui-actions\.js"><\/script>\s*<script defer src="\.\/installer-ui-problems\.js"><\/script>\s*<script defer src="\.\/installer-ui\.js"><\/script>/);
  assert.doesNotMatch(html, /type="module"|import\s+|export\s+/);
  assert.doesNotMatch(html, /<script>\s*\(/);
  const scripts = {
    js: await readFile(new URL('../tools/installer-ui/installer-ui.js', import.meta.url), 'utf8'),
    businessUnits: await readFile(new URL('../tools/installer-ui/installer-ui-business-units.js', import.meta.url), 'utf8'),
    prefill: await readFile(new URL('../tools/installer-ui/installer-ui-prefill.js', import.meta.url), 'utf8'),
    actions: await readFile(new URL('../tools/installer-ui/installer-ui-actions.js', import.meta.url), 'utf8'),
    problems: await readFile(new URL('../tools/installer-ui/installer-ui-problems.js', import.meta.url), 'utf8'),
  };
  for (const source of Object.values(scripts)) assert.doesNotMatch(source, /innerHTML|insertAdjacentHTML|import\s+|export\s+/);
  for (const name of ['buildPortableCommands', 'coerceAnswerValue', 'collectAnswersFromEntries', 'fieldsByCheckId', 'quoteBash', 'quotePowerShell', 'validateBusinessUnits']) {
    for (const [script, source] of Object.entries(scripts)) assert.doesNotMatch(source, new RegExp(`function\\s+${name}\\b|const\\s+${name}\\b`), `${name} must live only in ui-model.js, not ${script}`);
  }
  const schema = JSON.parse(await readFile(new URL('../schemas/claude-gateway.answers.schema.json', import.meta.url), 'utf8'));
  const schemaExtensionKeys = new Set(JSON.stringify(schema).match(/"x-[^"]+"/g)?.map((key) => key.slice(1, -1)) || []);
  const context = createContext({ globalThis: {} });
  runInContext(await readFile(new URL('../tools/installer-ui/ui-model.js', import.meta.url), 'utf8'), context);
  const modelFunctionNames = Object.entries(context.globalThis.ClaudeInstallerUiModel)
    .filter(([, value]) => typeof value === 'function')
    .map(([name]) => name);
  for (const file of (await readdir(new URL('../tools/installer-ui/', import.meta.url))).filter((name) => name.endsWith('.mjs'))) {
    const source = await readFile(new URL(`../tools/installer-ui/${file}`, import.meta.url), 'utf8');
    for (const key of schemaExtensionKeys) assert.doesNotMatch(source, new RegExp(`['"]${key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}['"]`), `${file} must not copy schema extension key ${key}`);
    for (const name of modelFunctionNames) {
      const declaration = new RegExp(`(?:export\\s+)?(?:async\\s+)?function\\s+${name}\\s*\\([^)]*\\)\\s*\\{([\\s\\S]*?)\\}`, 'm');
      const match = source.match(declaration);
      if (!match) continue;
      assert.match(match[1], new RegExp(`return \\(await loadUiModel\\(\\)\\)\\.${name}\\(`), `${file} must delegate ${name} to ui-model.js`);
    }
  }
  const model = await readFile(new URL('../tools/installer-ui/ui-model.js', import.meta.url), 'utf8');
  assert.match(model, /ClaudeInstallerUiModel/);
  const server = await createInstallerUiServer({ token: 'structure-token-with-at-least-32-bytes-0000', stubInstaller: fileURLToPath(new URL('./installer-ui-stub.mjs', import.meta.url)) });
  const address = await server.listenAsync('127.0.0.1');
  const base = `http://127.0.0.1:${address.port}`;
  try {
    const bootstrap = await fetch(`${base}/?token=${encodeURIComponent(server.token)}`, { redirect: 'manual' });
    const cookie = bootstrap.headers.get('set-cookie').split(';')[0];
    const routeFiles = [...html.matchAll(/<script defer src="\.\/([^"]+)"><\/script>/g)].map((match) => match[1]);
    routeFiles.push('installer-ui.css');
    for (const file of routeFiles) {
      const response = await fetch(`${base}/${file}`, { headers: { cookie } });
      assert.equal(response.status, 200, file);
      assert.equal(await response.text(), await readFile(new URL(`../tools/installer-ui/${file}`, import.meta.url), 'utf8'), file);
    }
    assert.equal((await fetch(`${base}/installer-ui-missing.js`, { headers: { cookie } })).status, 404);
  } finally {
    await server.cleanup();
    server.close();
    await once(server, 'close').catch(() => {});
  }
});
