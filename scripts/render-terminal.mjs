/**
 * Renders captured terminal output to a PNG that looks like a terminal.
 *
 * Window screenshots of a real console were tried first and rejected: they pick
 * up whatever else is on screen, vary with DPI, and leak the operator's prompt
 * and paths. Rendering the captured text instead is reproducible, crops to
 * exactly the content, and cannot leak anything that was not in the output.
 *
 *   node render-terminal.mjs <input.txt> <output.png> ["Title"]
 *
 * ANSI SGR colours are honoured, so the scripts' own [OK]/[WARN]/[FAIL]
 * highlighting survives into the image.
 */
import fs from 'node:fs';
import path from 'node:path';
import { chromium } from 'playwright';

const [, , inFile, outFile, title = 'PowerShell'] = process.argv;
if (!inFile || !outFile) {
  console.error('usage: node render-terminal.mjs <input.txt> <output.png> ["Title"]');
  process.exit(1);
}

const PALETTE = {
  30: '#5c6370', 31: '#e06c75', 32: '#98c379', 33: '#e5c07b',
  34: '#61afef', 35: '#c678dd', 36: '#56b6c2', 37: '#dcdfe4',
  90: '#7f848e', 91: '#e06c75', 92: '#98c379', 93: '#e5c07b',
  94: '#61afef', 95: '#c678dd', 96: '#56b6c2', 97: '#ffffff',
};

const esc = (s) =>
  s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

/** Minimal SGR handling: colour and bold, which is all the scripts emit. */
function ansiToHtml(text) {
  let out = '';
  let open = false;
  let i = 0;

  while (i < text.length) {
    const m = /\u001b\[([0-9;]*)m/.exec(text.slice(i, i + 12));
    if (m && m.index === 0) {
      const codes = m[1].split(';').filter(Boolean).map(Number);
      if (open) { out += '</span>'; open = false; }
      const colour = codes.map((c) => PALETTE[c]).filter(Boolean).pop();
      const bold = codes.includes(1);
      if (colour || bold) {
        out += `<span style="${colour ? `color:${colour};` : ''}${bold ? 'font-weight:600;' : ''}">`;
        open = true;
      }
      i += m[0].length;
      continue;
    }
    out += esc(text[i]);
    i++;
  }
  if (open) out += '</span>';
  return out;
}

const raw = fs.readFileSync(inFile, 'utf8').replace(/\r\n/g, '\n').replace(/\s+$/, '');

/**
 * Colours by meaning rather than by ANSI codes.
 *
 * Write-Host colours never reach a redirected stream, so the captured text is
 * plain. Re-deriving colour from the markers the scripts already emit gives an
 * image that matches what the operator sees on a real console.
 */
function colourise(text) {
  return text
    .split('\n')
    .map((line) => {
      const e = esc(line);
      if (/^={10,}/.test(line)) return `<span style="color:#56b6c2">${e}</span>`;
      if (/^-{10,}/.test(line.trim())) return `<span style="color:#5c6370">${e}</span>`;
      if (/^==>/.test(line)) return `<span style="color:#56b6c2;font-weight:600">${e}</span>`;
      if (/^\s+\[OK\]/.test(line))
        return e.replace(/(\[OK\])/, '<span style="color:#98c379;font-weight:600">$1</span>');
      if (/^\s+\[WARN\]/.test(line))
        return e.replace(/(\[WARN\])/, '<span style="color:#e5c07b;font-weight:600">$1</span>');
      if (/^\s+\[FAIL\]/.test(line))
        return e.replace(/(\[FAIL\])/, '<span style="color:#e06c75;font-weight:600">$1</span>');
      // Prompts: "  Label [default]: typed"
      const p = /^(\s+)(.*?)(\[[^\]]*\]):(.*)$/.exec(line);
      if (p) {
        return `${p[1]}<span style="color:#ffffff">${esc(p[2])}</span>` +
               `<span style="color:#7f848e">${esc(p[3])}</span>` +
               `<span style="color:#7f848e">:</span>` +
               `<span style="color:#e5c07b;font-weight:600">${esc(p[4])}</span>`;
      }
      // Section titles inside banners.
      if (/^\s[A-Z]/.test(line)) return `<span style="color:#56b6c2">${e}</span>`;
      // Indented detail.
      if (/^\s{4,}/.test(line)) return `<span style="color:#8a909c">${e}</span>`;
      return e;
    })
    .join('\n');
}

const body = colourise(raw);

const html = `<!doctype html>
<html><head><meta charset="utf-8"><style>
  * { box-sizing: border-box; }
  body { margin:0; background:#12141a; padding:22px; }
  .win { background:#1b1e26; border-radius:9px; overflow:hidden;
         box-shadow:0 10px 34px rgba(0,0,0,.45); border:1px solid #2a2f3a; }
  .bar { background:#22262f; padding:9px 14px; display:flex; align-items:center; gap:8px;
         border-bottom:1px solid #2a2f3a; }
  .dot { width:11px; height:11px; border-radius:50%; }
  .t   { color:#9aa2b1; font:12.5px 'Segoe UI',system-ui,sans-serif; margin-left:7px; }
  pre  { margin:0; padding:17px 20px; color:#dcdfe4; background:#1b1e26;
         font:13px/1.55 Consolas,'Cascadia Mono','SF Mono',Menlo,monospace;
         white-space:pre; }
</style></head>
<body>
  <div class="win">
    <div class="bar">
      <div class="dot" style="background:#ff5f57"></div>
      <div class="dot" style="background:#febc2e"></div>
      <div class="dot" style="background:#28c840"></div>
      <div class="t">${esc(title)}</div>
    </div>
    <pre>${body}</pre>
  </div>
</body></html>`;

const tmp = path.join(path.dirname(path.resolve(outFile)), '.terminal.tmp.html');
fs.mkdirSync(path.dirname(path.resolve(outFile)), { recursive: true });
fs.writeFileSync(tmp, html, 'utf8');

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1180, height: 800 }, deviceScaleFactor: 2 });
await page.goto('file:///' + tmp.replace(/\\/g, '/'));
await page.waitForTimeout(350);
const el = await page.locator('.win');
await el.screenshot({ path: path.resolve(outFile) });
await browser.close();
fs.unlinkSync(tmp);

const kb = Math.round(fs.statSync(path.resolve(outFile)).size / 1024);
console.log(`  ${path.basename(outFile)}  ${kb} KB`);
