/**
 * Renders the request and telemetry path as a diagram.
 *
 * Deterministic HTML rather than a generated image: the value of this picture
 * is that the resource names and header names on it are the real ones, and an
 * image model cannot be relied on to spell ApiManagementGatewayLlmLog. The
 * layout is the six-hop flow; the labels come from what is actually deployed,
 * checked against scripts/Get-ClaudeBom.ps1.
 *
 *   node guide/render-architecture.mjs
 */
import { chromium } from 'playwright';
import { mkdir } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const outDir = join(here, '..', 'docs', 'images');

const hops = [
  { n: 1, title: 'Sign in',   what: 'The developer already has an Entra token. No API key exists to leak or rotate.',
    res: 'Microsoft Entra ID', sub: 'oid carried on every call', tone: 'a' },
  { n: 2, title: 'Admit',     what: 'Entitlement, tier, business unit and four budgets are checked before anything is called.',
    res: 'API Management BasicV2', sub: 'policy.xml', tone: 'b' },
  { n: 3, title: 'Serve',     what: 'The gateway swaps in its managed identity and calls your own Foundry deployment.',
    res: 'Claude on Foundry', sub: 'your account, your agreement', tone: 'c' },
  { n: 4, title: 'Meter',     what: 'Every call is logged with tokens, model, latency and whether it streamed.',
    res: 'ApiManagementGatewayLlmLog', sub: 'built in, no exporter', tone: 'd' },
  { n: 5, title: 'Attribute', what: 'A trace carries who, which unit and which client, joined to the log on request id.',
    res: 'AppTraces', sub: 'user, tier, unit, client', tone: 'e' },
  { n: 6, title: 'Observe',   what: 'Spend by business unit, team, developer and client — with the caveats on the pane.',
    res: 'Workbook + saved functions', sub: 'ClaudeChargeback()', tone: 'f' },
];

const budgets = [
  ['per minute', 'tokens-per-minute, by tier'],
  ['per day', 'quota-standard / quota-premium, per developer'],
  ['per month', 'the team, then the business unit above it'],
  ['organisation', 'quota-org, one shared counter'],
];

const html = `<!doctype html><html><head><meta charset="utf-8"><style>
  :root{--a:#6264a7;--b:#0078d4;--c:#c2410c;--d:#0f766e;--e:#7c3aed;--f:#1e3a5f}
  *{box-sizing:border-box}
  body{margin:0;font:15px/1.5 "Segoe UI",system-ui,sans-serif;color:#1b1b1b;background:#fff}
  .sheet{width:1680px;padding:44px 48px 40px}
  h1{font-size:30px;margin:0 0 4px;letter-spacing:-.4px}
  .sub{color:#5b5b5b;margin:0 0 28px;font-size:16px}
  .row{display:flex;gap:12px;align-items:stretch}
  .hop{flex:1;border:1px solid #e3e3e3;border-radius:12px;padding:16px 16px 14px;position:relative;background:#fff}
  .hop:before{content:"";position:absolute;left:0;top:0;bottom:0;width:4px;border-radius:12px 0 0 12px}
  .hop.a:before{background:var(--a)} .hop.b:before{background:var(--b)} .hop.c:before{background:var(--c)}
  .hop.d:before{background:var(--d)} .hop.e:before{background:var(--e)} .hop.f:before{background:var(--f)}
  .num{display:inline-flex;width:24px;height:24px;border-radius:50%;color:#fff;font-size:13px;font-weight:600;
       align-items:center;justify-content:center;margin-right:8px}
  .a .num{background:var(--a)} .b .num{background:var(--b)} .c .num{background:var(--c)}
  .d .num{background:var(--d)} .e .num{background:var(--e)} .f .num{background:var(--f)}
  .ttl{font-weight:600;font-size:17px;margin-bottom:8px;display:flex;align-items:center}
  .what{font-size:13.5px;color:#3c3c3c;min-height:76px}
  .res{margin-top:10px;padding:8px 10px;border-radius:7px;background:#f6f7f9;font-size:12.5px;font-weight:600}
  .res span{display:block;font-weight:400;color:#6a6a6a;margin-top:2px}
  .arrow{align-self:center;color:#c9c9c9;font-size:20px}
  .band{margin-top:22px;border:1px solid #e3e3e3;border-radius:12px;padding:16px 20px;background:#fafbfc;
        display:flex;gap:28px;align-items:flex-start}
  .band h3{margin:0 0 6px;font-size:15px}
  .band .cap{font-size:13px;color:#4a4a4a}
  .bud{display:flex;gap:10px;flex:1;flex-wrap:wrap}
  .b1{border:1px solid #e0e0e0;border-radius:8px;padding:7px 11px;background:#fff;font-size:12.5px}
  .b1 b{display:block;font-size:12.5px}
  .b1 span{color:#6a6a6a}
  .foot{margin-top:20px;display:flex;gap:30px;font-size:12.5px;color:#5b5b5b}
  .foot div{flex:1}
  .foot b{color:#1b1b1b}
  .warn{margin-top:16px;border-left:4px solid #b45309;background:#fffbeb;padding:10px 14px;font-size:13px;border-radius:0 8px 8px 0}
</style></head><body><div class="sheet">
  <h1>One request, six governed hops</h1>
  <p class="sub">Claude Code, the VS Code extension and Claude Desktop all take this path. Nothing reaches Foundry without passing every gate.</p>
  <div class="row">
    ${hops.map((h, i) => `
      <div class="hop ${h.tone}">
        <div class="ttl"><span class="num">${h.n}</span>${h.title}</div>
        <div class="what">${h.what}</div>
        <div class="res">${h.res}<span>${h.sub}</span></div>
      </div>
      ${i < hops.length - 1 ? '<div class="arrow">&#8594;</div>' : ''}`).join('')}
  </div>

  <div class="band">
    <div style="min-width:190px">
      <h3>Four budgets, one request</h3>
      <div class="cap">Checked at hop 2, in this order. The refusal names which one ran out.</div>
    </div>
    <div class="bud">
      ${budgets.map(([a, b]) => `<div class="b1"><b>${a}</b><span>${b}</span></div>`).join('')}
    </div>
  </div>

  <div class="foot">
    <div><b>What it costs.</b> One API Management instance, plus Application Insights and Log Analytics by volume. The workbook and saved functions are definitions and bill nothing. Foundry is yours already.</div>
    <div><b>What it does not add.</b> No always-on processor, no database, no queue. Chargeback is the built-in LLM log joined to a trace the gateway already emits.</div>
    <div><b>Closed loop.</b> What hop 6 shows is enforced at hop 2 on the next call — budgets and entitlement are named values, read per request with no redeploy.</div>
  </div>

  <div class="warn"><b>The one figure to read carefully.</b> The budget counter counts prompt and completion only. Measured over thirty days, cache reads were 38.7% of real cost weight, so spend is always higher than a budget suggests — never lower.</div>
</div></body></html>`;

await mkdir(outDir, { recursive: true });
const browser = await chromium.launch();
const page = await browser.newPage({ deviceScaleFactor: 2 });
await page.setContent(html);
const sheet = await page.locator('.sheet');
await sheet.screenshot({ path: join(outDir, 'request-flow.png') });
await browser.close();
console.log('  wrote docs/images/request-flow.png');
