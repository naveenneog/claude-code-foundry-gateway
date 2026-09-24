import test from 'node:test';
import assert from 'node:assert/strict';
import { reportRedactions, redactReportText, redactPortalPage, assertRedacted, validateCaptureProfile } from '../guide/lib/chargeback-redaction.mjs';
import { resolve } from 'node:path';
import { chromium } from 'playwright';

const inventory = {
  ResourceGroup: 'rg-private-example', ApimName: 'apim-private-example',
  SubscriptionName: 'Example subscription label', SubscriptionId: '11111111-1111-4111-8111-111111111111',
  TenantId: '22222222-2222-4222-8222-222222222222', OperatorName: 'Example Operator',
  OperatorAddress: 'operator@example.invalid',
  WorkspaceResourceId: '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-private-example/providers/Microsoft.OperationalInsights/workspaces/log-private-example',
  Resources: [
    { name: 'stprivateexample', type: 'Microsoft.Storage/storageAccounts' },
    { name: 'job-reports-mail-private', type: 'Microsoft.App/jobs' },
    { name: 'id-reports-admin-private', type: 'Microsoft.ManagedIdentity/userAssignedIdentities' },
  ],
};
test('discovered deployment and operator values become Contoso placeholders', () => {
  const pairs = reportRedactions(inventory);
  const raw = 'Example Operator operator@example.invalid Example subscription label rg-private-example apim-private-example stprivateexample job-reports-mail-private';
  const text = redactReportText(raw, pairs);
  assert.match(text, /Contoso administrator/);
  assert.match(text, /alice@contoso\.com/);
  assert.match(text, /streportscontoso/);
  assert.match(text, /job-reports-mail-contoso/);
  assertRedacted(text, pairs);
});
test('unknown GUIDs, email addresses and IPs are also masked', () => {
  const raw = '33333333-3333-4333-8333-333333333333 someone@example.invalid 10.42.8.4';
  const text = redactReportText(raw, []);
  assert.ok(!text.includes('33333333-'));
  assert.ok(!text.includes('someone@'));
  assert.ok(!text.includes('10.42.8.4'));
  assertRedacted(text, []);
});
test('a missed known resource or identity fails rather than publishes', () => {
  assert.throws(() => assertRedacted('stprivateexample', reportRedactions(inventory)), /unredacted/);
  assert.throws(() => assertRedacted('person@example.invalid', []), /unredacted/);
});
test('only the copied profile inside the worktree may be opened', () => {
  const root = resolve('.');
  assert.equal(validateCaptureProfile(root, resolve(root, '.pw-profile')), resolve(root, '.pw-profile'));
  assert.throws(() => validateCaptureProfile(root, resolve(root, '..', 'other', '.pw-profile')), /worktree/);
});
test('browser redaction covers visible text, input values and subsequent rendering', async () => {
  const browser = await chromium.launch({ headless: true });
  try {
    const page = await browser.newPage();
    await page.setContent('<h1>stprivateexample</h1><input value="11111111-1111-4111-8111-111111111111"><p>operator@example.invalid</p>');
    const pairs = reportRedactions(inventory);
    await redactPortalPage(page, pairs);
    assertRedacted(await page.locator('body').innerText(), pairs);
    assertRedacted(await page.locator('input').inputValue(), pairs);
    await page.evaluate(() => { const p = document.createElement('p'); p.textContent = 'Example Operator'; document.body.append(p); });
    await page.waitForTimeout(350);
    assertRedacted(await page.locator('body').innerText(), pairs);
  } finally { await browser.close(); }
});
