const GUID = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
const ARM = /^\/subscriptions\/[0-9a-f-]{36}\/resourceGroups\/[^/?#]+\/providers\/Microsoft\.[^/?#]+\/[^?#]+$/i;

export function makePortalUrl(tenant, resource, blade = 'overview') {
  if (!GUID.test(tenant ?? '')) throw new Error('A discovered tenant id is required');
  if (!ARM.test(resource ?? '')) throw new Error('A discovered ARM resource id is required');
  if (!/^[a-z][a-z0-9/-]*$/i.test(blade) || blade.includes('..')) throw new Error('Invalid portal blade');
  return `https://portal.azure.com/#@${tenant}/resource${encodeURI(resource)}/${blade}`;
}

export function validateCapturePlan(plan) {
  if (plan?.version !== 1 || !GUID.test(plan.tenantId ?? '') || !GUID.test(plan.subscriptionId ?? '')) {
    throw new Error('Plan needs discovered tenant and subscription ids');
  }
  if (!Array.isArray(plan.pages) || !plan.pages.length || !Array.isArray(plan.replacements)) {
    throw new Error('Plan needs pages and discovered redaction replacements');
  }
  const ids = new Set();
  for (const page of plan.pages) {
    if (!/^[a-z0-9-]+$/.test(page.id ?? '')) throw new Error('Invalid capture id');
    if (ids.has(page.id)) throw new Error('Duplicate capture id');
    ids.add(page.id);
    if (page.kind === 'entra-app') {
      if (!GUID.test(page.appId ?? '')) throw new Error('A discovered app id is required');
    } else makePortalUrl(plan.tenantId, page.resourceId, page.blade);
    if (!page.title || !page.expect) throw new Error('Capture needs a title and a visible blade expectation');
  }
  return true;
}

export function redactText(value, replacements) {
  let result = String(value ?? '');
  for (const { from, to } of [...replacements].filter(pair => pair.from?.length > 2)
    .sort((a, b) => b.from.length - a.from.length)) {
    result = result.replace(new RegExp(from.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'gi'), () => to);
  }
  result = result
    .replace(/\bMicrosoft \([^)\r\n]+\)/g, 'Microsoft (Contoso application)')
    .replace(/\b[a-z0-9.-]+\.onmicrosoft\.com\b/gi, 'contoso.onmicrosoft.com')
    .replace(/[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}/gi, '00000000-0000-0000-0000-000000000000')
    .replace(/\b[0-9a-f]{24,64}\b/gi, '[id redacted]')
    .replace(/[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi, 'administrator@contoso.com')
    .replace(/\b(?:\d{1,3}\.){3}\d{1,3}\b/g, '10.0.0.0')
    .replace(/\b(?!portal\.|ms\.portal\.|management\.|login\.|api\.|privatelink\.)[a-z0-9-]+(?:\.[a-z0-9-]+)*\.(azure-api\.net|azurewebsites\.net|azurecomm\.net|documents\.azure\.com|communication\.azure\.com|blob\.core\.windows\.net|postgres\.database\.azure\.com|servicebus\.windows\.net|services\.ai\.azure\.com|cognitiveservices\.azure\.com)\b/gi,
      (_, suffix) => `contoso.${suffix}`)
    .replace(/\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/g, '[token redacted]');
  return result;
}

export function isSignInPage(url, text) {
  return /https:\/\/(?:login\.microsoftonline\.com|login\.live\.com)\//i.test(url) ||
    /Pick an account|Enter password|Sign in to your account|Stay signed in\?/i.test(text);
}

export function isBladeReady(text, expected, content) {
  return text.includes(expected) && text.includes(content) &&
    !/Error loading|You don't have access|Resource not found/i.test(text);
}

export function publicCaptureReceipt(result) {
  return Object.fromEntries(['id', 'title', 'status', 'image', 'sha256', 'capturedUtc']
    .filter(key => result[key] !== undefined).map(key => [key, result[key]]));
}
