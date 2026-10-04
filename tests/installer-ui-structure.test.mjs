import assert from 'node:assert/strict';
import { readdir, readFile } from 'node:fs/promises';
import { test } from 'node:test';

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
  for (const file of (await readdir(new URL('../tools/installer-ui/', import.meta.url))).filter((name) => name.endsWith('.mjs'))) {
    const source = await readFile(new URL(`../tools/installer-ui/${file}`, import.meta.url), 'utf8');
    assert.doesNotMatch(source, /const map = \{\};[\s\S]{0,500}x-checkId/, `${file} must delegate fieldsByCheckId to ui-model.js`);
  }
  const model = await readFile(new URL('../tools/installer-ui/ui-model.js', import.meta.url), 'utf8');
  assert.match(model, /ClaudeInstallerUiModel/);
});
