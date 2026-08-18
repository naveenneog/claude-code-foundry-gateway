/**
 * Screenshot annotation helpers for the UI guide.
 *
 * Design rules learned the hard way:
 *   - never draw the step text over the UI; it hides the thing being explained.
 *     The caption goes in a banner on an extended canvas instead.
 *   - all annotation geometry is scaled to the source resolution, so a 2496px
 *     VS Code capture and a 1500px portal capture end up with identically sized
 *     banners once both are resized to the output width.
 *   - highlight boxes come from live element bounding boxes where a page is
 *     available, so they survive portal layout changes.
 *   - identity redaction is on by default. Forgetting it is a privacy incident,
 *     not a cosmetic bug, so it has to be opted out of explicitly.
 */
import fs from 'node:fs';
import path from 'node:path';
import sharp from 'sharp';

const NAVY = '#1E2761';
const AMBER = '#F2A007';
const INK = '#0d1117';

/** Banner height in *output* pixels; multiplied by the source scale factor. */
const BANNER_H = 74;

const esc = (s) =>
  String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

/** Step banner drawn above the screenshot on extended canvas. */
function bannerSvg(width, k, { n, title, note }) {
  const h = BANNER_H * k;
  const r = (v) => Math.round(v * k);
  return `
    <rect x="0" y="0" width="${width}" height="${h}" fill="${NAVY}"/>
    <rect x="0" y="${h - 4 * k}" width="${width}" height="${4 * k}" fill="${AMBER}"/>
    ${n != null ? `
      <rect x="${r(22)}" y="${r(17)}" width="${r(42)}" height="${r(42)}" rx="${r(8)}" fill="${AMBER}"/>
      <text x="${r(43)}" y="${r(47)}" text-anchor="middle" font-family="Consolas, monospace"
            font-size="${r(22)}" font-weight="bold" fill="#3d2a00">${esc(n)}</text>` : ''}
    <text x="${r(n != null ? 80 : 22)}" y="${r(34)}" font-family="Segoe UI, system-ui, sans-serif"
          font-size="${r(19)}" font-weight="600" fill="#ffffff">${esc(title ?? '')}</text>
    ${note ? `<text x="${r(n != null ? 80 : 22)}" y="${r(56)}" font-family="Consolas, monospace"
          font-size="${r(13.5)}" fill="#cadcfc">${esc(note)}</text>` : ''}`;
}

/** Rounded highlight box plus optional numbered tag on its corner. */
function highlightSvg({ x, y, w, h, n }, k, dy) {
  const top = y + dy;
  const sw = 3 * k;
  const rad = 15 * k;
  return `
    <rect x="${x - sw}" y="${top - sw}" width="${w + sw * 2}" height="${h + sw * 2}" rx="${6 * k}"
          fill="none" stroke="${AMBER}" stroke-width="${sw}"/>
    ${n != null ? `
      <circle cx="${x - sw}" cy="${top - sw}" r="${rad}" fill="${AMBER}" stroke="#ffffff" stroke-width="${2 * k}"/>
      <text x="${x - sw}" y="${top - sw + 5.5 * k}" text-anchor="middle" font-family="Consolas, monospace"
            font-size="${15 * k}" font-weight="bold" fill="#3d2a00">${esc(n)}</text>` : ''}`;
}

/** Opaque block used to cover anything that must not be published. */
function maskSvg({ x, y, w, h, text, align = 'end' }, k, dy) {
  const top = y + dy;
  const tx = align === 'end' ? x + w - 10 * k : x + 10 * k;
  return `
    <rect x="${x}" y="${top}" width="${w}" height="${h}" rx="${3 * k}" fill="${INK}"/>
    ${text ? `<text x="${tx}" y="${top + h / 2 + 5 * k}" text-anchor="${align}"
        font-family="Consolas, monospace" font-size="${13 * k}" fill="#9fb4d0">${esc(text)}</text>` : ''}`;
}

/**
 * The portal renders the signed-in account and tenant at the top right of a
 * fixed-height header. Covering that strip is reliable without needing to know
 * the actual strings.
 */
function identitySvg(width, k, dy, { account = 'you@contoso.com', tenant = 'CONTOSO' } = {}) {
  const w = 340 * k;
  const x = width - w - 12 * k;
  const y = dy + 6 * k;
  return `
    <rect x="${x}" y="${y}" width="${w}" height="${44 * k}" rx="${4 * k}" fill="#0f6cbd"/>
    <text x="${x + w - 14 * k}" y="${y + 22 * k}" text-anchor="end" font-family="Segoe UI, sans-serif"
          font-size="${14 * k}" fill="#ffffff">${esc(account)}</text>
    <text x="${x + w - 14 * k}" y="${y + 39 * k}" text-anchor="end" font-family="Segoe UI, sans-serif"
          font-size="${10.5 * k}" font-weight="600" fill="#dbe9f7">${esc(tenant)}</text>`;
}

