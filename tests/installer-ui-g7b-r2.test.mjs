import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';

test('R2-5 PFX path is reported once because defaults create no PFX requirement', async () => {
  const source = await readFile(new URL('../tools/installer-ui/ui-model.js', import.meta.url), 'utf8');
  const context = { globalThis: {} };
  (await import('node:vm')).runInNewContext(source, context);
  const model = context.globalThis.ClaudeInstallerUiModel;
  const schema = JSON.parse(await readFile(new URL('../schemas/claude-gateway.answers.schema.json', import.meta.url), 'utf8'));
  const answers = { schemaVersion: 1, AddressMode: 'custom', AddressCertificateSource: 'Pfx' };
  const problems = [...model.validateAnswers(schema, answers, 'Install-ClaudeGateway.ps1'), ...model.validateEffectiveAddressDefaults(schema, answers)];
  assert.equal(problems.filter((p) => p.path === 'AddressPfxPath').length, 1);
});

test('R2-7 static mode shows terminal PFX command without Yes', async () => {
  const { chromium } = await import('playwright');
  const browser = await chromium.launch({ headless: true });
  try {
    const page = await browser.newPage();
    await page.goto(new URL('../tools/installer-ui/index.html', import.meta.url).href);
    await page.waitForSelector('[name="SubscriptionId"]');
    await page.locator('[name="AddressMode"]').selectOption('custom');
    await page.locator('[name="AddressCertificateSource"]').selectOption('Pfx');
    await page.locator('[name="AddressHostname"]').fill('claude.example.test');
    await page.locator('[name="AddressPfxPath"]').fill('cert.pfx');
    const commands = await page.locator('#commands').textContent();
    assert.match(commands, /-AnswersPath/);
    assert.doesNotMatch(commands, / -Yes /);
    assert.match(commands, /PFX password/);
  } finally {
    await browser.close();
  }
});
