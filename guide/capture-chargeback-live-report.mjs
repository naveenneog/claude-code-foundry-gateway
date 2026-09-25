// Render actual generated output, replacing every supplied identity/unit before screenshotting.
import { chromium } from 'playwright';
import { readFile, mkdir } from 'node:fs/promises';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { reportRedactions, redactPortalPage, redactReportText, saveRedactedScreenshot, assertRedacted } from './lib/chargeback-redaction.mjs';

const args = process.argv.slice(2);
const option = name => { const index = args.indexOf(name); return index < 0 ? undefined : args[index + 1]; };
const dataPath = option('--data');
if (!dataPath) throw new Error('Pass --data with private live HTML path, CSV rows and redaction pairs.');
const data = JSON.parse((await readFile(resolve(dataPath), 'utf8')).replace(/^\uFEFF/, ''));
if (!data.HtmlPath || !data.Rows?.length || !data.Redactions?.length) throw new Error('Live capture data/redactions are incomplete.');
const pairs = reportRedactions(data);
const root = resolve(import.meta.dirname, '..');
const output = resolve(root, 'docs', 'images', 'chargeback-reports');
await mkdir(output, { recursive: true });
const browser = await chromium.launch({ headless: true });
try {
  const page = await browser.newPage({ viewport: { width: 1600, height: 1100 } });
  await page.goto(pathToFileURL(resolve(data.HtmlPath)).href);
  await redactPortalPage(page, pairs);
  await page.evaluate(() => {
    for (const node of document.querySelectorAll('body > div')) {
      if (node.textContent.includes('Contoso administrator')) node.remove();
      if (node.textContent.includes('Live Azure portal')) node.textContent = 'Live generated report - names, addresses and identifiers replaced with Contoso placeholders';
    }
  });
  await saveRedactedScreenshot(page, resolve(output, 'live-unit-summary.png'), 'Live generated report - identities and unit names are Contoso placeholders; measurements are unchanged', true);
  const headings = Object.keys(data.Rows[0]);
  const escape = value => String(value ?? '').replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
  const body = data.Rows.map(row => `<tr>${headings.map(key => `<td>${escape(redactReportText(row[key] ?? '', pairs))}</td>`).join('')}</tr>`).join('');
  await page.setContent(`<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Live report CSV</title>
  <style>body{font:14px "Segoe UI",Arial;margin:28px;color:#242424}table{font-size:12px;border-collapse:collapse;width:100%}td,th{padding:10px;border:1px solid #d4d8e2;text-align:left;overflow-wrap:anywhere}th{background:#edf2f8}h1{font-size:24px;color:#1e2761}</style></head>
  <body><h1>Live unit CSV - ${escape(data.Month)}</h1><p>Actual exported rows, displayed as a table. Identities and unit names are Contoso placeholders; token and cost values are unchanged. Blank cache writes mean unknown.</p>
  <table><thead><tr>${headings.map(key => `<th scope="col">${escape(key)}</th>`).join('')}</tr></thead><tbody>${body}</tbody></table></body></html>`);
  assertRedacted(await page.locator('body').innerText(), pairs);
  await page.screenshot({ path: resolve(output, 'live-unit-csv.png'), fullPage: true });
  console.log(`Captured live report and ${data.Rows.length} CSV row(s), fully redacted.`);
} finally {
  await browser.close();
}
