// Executed inside a visible capture frame. Authentication values and hidden
// application state are never rewritten; sensitive input pixels get an overlay.
export function redactVisibleDocument(pairs) {
  if (!document.body) return;
  const redact = window.__architectureRedactText;
  if (typeof redact !== 'function') throw new Error('Redaction is not installed');
  window.__architectureObserver?.disconnect();
  const visible = element => {
    if (!element || element.closest('script,style,noscript,[hidden],[aria-hidden=true]')) return false;
    const style = getComputedStyle(element);
    return element.getClientRects().length > 0 && style.visibility !== 'hidden' && style.opacity !== '0';
  };
  const scrub = () => {
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    let node;
    while ((node = walker.nextNode())) {
      if (!visible(node.parentElement) || node.parentElement.closest('[data-architecture-overlay],textarea,select,option')) continue;
      const safe = redact(node.nodeValue, pairs);
      if (safe !== node.nodeValue) node.nodeValue = safe;
    }
    for (const element of document.querySelectorAll('input,textarea,select')) {
      if (!visible(element) || ['hidden', 'password'].includes(element.type) || element.dataset.architectureMasked) continue;
      const display = element instanceof HTMLSelectElement ? element.selectedOptions[0]?.textContent ?? '' : element.value;
      const safe = redact(display, pairs);
      if (safe === display) continue;
      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      const overlay = document.createElement('div');
      overlay.dataset.architectureOverlay = 'true';
      overlay.textContent = safe;
      Object.assign(overlay.style, {
        position: 'fixed', left: `${rect.left}px`, top: `${rect.top}px`, width: `${rect.width}px`, height: `${rect.height}px`,
        background: '#fff', color: '#292827', font: style.font, padding: style.padding,
        border: '1px solid #8a8886', boxSizing: 'border-box', overflow: 'hidden',
        pointerEvents: 'none', zIndex: '2147483647',
      });
      element.dataset.architectureMasked = 'true';
      document.body.append(overlay);
    }
  };
  scrub();
  const observer = new MutationObserver(() => {
    observer.disconnect();
    scrub();
    observer.observe(document.body, { subtree: true, childList: true, characterData: true });
  });
  observer.observe(document.body, { subtree: true, childList: true, characterData: true });
  window.__architectureObserver = observer;
}
