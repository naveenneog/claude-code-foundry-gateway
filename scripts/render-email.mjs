// Renders the generated onboarding email so it can be eyeballed before anyone
// sends it to a person.
import { chromium } from 'playwright';
import path from 'node:path';

const file = process.argv[2];
if (!file) { console.error('usage: node render-email.mjs <html>'); process.exit(1); }

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 760, height: 1400 }, deviceScaleFactor: 2 });
await page.goto('file:///' + path.resolve(file).replace(/\\/g, '/'));
await page.waitForTimeout(700);
const out = path.resolve('onboarding/email-preview.png');
await page.screenshot({ path: out, fullPage: true });
console.log(out);
await browser.close();
