import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  makePortalUrl, redactText, isSignInPage, isBladeReady, validateCapturePlan, publicCaptureReceipt, allowConsoleRequest,
} from './architecture-live.mjs';

const tenant = '11111111-1111-1111-1111-111111111111';
const subscription = '22222222-2222-2222-2222-222222222222';
const resource = `/subscriptions/${subscription}/resourceGroups/rg-fabrikam-example/providers/Microsoft.ApiManagement/service/apim-fabrikam-example`;
const plan = {
  version: 1, tenantId: tenant, subscriptionId: subscription,
  replacements: [{ from: 'apim-fabrikam-example', to: 'apim-contoso' }],
  pages: [{ id: 'gateway-overview', title: 'Gateway overview', resourceId: resource, blade: 'overview', expect: 'Overview' }],
};

test('portal URLs require discovered tenant and resource identifiers', () => {
  assert.equal(makePortalUrl(tenant, resource, 'overview'), `https://portal.azure.com/#@${tenant}/resource${resource}/overview`);
  assert.throws(() => makePortalUrl('', resource), /tenant/i);
  assert.throws(() => makePortalUrl(tenant, 'https://example.com'), /resource/i);
  assert.throws(() => makePortalUrl(tenant, resource, '../keys'), /blade/i);
});

test('capture plans have no deployment fallback and reject duplicate outputs', () => {
  assert.equal(validateCapturePlan(plan), true);
  assert.throws(() => validateCapturePlan({ ...plan, tenantId: undefined }), /tenant/i);
  assert.throws(() => validateCapturePlan({ ...plan, pages: [...plan.pages, plan.pages[0]] }), /duplicate/i);
  assert.throws(() => validateCapturePlan({ ...plan, pages: [{ ...plan.pages[0], id: '../escaped' }] }), /capture id/i);
});

test('redaction replaces full names, addresses, ids and deployment hosts', () => {
  const raw = `Fabrikam Operator operator@fabrikam.example ${tenant} apim-fabrikam-example.azure-api.net 10.87.0.12`;
  const clean = redactText(raw, [
    { from: 'Fabrikam Operator', to: 'Contoso administrator' },
    ...plan.replacements,
  ]);
  assert.match(clean, /Contoso administrator/);
  assert.doesNotMatch(clean, /Fabrikam Operator|operator@fabrikam|11111111|10\.87\.0\.12|apim-fabrikam/);
  assert.match(clean, /contoso\.com/);
});

test('longer discovered names are replaced before shorter parent names', () => {
  assert.equal(redactText('alpha-example-long alpha-example', [
    { from: 'alpha-example', to: 'Contoso' },
    { from: 'alpha-example-long', to: 'Contoso service' },
  ]), 'Contoso service Contoso');
});

test('discovered identity casing cannot evade replacement', () => {
  assert.equal(redactText('FABRIKAM OPERATOR', [{ from: 'Fabrikam Operator', to: 'Contoso administrator' }]), 'Contoso administrator');
});

test('fixed private DNS zones survive but deployed email domains do not', () => {
  assert.equal(redactText('privatelink.blob.core.windows.net', []), 'privatelink.blob.core.windows.net');
  assert.equal(redactText('example-generated.azurecomm.net', []), 'contoso.azurecomm.net');
});

test('provider app display names are not assumed to be ARM resource names', () => {
  assert.equal(redactText('Microsoft (example-resolver-registration)', []), 'Microsoft (Contoso application)');
});

test('tenant DNS names do not survive as plain directory labels', () => {
  assert.equal(redactText('FABRIKAM.ONMICROSOFT.COM', []), 'contoso.onmicrosoft.com');
});

test('opaque compact identifiers and exact entitlement maps are redacted', () => {
  assert.equal(redactText('f'.repeat(32), []), '[id redacted]');
  assert.equal(redactText(',unit=example-group:1000,', [
    { from: ',unit=example-group:1000,', to: '[configuration redacted]' },
  ]), '[configuration redacted]');
});

test('a resource shell or sidebar is not evidence of a loaded blade', () => {
  assert.equal(isBladeReady('Overview Activity log Networking', 'Overview', 'Essentials'), false);
  assert.equal(isBladeReady('Overview Essentials Resource group Subscription Pricing tier Basic v2', 'Overview', 'Essentials'), true);
  assert.equal(isBladeReady('Overview Essentials Error loading', 'Overview', 'Essentials'), false);
});

test('exact code identifiers and Azure blade labels survive redaction', () => {
  const labels = 'Turnstile.Manager ApiManagementGatewayLlmLog Named values Identity Networking Log Analytics Reader';
  assert.equal(redactText(labels, []), labels);
});

test('sign-in detection stops captures instead of attempting authentication', () => {
  assert.equal(isSignInPage('https://login.microsoftonline.com/common/oauth2/v2.0/authorize', ''), true);
  assert.equal(isSignInPage('https://portal.azure.com/', 'Pick an account'), true);
  assert.equal(isSignInPage('https://portal.azure.com/', 'Enter password'), true);
  assert.equal(isSignInPage('https://ms.portal.azure.com/', 'Microsoft Azure Overview Identity'), false);
});

test('public receipts cannot carry resource ids, tenant data or addresses', () => {
  const receipt = publicCaptureReceipt({
    id: 'gateway-overview', title: 'Gateway overview', status: 'captured',
    image: 'docs/images/architecture-live/gateway-overview.png', sha256: 'a'.repeat(64),
    capturedUtc: '2026-09-24T18:00:00.000Z', resourceId: resource, tenantId: tenant,
    email: 'operator@fabrikam.example', url: makePortalUrl(tenant, resource),
  });

  assert.deepEqual(Object.keys(receipt).sort(), ['capturedUtc', 'id', 'image', 'sha256', 'status', 'title']);
  assert.doesNotMatch(JSON.stringify(receipt), /fabrikam|11111111|22222222|subscriptions/);
});

test('console capture allows code redemption once but blocks management writes', () => {
  const base = 'https://console.contoso.example';
  assert.equal(allowConsoleRequest(base, `${base}/api/v1/auth/code`, 'POST', true), true);
  assert.equal(allowConsoleRequest(base, `${base}/api/v1/auth/code`, 'POST', false), false);
  assert.equal(allowConsoleRequest(base, `${base}/api/v1/gateway-apply`, 'POST', true), false);
  assert.equal(allowConsoleRequest(base, `${base}/api/v1/gateway-tiers`, 'PUT', false), false);
  assert.equal(allowConsoleRequest(base, `${base}/api/v1/budgets`, 'GET', false), true);
  assert.equal(allowConsoleRequest(base, 'https://other.contoso.example/api/v1/auth/code', 'POST', true), false);
});
