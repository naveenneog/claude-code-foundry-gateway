import { labelText } from './architecture-model.mjs';

const escape = value => String(value ?? '').replace(/[&<>"']/g, character =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[character]);
const box = item => `left:${item.x}px;top:${item.y}px;width:${item.w}px;height:${item.h}px`;
const color = { data: '#1764a1', control: '#7253a0', identity: '#127268' };

function content(spec, value) {
  return escape(value).replace(/\[\[([a-z0-9-]+)\]\]/g, (_, key) =>
    `<code>${escape(labelText(spec, `[[${key}]]`)).replace(/([a-z0-9])([A-Z])/g, '$1<wbr>$2')}</code>`);
}

function flow(spec) {
  const edges = (spec.edges ?? []).map(edge => {
    const points = edge.points.map(point => point.join(',')).join(' ');
    const label = edge.label ? `<div class="edge-label ${edge.kind}" style="left:${edge.labelAt[0]}px;top:${edge.labelAt[1]}px">${content(spec, edge.label)}</div>` : '';
    return {
      line: `<polyline points="${points}" stroke="${color[edge.kind]}" stroke-dasharray="${edge.kind === 'control' ? '9 5' : edge.kind === 'identity' ? '3 5' : ''}" marker-end="url(#arrow-${edge.kind})"/>`,
      label,
    };
  });
  return `<div class="canvas" style="height:${spec.height}px">
    ${(spec.groups ?? []).map(group => `<section class="boundary ${group.tone ?? 'slate'}" style="${box(group)}">
      <div class="boundary-title">${content(spec, group.title)}</div>
      ${group.subtitle ? `<div class="boundary-subtitle">${content(spec, group.subtitle)}</div>` : ''}
    </section>`).join('')}
    <svg class="connections" width="${spec.width}" height="${spec.height}" aria-hidden="true">
      <defs>${Object.entries(color).map(([kind, stroke]) => `<marker id="arrow-${kind}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse"><path d="M 0 0 L 10 5 L 0 10 z" fill="${stroke}"/></marker>`).join('')}</defs>
      <g fill="none" stroke-width="2.5" stroke-linejoin="round">${edges.map(edge => edge.line).join('')}</g>
    </svg>
    ${(spec.nodes ?? []).map(node => `<section class="node ${node.tone ?? 'slate'} ${node.compact ? 'compact' : ''}" style="${box(node)}" data-fit="${escape(node.id)}">
      ${node.eyebrow ? `<div class="eyebrow">${content(spec, node.eyebrow)}</div>` : ''}
      <h2>${content(spec, node.title)}</h2>
      ${(node.lines ?? []).map(line => `<p>${content(spec, line)}</p>`).join('')}
    </section>`).join('')}
    ${edges.map(edge => edge.label).join('')}
  </div>`;
}

function inventory(spec) {
  return `<div class="inventory">${spec.sections.map(section => `<section>
    <h2>${content(spec, section.title)}</h2><p>${content(spec, section.note)}</p>
    <ul>${section.types.map(type => `<li><code>${escape(type)}</code></li>`).join('')}</ul>
  </section>`).join('')}</div>`;
}

export function diagramHtml(spec) {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8">
  <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:">
  <title>${escape(spec.title)}</title><style>
    *{box-sizing:border-box}
    body{margin:0;color:#172f46;background:#fff;font:19px/1.4 "Segoe UI",Arial,sans-serif}
    .sheet{width:${spec.width + 64}px;padding:28px 32px 24px;background:#fff}
    header{border-top:5px solid #1764a1;padding-top:17px;margin-bottom:20px}
    .series{font-size:14px;letter-spacing:1.8px;font-weight:700;text-transform:uppercase;color:#506578}
    h1{font-size:34px;line-height:1.16;font-weight:650;letter-spacing:-.6px;margin:8px 0}
    .subtitle{margin:0;color:#435a6c;font-size:18px;max-width:1240px}
    .canvas{position:relative}
    .boundary{position:absolute;border:1.5px dashed var(--border);border-radius:10px;background:var(--wash)}
    .boundary-title{position:absolute;top:12px;left:16px;font-size:17px;font-weight:700;color:var(--ink)}
    .boundary-subtitle{position:absolute;top:38px;left:16px;font-size:15px;color:#486071}
    .connections{position:absolute;inset:0;overflow:visible}
    .node{position:absolute;padding:17px 18px;border:1.5px solid var(--border);border-top:4px solid var(--ink);border-radius:8px;background:white;overflow:visible}
    .node h2{font-size:21px;line-height:1.25;font-weight:650;letter-spacing:-.25px;margin:0 0 10px;color:var(--ink)}
    .node p{font-size:18px;line-height:1.35;margin:7px 0 0;color:#263f52}
    .node .eyebrow{font-size:13px;line-height:1.3;letter-spacing:1px;font-weight:750;color:var(--ink);text-transform:uppercase;margin-bottom:6px}
    .compact{padding:12px 15px}
    .compact h2{font-size:20px;margin-bottom:6px}
    .compact p{font-size:17px;line-height:1.3;margin-top:5px}
    code{font:0.91em/1.4 Consolas,"Liberation Mono",monospace;overflow-wrap:anywhere;font-variant-ligatures:none}
    .edge-label{position:absolute;transform:translate(-50%,-50%);padding:2px 6px;background:#fff;font-size:14px;font-weight:650;line-height:1.3;white-space:nowrap;border-radius:3px}
    .edge-label.data{color:#175c92}.edge-label.control{color:#68488f}.edge-label.identity{color:#11675f}
    .blue{--ink:#1764a1;--border:#a9c7df;--wash:#f2f7fb}
    .teal{--ink:#127268;--border:#a0cfc7;--wash:#f0f8f6}
    .purple{--ink:#7253a0;--border:#c7b5df;--wash:#f6f3fa}
    .amber{--ink:#94570e;--border:#dfc291;--wash:#fff9ee}
    .slate{--ink:#3d566d;--border:#bbcad7;--wash:#f5f7f9}
    .legend{display:flex;gap:27px;align-items:center;border-top:1px solid #cad6e0;margin-top:20px;padding-top:14px;font-size:14px;color:#40586c}
    .legend span{display:flex;gap:8px;align-items:center}
    .key{display:inline-block;width:32px;border-top:3px solid #1764a1}
    .key.control{border-color:#7253a0;border-top-style:dashed}
    .key.identity{border-color:#127268;border-top-style:dotted}
    .key.bound{width:22px;height:15px;border:1.5px dashed #9dafbe;background:#f5f7f9}
    .notice{margin-top:15px;padding:12px 16px;background:#fff9ee;border-left:4px solid #94570e;font-size:17px;color:#684112}
    footer{margin-top:13px;font-size:13px;color:#506578;display:flex;justify-content:space-between}
    .inventory section{padding:14px 18px;border:1px solid #cad6e0;border-left:4px solid #1764a1;margin-bottom:14px;border-radius:5px}
    .inventory h2{margin:0 0 4px;font-size:23px}
    .inventory p{margin:0 0 8px;font-size:17px;color:#435a6c}
    .inventory ul{margin:0;padding:0;list-style:none;columns:1}
    .inventory li{padding:5px 0;border-top:1px solid #e6edf3;font-size:18px}
  </style></head><body><main class="sheet">
    <header><div class="series">Claude on Microsoft Foundry · architecture</div>
      <h1>${content(spec, spec.title)}</h1><p class="subtitle">${content(spec, spec.subtitle)}</p>
    </header>
    ${spec.kind === 'inventory' ? inventory(spec) : flow(spec)}
    <div class="legend">
      <span><i class="key"></i>Request / data</span>
      <span><i class="key control"></i>Configuration / governance</span>
      <span><i class="key identity"></i>Identity / token</span>
      <span><i class="key bound"></i>Trust / network boundary</span>
    </div>
    ${spec.notice ? `<div class="notice">${content(spec, spec.notice)}</div>` : ''}
    <footer><span>Customer-owned deployment · generic resource names · no tenant data</span><span>Source: ${escape(spec.file)}</span></footer>
  </main></body></html>`;
}
