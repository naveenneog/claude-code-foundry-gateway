// Only renders the Contoso fixture produced by Test-ChargebackReports.ps1.
import { chromium } from 'playwright';
import { readFile, mkdir } from 'node:fs/promises';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { execFileSync } from 'node:child_process';
import assert from 'node:assert/strict';

const root = resolve(import.meta.dirname, '..');
const fixture = resolve(root, '.chargeback-fixture');
execFileSync('pwsh', ['-NoProfile', '-File', resolve(root, 'tests', 'Test-ChargebackReports.ps1'), '-KeepOutput', fixture], { cwd: root, stdio: 'inherit' });
const output = resolve(root, 'docs', 'images', 'chargeback-reports');
await mkdir(output, { recursive: true });
const browser = await chromium.launch({ headless: true });
try {
  const page = await browser.newPage({ viewport: { width: 1180, height: 1600 }, deviceScaleFactor: 1 });
  await page.goto(pathToFileURL(resolve(fixture, 'engineering.html')).href);
  assert.equal(await page.locator('h1').innerText(), 'Contoso Engineering');
  assert.equal(await page.locator('script').count(), 0);
  assert.ok((await page.locator('body').innerText()).includes('list price'));
  assert.ok(!(await page.locator('body').innerText()).includes('carol@contoso.com'));
  const remoteRequests = [];
  page.on('request', request => { if (request.url().startsWith('http')) remoteRequests.push(request.url()); });
  await page.screenshot({ path: resolve(output, 'unit-summary.png'), fullPage: true });
  await page.setViewportSize({ width: 390, height: 844 });
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
  assert.equal(remoteRequests.length, 0, 'report must not fetch remote assets or tracking pixels');
  await page.setViewportSize({ width: 1600, height: 950 });
  const csv = await readFile(resolve(fixture, 'engineering.csv'), 'utf8');
  const rows = parseCsv(csv.replace(/^\uFEFF/, ''));
  assert.equal(rows.length, 3, 'header and two engineering people');
  const escape = value => value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
  const header = rows[0].map(value => `<th scope="col">${escape(value)}</th>`).join('');
  const body = rows.slice(1).map(row => `<tr>${row.map(value => `<td>${escape(value)}</td>`).join('')}</tr>`).join('');
  await page.setContent(`<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Contoso report CSV</title>
    <style>body{margin:36px;font:14px "Segoe UI",Arial,sans-serif;color:#1a1a1a;background:#f4f5f7}h1{color:#1e2761;font-size:26px}p{color:#374151;max-width:75ch;line-height:1.5}table{border-collapse:collapse;background:white;font-size:12px}th,td{border:1px solid #d4d8e2;padding:12px 9px;text-align:left;overflow-wrap:anywhere;max-width:180px}th{background:#e8edf5;font-weight:600}caption{text-align:left;margin:16px 0;color:#374151}</style></head>
    <body><h1>Contoso Engineering - exported CSV</h1><p>2024-02 / UTC. Fixture data, not a live deployment. The quoted CSV is displayed as a table; it is not a screenshot of Excel. Blank cache-write cells mean unknown, not zero. Formula-like names are prefixed with an apostrophe.</p>
    <table><caption>engineering.csv - every person in this unit, no cross-unit rows</caption><thead><tr>${header}</tr></thead><tbody>${body}</tbody></table></body></html>`);
  assert.equal(await page.locator('tbody tr').count(), 2);
  await page.screenshot({ path: resolve(output, 'unit-csv-table.png'), fullPage: true });
  console.log('2 fixture screenshots captured; HTML escaping, privacy, mobile overflow and CSV rows verified.');
} finally {
  await browser.close();
}

function parseCsv(text) {
  const rows = [];
  let row = [], cell = '', quoted = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (ch === '"') {
      if (quoted && text[i + 1] === '"') { cell += '"'; i++; } else quoted = !quoted;
    } else if (ch === ',' && !quoted) { row.push(cell); cell = ''; }
    else if ((ch === '\r' || ch === '\n') && !quoted) {
      if (ch === '\r' && text[i + 1] === '\n') i++;
      row.push(cell); rows.push(row); row = []; cell = '';
    } else cell += ch;
  }
  if (quoted) throw new Error('CSV ends inside a quoted cell');
  if (row.length || cell) { row.push(cell); rows.push(row); }
  return rows;
}
