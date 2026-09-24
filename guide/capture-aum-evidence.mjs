// Render redacted, measured API receipts. This is not a fabricated portal view.
// No browser authentication/profile is used and no live response identities are rendered.
import fs from 'node:fs';
import path from 'node:path';
import { chromium } from 'playwright';

const load = file => JSON.parse(fs.readFileSync(path.join('.aum-local', file), 'utf8').replace(/^\uFEFF/, ''));
const evidence = load('live-evidence.json');
const reads = load('live-reads.json');
const cleanPath = p => p
  .replace(/pilot-[a-f0-9]{8}-unit/g, 'contoso-unit')
  .replace(/pilot-[a-f0-9]{8}-team/g, 'contoso-team')
  .replace(/pilot-[a-f0-9]{8}-other/g, 'contoso-other-team')
  .replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi, '<record-id>')
  .replace(/search=[^&]+/g, 'search=<redacted>');
const line = e => `${e.utc}  ${String(e.status).padStart(3)}  ${e.method ?? 'GET'} ${cleanPath(e.path)}`;
const proof = name => {
  const entry = evidence.find(e => e.flow === name);
  if (!entry?.passed) throw new Error(`No successful live receipt for ${name}`);
  return `${entry.utc}  PASS ${name}`;
};
const scenarios = [
  ['aum-09-live-reads', 'Authenticated reads, no Turnstile',
    reads.map(line).join('\n') + '\n\n' +
    evidence.filter(e => e.status === 401).map(line).join('\n'),
    'Real Function responses; no token, account name, hostname or object id is shown.'],
  ['aum-10-live-writes', 'Budget authority and request decisions',
    evidence.filter(e => e.method && e.method !== 'GET' && !e.path?.startsWith('boosts')).map(line).join('\n') +
    '\n\n' + proof('budget-restored-byte-identically'),
    '409 proves headroom denial; 403 proves default self-approval denial. Administrator override was explicit and audited.'],
  ['aum-11-live-expiry', 'The timer restored the gateway budget',
    evidence.filter(e => e.path?.startsWith('boosts')).map(line).join('\n') +
    '\n\n' + proof('timer-restored-byte-identically'),
    'Expiry was performed by the scheduled Azure Function, not by a manual timer invocation or a local fake.'],
];
const escape = s => String(s).replace(/[<>&"]/g, c => ({'<':'&lt;','>':'&gt;','&':'&amp;','"':'&quot;'})[c]);
fs.mkdirSync(path.join('.aum-local', 'api-evidence-profile'), { recursive: true });
const context = await chromium.launchPersistentContext(path.resolve('.aum-local', 'api-evidence-profile'), {
  channel: 'msedge', headless: true, viewport: { width: 1500, height: 1050 },
});
try {
  const page = context.pages()[0] ?? await context.newPage();
  for (const [file, title, text, note] of scenarios) {
    const html = `<!doctype html><html><head><meta charset="utf-8"><style>
      body{margin:0;background:#101b28;color:#e7eef5;font-family:Segoe UI,sans-serif;padding:40px}
      h1{font-size:30px;margin:8px 0 20px}p{font-size:18px;line-height:1.5;color:#bcd0e0}
      small{color:#72d4ab;font-size:16px;letter-spacing:1px}
      pre{white-space:pre-wrap;overflow-wrap:anywhere;font:16px/1.7 Consolas,monospace;padding:24px;
      border:1px solid #446075;border-radius:8px;background:#0b131d}
      footer{font-size:16px;color:#bcd0e0;margin-top:22px}
    </style></head><body><small>AUM SERVICE | MEASURED API RECEIPTS</small>
      <h1>${escape(title)}</h1><p>${escape(note)}</p><pre>${escape(text)}</pre>
      <footer>Live Azure results rendered from saved receipts. UTC timestamps retained; identifiers replaced with Contoso placeholders.</footer>
    </body></html>`;
    await page.setContent(html);
    const height = await page.evaluate(() => document.documentElement.scrollHeight);
    await page.setViewportSize({ width: 1500, height: Math.max(900, Math.min(height, 1800)) });
    await page.screenshot({ path: path.join('docs', 'guide', `${file}.png`), fullPage: true });
    console.log(`Rendered measured receipts: ${file}`);
  }
} finally {
  await context.close();
}
