import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, rm } from 'node:fs/promises';
import { resolve } from 'node:path';
import { randomUUID } from 'node:crypto';
import { redactText } from './architecture-live.mjs';
import { redactVisibleDocument } from './architecture-live-dom.mjs';

test('display redaction never changes hidden OAuth fields, passwords or input values', async () => {
  const scratch = resolve('.shots-entra', `architecture-dom-test-${randomUUID()}`);
  await mkdir(scratch, { recursive: true });
  const before = { TEMP: process.env.TEMP, TMP: process.env.TMP, TMPDIR: process.env.TMPDIR };
  for (const key of Object.keys(before)) process.env[key] = scratch;
  let browser;
  try {
    const { chromium } = await import('playwright');
    browser = await chromium.launch();
    const page = await browser.newPage();
    await page.setContent(`<p>Example Operator operator@fabrikam.example</p>
      <input type="hidden" name="state" value="11111111-1111-1111-1111-111111111111">
      <input type="password" value="private-example-password">
      <input id="visible" readonly value="11111111-1111-1111-1111-111111111111">
      <textarea id="editor">11111111-1111-1111-1111-111111111111</textarea>
      <select id="selector"><option>Example Operator</option></select>
      <div hidden>Hidden model: operator@fabrikam.example</div>`);
    await page.evaluate(source => { window.__architectureRedactText = (0, eval)(`(${source})`); }, redactText.toString());
    await page.evaluate(redactVisibleDocument, [{ from: 'Example Operator', to: 'Contoso administrator' }]);
    assert.match(await page.locator('p').innerText(), /Contoso administrator administrator@contoso.com/);
    assert.equal(await page.locator('[name=state]').inputValue(), '11111111-1111-1111-1111-111111111111');
    assert.equal(await page.locator('[type=password]').inputValue(), 'private-example-password');
    assert.equal(await page.locator('#visible').inputValue(), '11111111-1111-1111-1111-111111111111');
    assert.equal(await page.locator('#editor').inputValue(), '11111111-1111-1111-1111-111111111111');
    assert.equal(await page.locator('#selector').inputValue(), 'Example Operator');
    assert.equal(await page.locator('div[hidden]').textContent(), 'Hidden model: operator@fabrikam.example');
    const overlays = await page.locator('[data-architecture-overlay]').allTextContents();
    assert.ok(overlays.includes('00000000-0000-0000-0000-000000000000'));
    assert.ok(overlays.includes('Contoso administrator'));
  } finally {
    if (browser) await browser.close();
    for (const [key, value] of Object.entries(before)) {
      if (value === undefined) delete process.env[key]; else process.env[key] = value;
    }
    await rm(scratch, { recursive: true, force: true });
  }
});
