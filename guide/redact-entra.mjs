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

// Keyed by the initials on each avatar, not by first name: the tests assert
// that no real name survives in this file, and PowerShell -notmatch is
// case-insensitive, so a key called bhishek would fail that check.
const P = {
  ng:  { name: 'Na\u2022\u2022\u2022\u2022n Go\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022na', mail: 'na\u2022\u2022\u2022\u2022\u2022g@microsoft.com' },
  ss: { name: 'Sa\u2022\u2022\u2022\u2022h Se\u2022\u2022',                mail: 'Sa\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022h@microsoft.com' },
  nv:   { name: 'Ni\u2022\u2022d Ve\u2022\u2022\u2022\u2022\u2022\u2022an',  mail: 'ni\u2022\u2022\u2022\u2022v@microsoft.com' },
  vk:   { name: 'Vr\u2022\u2022a Ki\u2022\u2022\u2022\u2022e Mu\u2022\u2022\u2022\u2022ai', mail: 'vr\u2022@microsoft.com' },
  ap:{ name: 'Ab\u2022\u2022\u2022\u2022\u2022\u2022k Pa\u2022\u2022a',   mail: 'ab\u2022\u2022\u2022ra@microsoft.com' },
  rs:   { name: 'Ra\u2022\u2022t Sr\u2022\u2022\u2022\u2022\u2022\u2022va',  mail: 'ra\u2022\u2022\u2022sr@microsoft.com' },
};

// Measured on these captures: the name column starts at x=718, the email column
// at x=1558, and rows are 80px apart. Only user rows are masked - a group row
// carries a group name, which is not an identity.
const NAME_X = 718, MAIL_X = 1558, PITCH = 80;
function memberRow(cy, person) {
  return [
    { rect: { x: NAME_X - 14, y: cy - 20, w: 340, h: 40, fill: ROW } },
    { x: NAME_X, y: cy + 8, size: 22, fill: LINK, text: person.name },
    { rect: { x: MAIL_X - 6, y: cy - 20, w: 380, h: 40, fill: ROW } },
    { x: MAIL_X, y: cy + 8, size: 22, fill: TEXT, text: person.mail },
  ];
}

// The single member of claude-bu-gbb, masked the same way. That capture is
// cropped above the account line, so its header needs nothing.
const GBB_PERSON = {
  name: 'So\u2022\u2022\u2022th Ba\u2022\u2022\u2022\u2022ee',
  mail: 'so\u2022\u2022\u2022\u2022\u2022\u2022\u2022ee@microsoft.com',
};

// The signed-in account chip, top right. The tenant name stays: it says this is
// a real Microsoft non-production tenant, which is the point.
const chip = (right, top, height, width = 330) => ({
  rect: { x: right - width, y: top, w: width, h: height, fill: HEADER },
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
  {
    file: 'ites-1-memberships.png',
    out: 'entra-3-team-memberships.png',
    // The Group memberships blade of a team: it shows the team sitting in both
    // its business unit and its tier group, which is the two-axis model in one
    // picture. The object ids in that table are the same ones the guide already
    // links to, so they stay.
    parts: (() => { const c = chip(2195, 7, 60); return [{ rect: c.rect }, ...c.texts]; })(),
  },
  {
    file: 'gbb.png',
    out: 'entra-4-bu-direct-person.png',
    // A business unit with a person in it rather than a team. The capture is
    // cropped above the account line, so the header needs nothing.
    parts: [
      { rect: { x: 718, y: 680, w: 300, h: 40, fill: ROW } },
      { x: 722, y: 708, size: 22, fill: LINK, text: GBB_PERSON.name },
      { rect: { x: 1560, y: 680, w: 380, h: 40, fill: ROW } },
      { x: 1566, y: 708, size: 22, fill: TEXT, text: GBB_PERSON.mail },
    ],
  },
  {
    file: 'ites-1.png',
    out: 'entra-5-team-ites-1-members.png',
    // A team with two people in it. Rows are 80px apart from y=735.
    parts: (() => {
      const c = chip(2195, 0, 60);
      return [{ rect: c.rect }, ...c.texts,
        ...memberRow(735, P.ng), ...memberRow(815, P.ss)];
    })(),
  },
  {
    file: 'ites-2.png',
    out: 'entra-6-team-ites-2-members.png',
    parts: (() => {
      const c = chip(2214, 0, 78, 380);
      return [{ rect: c.rect }, ...c.texts,
        ...memberRow(735, P.nv), ...memberRow(815, P.vk)];
    })(),
  },
  {
    file: 'tier-standard.png',
    out: 'entra-7-tier-standard-members.png',
    // A tier holds a mix: two teams and three people added directly. Only the
    // three user rows carry identities - rows 2 and 3 are group names.
    parts: (() => {
      const c = chip(2235, 0, 78, 380);
      return [{ rect: c.rect }, ...c.texts,
        ...memberRow(746, P.ap), ...memberRow(986, P.ng), ...memberRow(1066, P.rs)];
    })(),
  },
  {
    file: 'tier-premium.png',
    out: 'entra-8-tier-premium-members.png',
    // Nothing to mask in the table: the premium tier holds one team and one
    // service principal. A service principal is a workload identity, not a
    // person, so its name stays - it is the example of a CI job holding a tier.
    parts: (() => { const c = chip(2199, 0, 78, 380); return [{ rect: c.rect }, ...c.texts]; })(),
  },
  {
    file: 'navg-groups.png',
    out: 'entra-9-user-groups.png',
    // The same hierarchy read from the other end: one person's Groups blade,
    // showing the team and the tier they landed in. The blade title and the
    // breadcrumb both carry the display name.
    parts: (() => {
      const c = chip(2230, 0, 72, 380);
      return [{ rect: c.rect }, ...c.texts,
        { rect: { x: 140, y: 92, w: 300, h: 32, fill: ROW } },
        { x: 146, y: 114, size: 22, fill: TEXT, text: P.ng.name },
        { rect: { x: 98, y: 130, w: 470, h: 66, fill: ROW } },
        { x: 103, y: 182, size: 44, fill: TEXT, weight: '600', text: P.ng.name },
        // An unrelated group in this tenant is named after the account holder.
        // Leaving it would undo the masking three lines above: the title reads
        // "Na****n" and this row would spell the same first name out.
        { rect: { x: 670, y: 1085, w: 190, h: 36, fill: ROW } },
        { x: 674, y: 1110, size: 21, fill: TEXT, text: 'na\u2022\u2022\u2022\u2022-ai-gbb' },
      ];
    })(),
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
