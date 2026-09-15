// Redacts the Entra portal screenshots used in the business unit guide.
//
// Same approach as redact-clients.mjs: these are GUI captures with no character
// grid, so boxes are pixel coordinates verified by looking at the result.
// Under-covering is the only failure that matters, so boxes are padded outward.
//
// The replacement identities continue the table in render-terminal.mjs, so the
// same person is the same example across the terminal output and the portal
// screenshots - navg is Amara Okafor in both.
//
//   node guide/redact-entra.mjs

import sharp from 'sharp';
import fs from 'node:fs';
import path from 'node:path';

const SRC = '.shots-entra';
const OUT = 'docs/guide';

const esc = (s) => String(s).replace(/[<>&]/g, (c) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;' })[c]);

// Portal colours, sampled from the captures rather than guessed.
const HEADER = '#0078d4';
const ROW = '#ffffff';
const LINK = '#0078d4';
const TEXT = '#292827';
const UI = 'Segoe UI, system-ui, sans-serif';

// Real identity -> what appears in the documentation.
const PEOPLE = [
  { initials: 'AO', name: 'Amara Okafor',  mail: 'amara.okafor@contoso.com',  dot: '#da532c' },
  { initials: 'PR', name: 'Priya Raman',   mail: 'priya.raman@contoso.com',   dot: '#8764b8' },
  { initials: 'TN', name: 'Tomas Novak',   mail: 'tomas.novak@contoso.com',   dot: '#0f548c' },
  { initials: 'LF', name: 'Lena Fischer',  mail: 'lena.fischer@contoso.com',  dot: '#5c2e91' },
];

// The signed-in account chip, top right. Two lines, right-aligned against the
// avatar, on the header blue.
const chip = (right, top, height) => ({
  rect: { x: right - 330, y: top, w: 330, h: height, fill: HEADER },
  texts: [
    { x: right - 6, y: top + 30, anchor: 'end', size: 23, fill: '#ffffff', text: 'amara.okafor@contoso.com' },
    { x: right - 6, y: top + 54, anchor: 'end', size: 16, fill: '#ffffff', weight: '600', text: 'CONTOSO ENGINEERING ...' },
  ],
});

// The member table in the All members capture. Rows are 80px apart, measured
// from the capture; the first user row is the third row because the two team
// groups sort above the people.
const FIRST_USER_ROW = 886;
const ROW_PITCH = 80;

const memberRows = PEOPLE.flatMap((p, i) => {
  const cy = FIRST_USER_ROW + i * ROW_PITCH;
  return [
    // Avatar: a filled circle carrying the initials, so the original initials
    // do not survive next to a replaced name.
    { rect: { x: 556, y: cy - 29, w: 60, h: 60, fill: ROW } },
    { circle: { cx: 585, cy, r: 27, fill: p.dot } },
    { x: 585, y: cy + 7, anchor: 'middle', size: 20, fill: '#ffffff', weight: '600', text: p.initials },
    // Display name, a link.
    { rect: { x: 628, y: cy - 20, w: 330, h: 40, fill: ROW } },
    { x: 632, y: cy + 8, size: 22, fill: LINK, text: p.name },
    // Email.
    { rect: { x: 1470, y: cy - 20, w: 360, h: 40, fill: ROW } },
    { x: 1476, y: cy + 8, size: 22, fill: TEXT, text: p.mail },
  ];
});

const JOBS = [
  {
    file: 'mcaps-direct.png',
    out: 'entra-1-bu-direct-members.png',
    // Direct members are the two team groups - no personal data in the table,
    // so only the signed-in account needs covering.
    parts: (() => { const c = chip(2184, 8, 72); return [{ rect: c.rect }, ...c.texts]; })(),
  },
  {
    file: 'mcaps-all.png',
    out: 'entra-2-bu-all-members.png',
    parts: (() => { const c = chip(2195, 0, 60); return [{ rect: c.rect }, ...c.texts, ...memberRows]; })(),
  },
];

fs.mkdirSync(OUT, { recursive: true });

for (const job of JOBS) {
  const src = path.join(SRC, job.file);
  if (!fs.existsSync(src)) { console.log(`${job.out.padEnd(34)} skipped - source missing`); continue; }
  const meta = await sharp(src).metadata();

  const body = job.parts.map((p) => {
    if (p.rect) {
      const r = p.rect;
      return `<rect x="${r.x}" y="${r.y}" width="${r.w}" height="${r.h}" fill="${r.fill ?? ROW}"/>`;
    }
    if (p.circle) {
      const c = p.circle;
      return `<circle cx="${c.cx}" cy="${c.cy}" r="${c.r}" fill="${c.fill}"/>`;
    }
    return `<text x="${p.x}" y="${p.y}" font-family="${UI}" font-size="${p.size}"
      fill="${p.fill}" ${p.weight ? `font-weight="${p.weight}"` : ''}
      ${p.anchor ? `text-anchor="${p.anchor}"` : ''}>${esc(p.text)}</text>`;
  }).join('\n');

  const svg = `<svg width="${meta.width}" height="${meta.height}" xmlns="http://www.w3.org/2000/svg">${body}</svg>`;

  await sharp(src)
    .composite([{ input: Buffer.from(svg), top: 0, left: 0 }])
    .png()
    .toFile(path.join(OUT, job.out));

  console.log(`${job.out.padEnd(34)} ${meta.width}x${meta.height}  ${job.parts.length} edit(s)`);
}
