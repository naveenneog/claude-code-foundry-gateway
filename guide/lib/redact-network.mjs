function expandBindings(bindings) {
  const all = [];
  for (const [live, replacement] of bindings) {
    if (!live) continue;
    all.push([live, replacement]);
    if (/^[a-zA-Z][a-zA-Z0-9-]{9,}$/.test(live)) {
      for (let length = 6; length < live.length; length++) {
        all.push([live.slice(0, length) + '...', replacement + '...']);
        all.push([live.slice(0, length) + '\u2026', replacement + '\u2026']);
      }
    }
  }
  return all.sort((a, b) => b[0].length - a[0].length);
}

export function redactNetworkText(value, bindings) {
  let text = String(value);
  for (const [live, replacement] of expandBindings(bindings)) {
    if (live) text = text.split(live).join(replacement);
  }
  return text
    .replace(/\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b/gi, '00000000-0000-0000-0000-000000000000')
    .replace(/\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/gi, 'admin@contoso.com');
}

export async function redactNetworkPage(page, bindings) {
  const ordered = expandBindings(bindings);
  await page.evaluate(({ bindings: replacements }) => {
    const scrub = value => {
      let text = String(value);
      for (const [live, replacement] of replacements) text = text.split(live).join(replacement);
      return text
        .replace(/\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b/gi, '00000000-0000-0000-0000-000000000000')
        .replace(/\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/gi, 'admin@contoso.com');
    };
    const redactNode = root => {
      const nodes = root.nodeType === Node.TEXT_NODE ? [root] : [];
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
      while (walker.nextNode()) nodes.push(walker.currentNode);
      for (const node of nodes) {
        if (['SCRIPT', 'STYLE'].includes(node.parentElement?.tagName)) continue;
        const next = scrub(node.textContent);
        if (next !== node.textContent) node.textContent = next;
      }
      const elements = root.nodeType === Node.ELEMENT_NODE ? [root, ...root.querySelectorAll('input,textarea,[title],[aria-label]')] : [];
      for (const element of elements) {
        if (element.matches('input,textarea')) {
          const next = element.type === 'password' ? '[redacted]' : scrub(element.value);
          if (element.value !== next) element.value = next;
        }
        for (const attribute of ['title', 'aria-label']) {
          if (!element.hasAttribute(attribute)) continue;
          const next = scrub(element.getAttribute(attribute));
          if (element.getAttribute(attribute) !== next) element.setAttribute(attribute, next);
        }
      }
    };
    redactNode(document.body);
    const observer = new MutationObserver(records => {
      for (const record of records) {
        if (record.type === 'childList') for (const node of record.addedNodes) redactNode(node);
        else redactNode(record.target);
      }
    });
    observer.observe(document.body, { subtree: true, childList: true, characterData: true, attributes: true, attributeFilter: ['value', 'title', 'aria-label'] });
    const identity = document.createElement('div');
    identity.setAttribute('data-network-redaction', 'identity');
    identity.style.cssText = 'position:fixed;z-index:2147483646;top:0;right:0;width:480px;height:48px;background:#0078d4;color:white;display:flex;align-items:center;justify-content:flex-end;padding-right:20px;font:14px Segoe UI;';
    identity.textContent = 'Contoso | Administrator';
    document.body.append(identity);
  }, { bindings: ordered });
  const visible = await page.locator('body').innerText();
  const inputs = await page.locator('input,textarea').evaluateAll(elements => elements.map(e => e.value).join('\n'));
  const escaped = ordered.filter(([live, replacement]) => live !== replacement && live.length >= 5 && `${visible}\n${inputs}`.includes(live));
  if (escaped.length) throw new Error(`Redaction failed: ${escaped.length} live values remain. No screenshot was published.`);
}
