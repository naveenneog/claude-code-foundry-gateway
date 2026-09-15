// Renders real terminal output into the screenshots used by the business unit
// guide.
//
//   node guide/render-terminal.mjs
//
// Why render rather than photograph
// ---------------------------------
// guide/redact-terminal.mjs handles screenshots taken by hand: it paints over
// regions of a captured PNG, and the coordinates have to be recalibrated per
// image. That works for the installer, whose output is a wizard nobody can
// reproduce on demand.
//
// The business unit commands are different. Their output is short, deterministic
// and reproducible, so the honest thing is to keep the text - which is genuine
// output from live runs against the reference gateway - and render it, rather
// than crop a photograph of a window.
//
// Nothing is invented here. Every line below was produced by running the command
// shown against apim-claude-gw-fzgql9. The only edits are the identifier
// substitutions in REDACTIONS, which replace real tenant identities with
// example ones. Keeping those in one table means a reviewer can see exactly what
// was changed.

import { chromium } from 'playwright';
import { mkdir } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const outDir = join(here, '..', 'docs', 'guide');

// Real identity -> what appears in the documentation. Applied to every line.
const REDACTIONS = [
  [/navg_microsoft\.com#EXT#@fdpo\.onmicrosoft\.com/g, 'amara.okafor_contoso.com#EXT#@contoso.onmicrosoft.com'],
  [/abpatra_microsoft\.com#EXT#@fdpo\.onmicrosoft\.com/g, 'jonas.weber_contoso.com#EXT#@contoso.onmicrosoft.com'],
  [/rajatsr_microsoft\.com#EXT#@fdpo\.onmicrosoft\.com/g, 'mei.tanaka_contoso.com#EXT#@contoso.onmicrosoft.com'],
  [/43cc5304-b62c-48c4-a49e-427d621c19a9/g, '7f2a1c94-3e5b-4d81-9a06-b1e4c8d72f35'],
  [/1018f813-18ba-4c7f-9bfa-362913e4befa/g, 'c4d8e017-6b92-41af-8e73-2fa9d35c6081'],
  [/5ca49aa0-68ef-4c77-8e45-1ca39f35ac98/g, 'a91b6f23-58d4-4c07-b6e2-93f7a5c1d840'],
  [/apim-claude-gw-fzgql9/g, 'apim-claude-gateway'],
  [/rg-contosohub/g, 'rg-claude-gateway'],
];

const redact = (s) => REDACTIONS.reduce((acc, [from, to]) => acc.replace(from, to), s);

// Minimal ANSI-ish colouring, applied by matching the line rather than by
// capturing escape codes, because PowerShell's Write-Host colours do not survive
// redirection to a string.
function colourise(line) {
  const esc = line
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');

  if (/^PS [A-Z]:/.test(line)) return `<span class="prompt">${esc}</span>`;
  if (/^\s*\[OK\]/.test(line)) return `<span class="ok">${esc}</span>`;
  if (/^\s*\[FAIL\]|^WARNING:/.test(line)) return `<span class="warn">${esc}</span>`;
  if (/^(Business units on|Syncing Entra|Business unit membership)/.test(line)) return `<span class="head">${esc}</span>`;
  if (/^\s*-{10,}/.test(line)) return `<span class="dim">${esc}</span>`;
  if (/(created|updated|removed|mapped to a business unit|identity\(ies\) authorised)/.test(line)) return `<span class="ok">${esc}</span>`;
  if (/(List price|Dollar figures|Figures are|Their usage|Set bu-unassigned|Membership comes|business unit\(s\) before|not reconciled|than shown)/.test(line)) return `<span class="dim">${esc}</span>`;
  if (/Unassigned developers/.test(line)) return `<span class="warn">${esc}</span>`;
  return esc;
}

function html(title, body) {
  const lines = redact(body).replace(/\r/g, '').split('\n');
  while (lines.length && !lines[lines.length - 1].trim()) lines.pop();
  const cols = Math.max(84, ...lines.map((l) => l.length)) + 2;

  return `<!doctype html><html><head><meta charset="utf-8"><style>
    * { box-sizing: border-box; }
    body { margin: 0; background: #11131a; font-family: "Cascadia Mono", Consolas, monospace; }
    .frame { width: ${cols}ch; padding: 0; }
    .bar { background: #21242e; padding: 9px 14px; display: flex; align-items: center; gap: 8px;
           border-radius: 8px 8px 0 0; }
    .dot { width: 11px; height: 11px; border-radius: 50%; }
    .r { background: #ec6a5e; } .y { background: #f4bf4f; } .g { background: #61c554; }
    .title { color: #9aa3b8; font-size: 12.5px; margin-left: 8px; }
    pre { margin: 0; padding: 16px 18px 20px; color: #d6dae4; font-size: 13.5px;
          line-height: 1.52; white-space: pre; background: #11131a; border-radius: 0 0 8px 8px; }
    .prompt { color: #7aa2f7; } .ok { color: #86c98b; } .warn { color: #e8c07d; }
    .head { color: #7dcfff; } .dim { color: #7f889c; }
  </style></head><body>
    <div class="frame">
      <div class="bar"><span class="dot r"></span><span class="dot y"></span><span class="dot g"></span>
        <span class="title">${title}</span></div>
      <pre>${lines.map(colourise).join('\n')}</pre>
    </div></body></html>`;
}

// Captured from live runs on 2026-09-15.
const shots = [
  {
    file: 'bu-1-add.png',
    title: 'Adding a business unit',
    body: `PS C:\\claude-gateway> ./scripts/Set-ClaudeBusinessUnit.ps1 -Id platform \`
>>     -Group "claude-code-standard" -MonthlyBudgetUsd 5000

  platform created
  $5,000/month -> 1,388,888,888 tokens, at a blended $3.6/M for claude-sonnet-5 assuming 20% output.
  List price, price book 2026-09-15. The quota counter excludes cached tokens.
  0 business unit(s) before, 1 after. Others untouched.

  Membership comes from the Entra group. Run the sync to pick it up:
    ./scripts/Sync-ClaudeAccess.ps1 -ApimName apim-claude-gw-fzgql9 -ResourceGroup rg-contosohub`,
  },
  {
    file: 'bu-2-list.png',
    title: 'Listing business units',
    body: `PS C:\\claude-gateway> ./scripts/Set-ClaudeBusinessUnit.ps1 -List

Business units on apim-claude-gw-fzgql9

  Id               Entra group                          Tokens/month   approx USD
  --------------------------------------------------------------------------------
  platform         claude-code-standard                1,388,888,888       $5,000
  research         claude-code-premium                 3,333,333,333      $12,000

  Dollar figures are list price and exclude cached tokens. See docs/BUSINESS-UNITS.md.`,
  },
  {
    file: 'bu-3-change-budget.png',
    title: 'Changing a budget',
    body: `PS C:\\claude-gateway> ./scripts/Set-ClaudeBusinessUnit.ps1 -Id platform -MonthlyBudgetUsd 8000

  platform updated (was claude-code-standard, 1,388,888,888 tokens/month)
  $8,000/month -> 2,222,222,222 tokens, at a blended $3.6/M for claude-sonnet-5 assuming 20% output.
  List price, price book 2026-09-15. The quota counter excludes cached tokens.
  2 business unit(s) before, 2 after. Others untouched.`,
  },
  {
    file: 'bu-4-sync.png',
    title: 'Syncing membership from Entra',
    body: `PS C:\\claude-gateway> ./scripts/Sync-ClaudeAccess.ps1

Syncing Entra group membership -> APIM named values
  APIM : apim-claude-gw-fzgql9 (rg-contosohub)

claude-code-standard  ->  3 member(s)
  43cc5304-b62c-48c4-a49e-427d621c19a9   navg_microsoft.com#EXT#@fdpo.onmicrosoft.com
  1018f813-18ba-4c7f-9bfa-362913e4befa   abpatra_microsoft.com#EXT#@fdpo.onmicrosoft.com
  5ca49aa0-68ef-4c77-8e45-1ca39f35ac98   rajatsr_microsoft.com#EXT#@fdpo.onmicrosoft.com

Business unit membership
  research         claude-code-premium            0 member(s)
  platform         claude-code-standard           3 member(s)
  3 developer(s) mapped to a business unit.

Done. 3 identity(ies) authorised.
Anyone not listed receives HTTP 403 from the gateway.`,
  },
  {
    file: 'bu-5-report.png',
    title: 'Spend by business unit',
    body: `PS C:\\claude-gateway> ./scripts/Get-ClaudeBusinessUnit.ps1

Business units on apim-claude-gw-fzgql9

  Id             Entra group                Members         Budget           Used  Used %
  --------------------------------------------------------------------------------------------
  research       claude-code-premium              0  3,333,333,333              0      0%
  platform       claude-code-standard             3  2,222,222,222            544      0%

  Unassigned developers: 1  (behaviour: allow)
  Their usage is served and recorded, but counts against no budget.
  Set bu-unassigned to "deny" once every developer has a business unit.

  Figures are at list price and exclude cached tokens, so real spend is higher
  than shown. They are not reconciled to an Azure invoice. See docs/BUSINESS-UNITS.md.`,
  },
  {
    file: 'bu-6-remove.png',
    title: 'Removing a business unit',
    body: `PS C:\\claude-gateway> ./scripts/Set-ClaudeBusinessUnit.ps1 -Id research -Remove

  research removed (was claude-code-premium, 3,333,333,333 tokens/month)
  2 business unit(s) before, 1 after. Others untouched.`,
  },
];

const browser = await chromium.launch();
const page = await browser.newPage({ deviceScaleFactor: 2 });
await mkdir(outDir, { recursive: true });

for (const s of shots) {
  await page.setContent(html(s.title, s.body));
  const frame = await page.locator('.frame');
  await frame.screenshot({ path: join(outDir, s.file) });
  console.log(`  wrote docs/guide/${s.file}`);
}

await browser.close();
console.log(`\n${shots.length} screenshot(s) rendered from live output.`);
