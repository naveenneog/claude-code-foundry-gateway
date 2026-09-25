// Renders real terminal transcripts into the Turnstile guide's screenshots.
//
//   $env:TURNSTILE_TRANSCRIPTS = '<folder of NN-name.txt files>'
//   node guide/render-turnstile.mjs
//
// The transcripts are the output of running the commands they show, against the
// reference gateway and the live Turnstile deployment (docs/TURNSTILE.md). Each file's
// first line is "# <title>"; the rest is the terminal text. They stay on the machine
// that ran them, because they hold real tenant identities. What is committed is this
// renderer and its images.
//
// Redaction is by pattern, not by a list of known values, so a new identity in a new
// transcript is caught without editing this file: every GUID becomes a numbered
// placeholder (the same GUID gets the same number across all images), and every email
// and resource name below becomes an example one.

import { chromium } from 'playwright';
import { readdir, readFile, mkdir } from 'node:fs/promises';
import { dirname, join, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Redactor } from './lib/turnstile-live.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const outDir = process.env.GUIDE_OUTPUT || join(here, '..', 'docs', 'guide');
const source = process.env.TURNSTILE_TRANSCRIPTS;
if (!source) {
  console.error('Set TURNSTILE_TRANSCRIPTS to the folder of transcripts.');
  process.exit(2);
}

if (!process.env.REDACTIONS_FILE) throw new Error('Set REDACTIONS_FILE to a private, deployment-specific replacement map');
const redactor = new Redactor(JSON.parse((await readFile(process.env.REDACTIONS_FILE, 'utf8')).replace(/^\uFEFF/, '')));

const guidPattern = /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi;
// Public, documented identifiers that a reader needs verbatim.
const PUBLIC_GUIDS = new Set(['04b07795-8ddb-461a-bbee-02f9e1bf7b46']); // Azure CLI
const guids = new Map();
const placeholder = (g) => {
  const key = g.toLowerCase();
  if (PUBLIC_GUIDS.has(key)) return g;
  if (!guids.has(key)) guids.set(key, `00000000-0000-0000-0000-${String(guids.size + 1).padStart(12, '0')}`);
  return guids.get(key);
};

const redact = (s) => {
  const result = redactor.redact(s).replace(guidPattern, placeholder);
  if (redactor.leaks(result).length) throw new Error('Refusing a transcript with a surviving identifier');
  return result;
};

function colourise(line) {
  const esc = line.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  if (/^PS [A-Z]:/.test(line)) return `<span class="prompt">${esc}</span>`;
  if (/^\s*(Exception|WARNING|Refused|refused)/.test(line)) return `<span class="warn">${esc}</span>`;
  if (/"type":\s*"(error|rate_limit_error)"|Status: 4\d\d/.test(line)) return `<span class="warn">${esc}</span>`;
  if (/^\s*(Issued|Wrote|set |Connected|Validated|granted|already)/.test(line)) return `<span class="ok">${esc}</span>`;
  if (/^\s*-{10,}/.test(line)) return `<span class="dim">${esc}</span>`;
  if (/^\s*(Nothing written|In effect|Figures|List price|Role assignments)/.test(line)) return `<span class="dim">${esc}</span>`;
  return esc;
}

function html(title, body) {
  const lines = redact(body).replace(/\r/g, '').split('\n');
  while (lines.length && !lines[lines.length - 1].trim()) lines.pop();
  const cols = Math.max(84, ...lines.map((l) => l.length)) + 2;
  return `<!doctype html><html><head><meta charset="utf-8"><style>
    * { box-sizing: border-box; }
    body { margin: 0; background: #11131a; font-family: "Cascadia Mono", Consolas, monospace; }
    .frame { width: ${cols}ch; }
    .bar { background: #21242e; padding: 9px 14px; display: flex; align-items: center; gap: 8px; border-radius: 8px 8px 0 0; }
    .dot { width: 11px; height: 11px; border-radius: 50%; }
    .r { background: #ec6a5e; } .y { background: #f4bf4f; } .g { background: #61c554; }
    .title { color: #9aa3b8; font-size: 12.5px; margin-left: 8px; }
    pre { margin: 0; padding: 16px 18px 20px; color: #d6dae4; font-size: 13.5px; line-height: 1.52;
          white-space: pre; background: #11131a; border-radius: 0 0 8px 8px; }
    .prompt { color: #7aa2f7; } .ok { color: #86c98b; } .warn { color: #e8c07d; } .dim { color: #7f889c; }
  </style></head><body><div class="frame">
    <div class="bar"><span class="dot r"></span><span class="dot y"></span><span class="dot g"></span>
      <span class="title">${redact(title)}</span></div>
    <pre>${lines.map(colourise).join('\n')}</pre></div></body></html>`;
}

const files = (await readdir(source)).filter((f) => /^\d\d-.+\.txt$/.test(f)).sort();
const browser = await chromium.launch();
const page = await browser.newPage({ deviceScaleFactor: 2 });
await mkdir(outDir, { recursive: true });
for (const f of files) {
  const text = (await readFile(join(source, f), 'utf8')).replace(/^\uFEFF/, '');
  const [first, ...rest] = text.split('\n');
  const title = first.replace(/^#\s*/, '').trim();
  const out = `turnstile-t${basename(f, '.txt')}.png`;
  await page.setContent(html(title, rest.join('\n')));
  await page.locator('.frame').screenshot({ path: join(outDir, out) });
  console.log(`  wrote ${join(outDir, out)}`);
}
await browser.close();
console.log(`\n${files.length} transcript(s) rendered; ${guids.size} distinct GUID(s) replaced.`);
