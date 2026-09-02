// Redacts the client screenshots used in the README.
//
// These are GUI captures rather than terminal output, so there is no character
// grid to address - boxes are pixel coordinates, checked by looking at the
// result. Under-covering is the only failure that matters, so every box is
// padded outward and the output is inspected.

import sharp from 'sharp';
import fs from 'node:fs';
import path from 'node:path';

const SRC = 'C:/Users/navg/DailyApps/work/CLAUDE/shots2';
const OUT = 'C:/Users/navg/DailyApps/work/CLAUDE/accel/docs/images';

const esc = (s) => String(s).replace(/[<>&]/g, (c) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;' })[c]);

const JOBS = [
  {
    file: 'cli-status.png',
    out: 'client-cli-status.png',
    // Terminal: dark background, light replacement text.
    ink: '#0c0c0c', fg: '#9aa7b4', size: 21, mono: true,
    // Row pitch is 28px, so a 26px box centred on the row leaves clearance
    // above and below. A 32px box clipped the descenders of the row above.
    boxes: [
      // Session GUID - identifies a real session.
      { x: 448, y: 527, w: 530, h: 26, text: '<session-id>' },
      // Working directory carries the Windows account name.
      { x: 448, y: 583, w: 530, h: 26, text: 'C:\\repos\\my-project' },
      // Real gateway hostname.
      { x: 448, y: 639, w: 730, h: 26, text: 'https://apim-example.azure-api.net/claude' },
    ],
  },
  {
    file: 'desktop-home.png',
    out: 'client-desktop-chat.png',
    // Light GUI chrome.
    ink: '#f2f0ea', fg: '#6b6b6b', size: 20, mono: false,
    boxes: [
      // Conversation titles, one personal.
      { x: 18, y: 400, w: 400, h: 40, text: 'Payments service refactor' },
      { x: 18, y: 442, w: 400, h: 40, text: 'Release notes draft' },
      { x: 18, y: 484, w: 400, h: 42, text: 'Onboarding checklist' },
      // Signed-in account.
      { x: 14, y: 1146, w: 250, h: 44, text: 'you  ·  Gateway' },
    ],
  },
  {
    file: 'desktop-code.png',
    out: 'client-desktop-code.png',
    ink: '#ffffff', fg: '#3d3d3d', size: 30, mono: false,
    boxes: [
      // Greeting includes the account name.
      { x: 540, y: 124, w: 380, h: 52, text: "What's up next?", size: 30 },
      // Project names in the sidebar.
      { x: 18, y: 242, w: 412, h: 42, text: 'payments-api', ink: '#f2f0ea', fg: '#6b6b6b', size: 20 },
      { x: 18, y: 284, w: 412, h: 40, text: 'Available options', ink: '#f2f0ea', fg: '#8a8a8a', size: 19 },
      { x: 18, y: 334, w: 412, h: 42, text: 'internal-tools', ink: '#f2f0ea', fg: '#6b6b6b', size: 20 },
      { x: 18, y: 376, w: 412, h: 40, text: 'Shared component library', ink: '#f2f0ea', fg: '#8a8a8a', size: 19 },
      // The working-directory chip at the bottom repeats the project name.
      // Missed on the first pass: it was redacted in the sidebar and left here.
      { x: 692, y: 1026, w: 122, h: 30, text: 'payments-api', ink: '#ffffff', fg: '#3d3d3d', size: 19 },
      { x: 14, y: 1144, w: 250, h: 44, text: 'you  ·  Gateway', ink: '#f2f0ea', fg: '#6b6b6b', size: 20 },
    ],
  },
];

fs.mkdirSync(OUT, { recursive: true });

for (const job of JOBS) {
  const src = path.join(SRC, job.file);
  if (!fs.existsSync(src)) { console.log(`${job.out.padEnd(28)} skipped - source missing`); continue; }
  const meta = await sharp(src).metadata();

  const svg = `<svg width="${meta.width}" height="${meta.height}" xmlns="http://www.w3.org/2000/svg">
    ${job.boxes.map((b) => {
      const ink = b.ink ?? job.ink;
      const fg = b.fg ?? job.fg;
      const size = b.size ?? job.size;
      const family = job.mono ? 'Consolas, monospace' : 'Segoe UI, system-ui, sans-serif';
      return `
      <rect x="${b.x}" y="${b.y}" width="${b.w}" height="${b.h}" rx="3" fill="${ink}"/>
      <text x="${b.x + 6}" y="${b.y + b.h / 2 + size / 3}" font-family="${family}"
            font-size="${size}" fill="${fg}">${esc(b.text)}</text>`;
    }).join('')}
  </svg>`;

  await sharp(src)
    .composite([{ input: Buffer.from(svg), top: 0, left: 0 }])
    .png()
    .toFile(path.join(OUT, job.out));

  console.log(`${job.out.padEnd(28)} ${meta.width}x${meta.height}  ${job.boxes.length} redaction(s)`);
}