/**
 * @param {Buffer} buffer   raw PNG
 * @param {string} outPath  destination file
 * @param {object} opts
 *   banner       { n, title, note } drawn above the shot on extended canvas
 *   highlights   [{ x, y, w, h, n }] pixel or fractional coordinates
 *   masks        [{ x, y, w, h, text, align }] extra redactions
 *   maskIdentity cover the portal account block (default true)
 *   width        output width (default 1500)
 */
export async function annotate(buffer, outPath, opts = {}) {
  const {
    banner,
    highlights = [],
    masks = [],
    maskIdentity = true,
    identity = {},
    width = 1500,
  } = opts;

  const meta = await sharp(buffer).metadata();

  // Source pixels per output pixel. Everything drawn is multiplied by this so
  // the annotations render at a constant size after the final resize.
  const k = meta.width / width;
  const dy = banner ? Math.round(BANNER_H * k) : 0;

  // Coordinates may be given as fractions of the image (all values <= 1) so a
  // spec stays correct across source resolutions. Pixel coordinates are never
  // fractional in practice.
  const toPx = (r) => {
    const frac = ['x', 'y', 'w', 'h'].every((key) => r[key] == null || Math.abs(r[key]) <= 1);
    if (!frac) return r;
    return {
      ...r,
      x: Math.round(r.x * meta.width),
      y: Math.round(r.y * meta.height),
      w: Math.round(r.w * meta.width),
      h: Math.round(r.h * meta.height),
    };
  };

  const canvas = banner
    ? await sharp(buffer).extend({ top: dy, background: NAVY }).png().toBuffer()
    : buffer;

  const svg = `<svg width="${meta.width}" height="${meta.height + dy}" xmlns="http://www.w3.org/2000/svg">
    ${banner ? bannerSvg(meta.width, k, banner) : ''}
    ${maskIdentity ? identitySvg(meta.width, k, dy, identity) : ''}
    ${masks.map((m) => maskSvg(toPx(m), k, dy)).join('')}
    ${highlights.map((h) => highlightSvg(toPx(h), k, dy)).join('')}
  </svg>`;

  const composed = await sharp(canvas)
    .composite([{ input: Buffer.from(svg), top: 0, left: 0 }])
    .png()
    .toBuffer();

  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  await sharp(composed).resize({ width }).png({ compressionLevel: 9 }).toFile(outPath);

  console.log(`  ${path.basename(outPath)}  ${Math.round(fs.statSync(outPath).size / 1024)} KB`);
  return outPath;
}

/**
 * Turns selector specs into highlight boxes by measuring the live page.
 * Missing elements are skipped rather than throwing, because portal blades
 * render inconsistently and a partial annotation beats no screenshot.
 *
 * @param {import('playwright').Page} page
 * @param {Array<{sel:string, n?:number|string, pad?:number}>} targets
 */
export async function resolveTargets(page, targets = []) {
  const out = [];

  // Bring the first target fully into frame before measuring anything, so a
  // highlight never lands half off the bottom of the capture. Measuring has to
  // happen after the scroll settles or every box is offset.
  if (targets.length) {
    try {
      const first = page.locator(targets[0].sel).first();
      await first.waitFor({ state: 'visible', timeout: targets[0].timeout ?? 6000 });
      await first.evaluate((el) => el.scrollIntoView({ block: 'center', behavior: 'instant' }));
      await page.waitForTimeout(900);
    } catch {
      /* unscrolled capture is still usable */
    }
  }

  for (const t of targets) {
    try {
      const loc = page.locator(t.sel).first();
      await loc.waitFor({ state: 'visible', timeout: t.timeout ?? 6000 });
      const box = await loc.boundingBox();
      if (!box) continue;
      const p = t.pad ?? 4;
      out.push({
        x: Math.round(box.x - p),
        y: Math.round(box.y - p),
        w: Math.round(box.width + p * 2),
        h: Math.round(box.height + p * 2),
        n: t.n,
      });
    } catch {
      console.log(`  (no match: ${t.sel})`);
    }
  }
  return out;
}

export { NAVY, AMBER, BANNER_H };
