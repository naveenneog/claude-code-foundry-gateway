/**
 * Applies the guide's banner + highlight treatment to screenshots that were
 * already captured and verified, so the whole guide looks like one document
 * regardless of which tool produced each image.
 *
 * These sources are static files rather than live pages, so highlight boxes
 * are expressed as fractions of the image. That keeps a spec correct even if a
 * source is recaptured at a different resolution.
 *
 * Identity redaction is off here because every source listed below was already
 * captured from a scrubbed profile and reviewed; re-masking would cover the
 * placeholder text that is already in the image.
 */
import path from 'node:path';
import fs from 'node:fs';
import { annotate } from './lib/annotate.mjs';

const OUT = path.resolve('docs/guide');

const ITEMS = [
  {
    src: 'docs/deck/portal-apim.png',
    out: 'a3-apim-overview.png',
    banner: { n: 3, title: 'Confirm the gateway tier', note: 'Must be a v2 SKU — classic tiers report zero Anthropic tokens' },
    // The capture includes the browser tab strip and the real subscription
    // identifiers; neither belongs in a published guide.
    masks: [
      { x: 0.0, y: 0.005, w: 0.090, h: 0.995 },
      { x: 0.373, y: 0.397, w: 0.150, h: 0.025, text: 'your-subscription', align: 'start' },
      { x: 0.373, y: 0.434, w: 0.192, h: 0.024, text: '00000000-0000-0000-0000-000000000000', align: 'start' },
    ],
    highlights: [
      { x: 0.642, y: 0.357, w: 0.125, h: 0.026, n: 'a' },
      { x: 0.394, y: 0.629, w: 0.040, h: 0.026, n: 'b' },
    ],
  },
  {
    src: 'docs/images/portal-01-overview.png',
    out: 'a5-foundry.png',
    banner: { n: 5, title: 'Open the Foundry account behind the gateway', note: 'Access control (IAM) is where the gateway identity gets its role' },
    highlights: [{ x: 0.013, y: 0.323, w: 0.130, h: 0.029 }],
  },
  {
    src: 'docs/deck/portal-budgets.png',
    out: 'a6-named-values.png',
    banner: { n: 6, title: 'Set the per-developer budgets', note: 'tpm-* per minute, quota-* per day, allow-* entitled object ids' },
    highlights: [
      { x: 0.187, y: 0.696, w: 0.197, h: 0.083, n: 'a' },
      { x: 0.187, y: 0.519, w: 0.197, h: 0.083, n: 'b' },
      { x: 0.187, y: 0.362, w: 0.197, h: 0.083, n: 'c' },
    ],
  },
  {
    src: 'docs/images/gw-01-governance.png',
    out: 'a7-controls.png',
    banner: { n: 7, title: 'Verify the controls end to end', note: './gateway/Show-Governance.ps1' },
    // The script prints the real caller UPNs. Cover them so the guide can be
    // published and reused by other tenants.
    masks: [
      { x: 0.079, y: 0.198, w: 0.382, h: 0.027, text: 'dev-standard@contoso.com', align: 'start' },
      { x: 0.083, y: 0.626, w: 0.190, h: 0.027, text: 'dev-standard@contoso.com', align: 'start' },
    ],
  },
  {
    src: 'docs/deck/portal-metrics.png',
    out: 'a8-chargeback.png',
    banner: { n: 8, title: 'Chargeback in Application Insights', note: 'Namespace claudecode → Total Tokens → Apply splitting → User' },
    highlights: [
      { x: 0.190, y: 0.343, w: 0.182, h: 0.046, n: 'a' },
      { x: 0.375, y: 0.330, w: 0.300, h: 0.074, n: 'b' },
    ],
  },
  {
    src: 'docs/images/ext-01-panel.png',
    out: 'b2-vscode-panel.png',
    banner: { n: 12, title: 'The extension talking to your gateway', note: 'No API key anywhere on the machine' },
  },
  {
    src: 'docs/images/ext-02-answer.png',
    out: 'b3-vscode-answer.png',
    banner: { n: 13, title: 'A real answer from your own deployment', note: 'Served by claude-sonnet-5 in your Foundry resource' },
  },
  {
    src: 'docs/images/cli-01-verify.png',
    out: 'b4-cli-verify.png',
    banner: { n: 14, title: 'Verify the direct Foundry path', note: './Test-ClaudeFoundry.ps1 — 7 checks, no gateway involved' },
    masks: [
      { x: 0.080, y: 0.279, w: 0.450, h: 0.033, text: 'dev@contoso.com / your-subscription', align: 'start' },
    ],
  },
  {
    src: 'docs/images/cli-02-status.png',
    out: 'b5-cli-status.png',
    banner: { n: 15, title: 'claude /status confirms which provider is in effect', note: 'Terminal only — /status is not available in the VS Code panel' },
  },
];

fs.mkdirSync(OUT, { recursive: true });

let ok = 0;
for (const item of ITEMS) {
  const src = path.resolve(item.src);
  if (!fs.existsSync(src)) {
    console.log(`miss ${item.src}`);
    continue;
  }
  console.log(`comp ${item.out}`);
  await annotate(fs.readFileSync(src), path.join(OUT, item.out), {
    banner: item.banner,
    highlights: item.highlights ?? [],
    masks: item.masks ?? [],
    maskIdentity: false,
  });
  ok++;
}

console.log('');
console.log(`composed ${ok}/${ITEMS.length}`);
