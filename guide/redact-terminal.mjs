// Redacts terminal screenshots of the installer before they go into the docs.
//
//   node guide/redact-terminal.mjs <source-dir>
//
// The raw captures contain real tenant ids, subscription names, user principal
// names and, in one case, another team's resource group. They are deliberately
// not committed: only the redacted output in docs/guide/ is. Point this at
// wherever the originals live.
//
// Why a grid rather than hand-placed boxes
// ----------------------------------------
// Terminal output is a fixed character cell, so a redaction is expressed as a
// row and a starting column - the coordinates the text actually has - instead
// of a rectangle dragged by eye. Column numbers come from the format strings in
// Install-ClaudeGateway.ps1, so they can be checked by reading the source
// rather than by squinting at pixels.
//
// The grid is calibrated per image because the screenshots were cropped
// differently. To recalibrate after a new capture, measure the ink extent of
// two rows whose leading whitespace is known:
//
//   cw = (leftB - leftA) / (colB - colA)
//   ox = leftA - colA * cw
//
// Failure modes this has already hit, all fixed here:
//   - a box sized to the ink height left descenders showing beneath it. The
//     tail of a 'g' from a real subscription name survived the first pass.
//   - a column guessed at 64 instead of read from the format string left three
//     characters of another team's resource group visible.
//   - accumulated rounding over ~50 columns left a sliver at the right edge, so
//     every box is padded outward.
//
// Under-covering is the only failure that matters. Inspect the output.

import sharp from 'sharp';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SRC = process.argv[2] ? path.resolve(process.argv[2]) : null;
const OUT = path.join(HERE, '..', 'docs', 'guide');

if (!SRC || !fs.existsSync(SRC)) {
  console.error('usage: node guide/redact-terminal.mjs <dir-with-raw-screenshots>');
  console.error('The raw captures are not in this repository - they contain real identifiers.');
  process.exit(1);
}

const INK = '#11161d';
const TEXT = '#8fa6c0';

const esc = (s) => String(s).replace(/[<>&]/g, (c) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;' })[c]);

const JOBS = [
  {
    file: 'run1-prereq.png',
    out: 'run-1-prerequisites.png',
    grid: { ox: 4, cw: 8.8 },
    cropHeight: 850, // the capture ends mid-line
    redactions: [
      // The prompt path carries the operator's Windows account name. 49 columns
      // covers the 47-character path plus the trailing '>'.
      { top: 5,   col: 3,  chars: 49, text: 'C:\\repos\\claude-code-foundry-gateway>' },
      { top: 442, col: 24, chars: 20, text: 'you@contoso.com' },
      { top: 462, col: 18, chars: 38, text: '00000000-0000-0000-0000-000000000000' },
      { top: 613, col: 11, chars: 20, text: 'you@contoso.com' },
      { top: 633, col: 11, chars: 38, text: '00000000-0000-0000-0000-000000000000' },
      { top: 651, col: 22, chars: 33, text: 'CONTOSO-AI-SUB' },
      { top: 670, col: 25, chars: 33, text: 'CONTOSO-AI-SUB' },
      { top: 785, col: 10, chars: 26, text: 'ai-contoso-foundry' },
      { top: 822, col: 11, chars: 26, text: 'ai-contoso-foundry' },
    ],
  },
  {
    file: 'run2-reuse.png',
    out: 'run-2-reuse-existing-apim.png',
    grid: { ox: 2.3, cw: 8.67 },
    redactions: [
      { top: 138, col: 10, chars: 22, text: 'apim-claude-gw-a1b2c3' },
      // A different team's gateway and resource group - the most sensitive
      // thing in the set, because it names an unrelated internal project.
      { top: 176, col: 10, chars: 14, text: 'apim-other-gw' },
      // Column 61 comes from the row's format string in the installer:
      //   "       {0}. {1,-24} {2,-10} {3,-14} {4}"
      // 7 spaces + index + '. ' = 10, name 24 -> 34, space, sku 10 -> 45,
      // space, location 14 -> 60, space, resource group at 61.
      { top: 176, col: 61, chars: 21, text: 'rg-other-team' },
      { top: 289, col: 19, chars: 22, text: 'apim-claude-gw-a1b2c3' },
    ],
  },
  {
    // Budget prompts only - nothing identifying, so it ships unmodified.
    file: 'run3-budgets.png',
    out: 'run-3-budgets.png',
    grid: { ox: 0, cw: 9 },
    redactions: [],
  },
  {
    file: 'run4-summary.png',
    out: 'run-4-summary.png',
    grid: { ox: -6.2, cw: 9.1 },
    redactions: [
      { top: 74,  col: 27, chars: 33, text: 'CONTOSO-AI-SUB' },
      // 25, not 26: the account name is exactly 25 characters, and the
      // '(rg ...)' after it should stay readable.
      { top: 92,  col: 27, chars: 25, text: 'ai-contoso-foundry' },
      { top: 149, col: 27, chars: 22, text: 'apim-claude-gw-a1b2c3' },
      { top: 169, col: 27, chars: 19, text: 'you@contoso.com' },
      // 21 keeps the ' - no new API Management' that follows.
      { top: 321, col: 10, chars: 21, text: 'apim-claude-gw-a1b2c3' },
    ],
  },
];

const PAD_X = 5;
// The row coordinate is the top of the ink, not of the character cell, and
// descenders sit below it. The row pitch is 19, so 23px starting 5px high
// covers a whole cell without reaching the ink of the row beneath.
const PAD_TOP = 5;
const BOX_H = 23;

fs.mkdirSync(OUT, { recursive: true });

for (const job of JOBS) {
  const src = path.join(SRC, job.file);
  if (!fs.existsSync(src)) {
    console.log(`${job.out.padEnd(32)} skipped - ${job.file} not found`);
    continue;
  }

  const dst = path.join(OUT, job.out);
  const meta = await sharp(src).metadata();

  const boxes = job.redactions.map((r) => ({
    x: Math.max(0, Math.round(job.grid.ox + r.col * job.grid.cw) - PAD_X),
    y: Math.max(0, r.top - PAD_TOP),
    w: Math.round(r.chars * job.grid.cw) + PAD_X * 2,
    h: BOX_H,
    text: r.text,
  }));

  const svg = `<svg width="${meta.width}" height="${meta.height}" xmlns="http://www.w3.org/2000/svg">
    ${boxes.map((b) => `
      <rect x="${b.x}" y="${b.y}" width="${b.w}" height="${b.h}" rx="2" fill="${INK}"/>
      <text x="${b.x + 5}" y="${b.y + 15}" font-family="Consolas, monospace" font-size="15" fill="${TEXT}">${esc(b.text)}</text>
    `).join('')}
  </svg>`;

  // Two passes: sharp applies extract before composite within one pipeline, so
  // cropping first would leave the full-height overlay too large to fit.
  const composited = await sharp(src)
    .composite(boxes.length ? [{ input: Buffer.from(svg), top: 0, left: 0 }] : [])
    .png()
    .toBuffer();

  const h = Math.min(job.cropHeight ?? meta.height, meta.height);
  await sharp(composited)
    .extract({ left: 0, top: 0, width: meta.width, height: h })
    .png()
    .toFile(dst);

  console.log(`${job.out.padEnd(32)} ${meta.width}x${h}  ${boxes.length} redaction(s)`);
}
