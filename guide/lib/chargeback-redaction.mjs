import { resolve } from 'node:path';
import sharp from 'sharp';

export function validateCaptureProfile(root, profile) {
  const expected = resolve(root, '.pw-profile');
  if (resolve(profile).toLowerCase() !== expected.toLowerCase()) throw new Error('Only the copied .pw-profile inside this worktree may be opened.');
  return expected;
}

export function reportRedactions(inventory) {
  const pairs = [
    [inventory.SubscriptionId, '<subscription-id>'], [inventory.TenantId, '<tenant-id>'],
    [inventory.SubscriptionName, 'Contoso subscription'], [inventory.TenantName, 'Contoso'],
    [inventory.TenantDomain, 'contoso.onmicrosoft.com'], [inventory.ResourceGroup, 'rg-contoso'],
    [inventory.ApimName, 'apim-contoso'], [inventory.OperatorName, 'Contoso administrator'],
    [inventory.OperatorAddress, 'alice@contoso.com'],
    [inventory.WorkspaceResourceId?.split('/').at(-1), 'log-contoso'],
  ];
  const names = {
    'microsoft.storage/storageaccounts': 'streportscontoso',
    'microsoft.communication/communicationservices': 'acs-reports-contoso',
    'microsoft.communication/emailservices': 'email-reports-contoso',
    'microsoft.network/virtualnetworks': 'vnet-reports-contoso',
    'microsoft.network/privateendpoints': 'pe-reports-contoso',
    'microsoft.network/networkinterfaces': 'nic-reports-contoso',
    'microsoft.app/managedenvironments': 'cae-reports-contoso',
  };
  for (const resource of inventory.Resources ?? []) {
    const type = resource.type.toLowerCase();
    const suffix = resource.name.match(/^id-reports-([a-z0-9]{10})$/i);
    if (type === 'microsoft.managedidentity/userassignedidentities' && suffix) pairs.push([suffix[1], 'contoso']);
    let replacement = names[type];
    if (type === 'microsoft.app/jobs') replacement = resource.name.includes('admin') ? 'job-reports-admin-contoso' : /mail|dispatch/.test(resource.name) ? 'job-reports-mail-contoso' : 'job-reports-contoso';
    if (type === 'microsoft.managedidentity/userassignedidentities') replacement = resource.name.includes('admin') ? 'id-reports-admin-contoso' : 'id-reports-contoso';
    if (replacement) pairs.push([resource.name, replacement]);
  }
  pairs.push(...(inventory.Redactions ?? []));
  return pairs.filter(([raw, substitute]) => raw && raw !== substitute).sort((a, b) => b[0].length - a[0].length);
}

export function redactReportText(text, pairs) {
  let value = String(text);
  for (const [raw, replacement] of pairs) value = value.replaceAll(new RegExp(raw.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'gi'), () => replacement);
  return value.replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi, '<object-id>')
    .replace(/[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi, 'alice@contoso.com')
    .replace(/\b(?:\d{1,3}\.){3}\d{1,3}\b/g, '<private-ip>');
}

export function assertRedacted(text, pairs) {
  for (const [raw] of pairs) if (String(text).toLowerCase().includes(raw.toLowerCase())) throw new Error('Known unredacted deployment/identity value remains; screenshot refused.');
  if (/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i.test(text)) throw new Error('An unredacted identifier remains.');
  const emails = String(text).match(/[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi) ?? [];
  if (emails.some(address => address.toLowerCase() !== 'alice@contoso.com')) throw new Error('An unredacted email address remains.');
}

export async function redactPortalPage(page, pairs) {
  for (const frame of page.frames()) {
    await frame.evaluate(({ replacements }) => {
      const clean = value => {
        let result = String(value);
        for (const [raw, replacement] of replacements) result = result.replaceAll(new RegExp(raw.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'gi'), () => replacement);
        return result.replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi, '<object-id>')
          .replace(/[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi, 'alice@contoso.com')
          .replace(/\b(?:\d{1,3}\.){3}\d{1,3}\b/g, '<private-ip>');
      };
      const scrub = () => {
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        while (walker.nextNode()) {
          const node = walker.currentNode;
          if (['SCRIPT', 'STYLE'].includes(node.parentElement?.tagName)) continue;
          const value = clean(node.nodeValue);
          if (value !== node.nodeValue) node.nodeValue = value;
        }
        for (const element of document.querySelectorAll('input,textarea')) {
          if (element.type === 'password') { element.value = ''; continue; }
          const value = clean(element.value);
          if (value !== element.value) element.value = value;
        }
        for (const element of document.querySelectorAll('[title],[aria-label]')) {
          for (const key of ['title', 'aria-label']) {
            const original = element.getAttribute(key);
            if (original && clean(original) !== original) element.setAttribute(key, clean(original));
          }
        }
        for (const element of document.querySelectorAll('[class*="avatar" i], [class*="persona-coin" i], img[alt*="profile" i]')) element.style.visibility = 'hidden';
      };
      scrub();
      window.__chargebackRedactionTimer = setInterval(scrub, 200);
    }, { replacements: pairs });
  }
  await page.evaluate(() => {
    const chip = document.createElement('div');
    chip.textContent = 'Contoso administrator  |  CONTOSO';
    chip.style.cssText = 'position:fixed;right:0;top:0;width:440px;height:48px;background:#fff;color:#242424;z-index:2147483647;font:14px Segoe UI,Arial;display:flex;align-items:center;justify-content:center';
    document.body.append(chip);
  });
  await page.waitForTimeout(350);
  for (const frame of page.frames()) {
    assertRedacted(await frame.locator('body').innerText(), pairs);
    const values = await frame.locator('input,textarea').evaluateAll(elements => elements.map(element => element.value).join('\n'));
    assertRedacted(values, pairs);
  }
}

export async function saveRedactedScreenshot(page, path, caption = 'Live Azure portal - identifiers and identities replaced with Contoso placeholders', fullPage = false) {
  const pixels = await page.screenshot({ fullPage });
  const { width, height } = await sharp(pixels).metadata();
  const label = caption.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
  const footer = Buffer.from(`<svg width="${width}" height="30"><rect width="100%" height="100%" fill="white"/><text x="16" y="20" font-family="Segoe UI,Arial" font-size="12" fill="#242424">${label}</text></svg>`);
  await sharp(pixels).extend({ bottom: 30, background: '#ffffff' }).composite([{ input: footer, left: 0, top: height }]).png().toFile(path);
}
