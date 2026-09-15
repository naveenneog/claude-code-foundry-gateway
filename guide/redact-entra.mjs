// Redacts the Entra portal screenshots used in the business unit guide.
//
// Same approach as redact-clients.mjs: these are GUI captures with no character
// grid, so boxes are pixel coordinates verified by looking at the result.
// Under-covering is the only failure that matters, so boxes are padded outward.
//
// These are real people in a real Microsoft tenant, and the screenshots say so
// on purpose - an accelerator whose evidence is all Contoso placeholders asks
// the reader to take it on trust. So identities are masked in the middle rather
// than replaced:
//
//   first two characters + bullets + last two characters, per name part
//   email local part masked the same way, domain left intact
//
// What that keeps: the tenant is visibly Microsoft, the addresses are visibly
// real, initials still match the names. What it removes: enough to identify or
// contact anyone.
//
// Only the masked strings are committed. The originals live in the capture,
// which is git-ignored, and are not restated here.
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

// Masked forms of the four people in the All members capture, in row order.
// The avatars are left alone: the initials still match the visible first
// letters, so redrawing them would only make the picture inconsistent.
const PEOPLE = [
  { name: 'Na\u2022\u2022\u2022\u2022n Go\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022na', mail: 'na\u2022\u2022\u2022\u2022\u2022g@microsoft.com' },
  { name: 'Ni\u2022\u2022d Ve\u2022\u2022\u2022\u2022\u2022\u2022an',                                 mail: 'ni\u2022\u2022\u2022\u2022v@microsoft.com' },
  { name: 'Sa\u2022\u2022\u2022\u2022h Se\u2022\u2022',                                               mail: 'Sa\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022h@microsoft.com' },
  { name: 'Vr\u2022\u2022a Ki\u2022\u2022\u2022\u2022e Mu\u2022\u2022\u2022\u2022ai',                 mail: 'vr\u2022@microsoft.com' },
];

// The signed-in account chip, top right. The tenant name stays: it says this is
// a real Microsoft non-production tenant, which is the point.
const chip = (right, top, height) => ({
  rect: { x: right - 330, y: top, w: 330, h: height, fill: HEADER },
  texts: [
    { x: right - 6, y: top + 30, anchor: 'end', size: 23, fill: '#ffffff', text: 'na\u2022\u2022@microsoft.com' },
    { x: right - 6, y: top + 54, anchor: 'end', size: 16, fill: '#ffffff', weight: '600', text: 'MICROSOFT NON-PRODUCTION ...' },
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
    // Display name, a link. The avatar to its left is untouched.
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

// Every capture must have a redaction job. capture-entra.mjs takes six blades;
// this file currently has coordinates for two of them, and a capture nobody has
// positioned boxes for is exactly the file that gets copied into docs by hand
// with a real name still on it. So it is an error, not a warning.
//
// Same reasoning as the named value guard in scripts/ApimNamedValue.ps1: the
// dangerous failure is the silent one.
const handled = new Set(JOBS.map((j) => j.file));
const captured = fs.existsSync(SRC)
  ? fs.readdirSync(SRC).filter((f) => f.toLowerCase().endsWith('.png'))
  : [];
const unhandled = captured.filter((f) => !handled.has(f));

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

if (unhandled.length) {
  console.error('');
  console.error('Captures with no redaction job:');
  for (const f of unhandled) console.error(`  ${f}`);
  console.error('');
  console.error('These still carry real names, addresses and the signed-in account.');
  console.error('Add a job to JOBS with boxes positioned against the capture, or delete');
  console.error('the file. Do not copy it into docs/guide/ by hand.');
  process.exit(1);
}

console.log(`\n${JOBS.length} capture(s) redacted, ${captured.length} present, 0 unhandled.`);
