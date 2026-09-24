// Render operator-supplied live transcripts. No historical deployment/output is embedded.
// Set GUIDE_TRANSCRIPTS and REDACTIONS_FILE; see docs/TURNSTILE.md, manual alternatives.
import fs from 'node:fs';
import path from 'node:path';
import { chromium } from 'playwright';
import { Redactor } from './lib/turnstile-live.mjs';

const directory = process.env.GUIDE_TRANSCRIPTS;
if (!directory || !process.env.REDACTIONS_FILE)
  throw new Error('Set GUIDE_TRANSCRIPTS and REDACTIONS_FILE; embedded reference transcripts are no longer supported');
const records = JSON.parse(fs.readFileSync(path.join(directory, 'manifest.json'), 'utf8').replace(/^\uFEFF/, ''));
const redactor = new Redactor(JSON.parse(fs.readFileSync(process.env.REDACTIONS_FILE, 'utf8').replace(/^\uFEFF/, '')));
const output = path.resolve(process.env.GUIDE_OUTPUT ?? 'docs/guide');
fs.mkdirSync(output, { recursive: true });
const escape = (value) => value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const browser = await chromium.launch();
try {
  const page = await browser.newPage();
  for (const item of records) {
    if (item.live !== true || !item.command || !Number.isFinite(Date.parse(item.captured_at_utc)))
      throw new Error('Every transcript needs live, dated command provenance');
    if (path.basename(item.file) !== item.file || !item.file.endsWith('.txt'))
      throw new Error('Transcript filenames must be local .txt basenames');
    const content = redactor.redact(fs.readFileSync(path.join(directory, item.file), 'utf8'));
    if (redactor.leaks(content).length) throw new Error('Refusing a transcript with a surviving identifier');
    await page.setContent(`<main style="width:1200px;background:#11131a;color:#d6dae4;padding:24px;font:15px/1.6 Consolas,monospace"><pre style="white-space:pre-wrap">${escape(content)}</pre></main>`);
    await page.locator('main').screenshot({ path: path.join(output, item.file.replace(/\.txt$/, '.png')) });
  }
} finally { await browser.close(); }
