import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { chromium } from 'playwright';
import { createInstallerUiServer } from '../tools/installer-ui/server.mjs';

const out = resolve('docs/guide');
await mkdir(out, { recursive: true });
const scratch = await mkdtemp(resolve(tmpdir(), 'p93-ui-capture-'));
const azCmd = resolve(scratch, 'az.cmd');
await writeFile(azCmd, `@echo off\r\nnode "${azCmd.replace(/\\/g, '\\\\')}.mjs" %*\r\n`, 'utf8');
await writeFile(`${azCmd}.mjs`, `
const joined = process.argv.slice(2).join(' ');
if (joined.startsWith('account show')) { console.log(JSON.stringify({ id: '00000000-0000-4000-8000-000000000093', name: 'Capture subscription', tenantId: 'tenant-capture', user: { name: 'operator@example.invalid' } })); process.exit(0); }
if (joined.startsWith('account list')) { console.log(JSON.stringify([{ id: '00000000-0000-4000-8000-000000000093', name: 'Capture subscription', tenantId: 'tenant-capture' }])); process.exit(0); }
console.error('unexpected az ' + joined); process.exit(2);
`, 'utf8');

const server = await createInstallerUiServer({
  token: 'capture-token-with-at-least-32-bytes-0000',
  stubInstaller: resolve('tests/installer-ui-stub.mjs'),
  idleMs: 60000,
  env: {
    PATH: `${scratch};${process.env.PATH}`,
    P93_INSTALLER_UI_STUB_FAIL_STEP: 'gateway-deployment'
  }
});
const address = await server.listenAsync('127.0.0.1');
const browser = await chromium.launch({ headless: true });
try {
  const page = await browser.newPage({ viewport: { width: 1365, height: 900 }, deviceScaleFactor: 1, locale: 'en-US', timezoneId: 'UTC', reducedMotion: 'reduce' });
  await page.goto(`http://127.0.0.1:${address.port}/?token=${encodeURIComponent(server.token)}`);
  await page.getByText('operator@example.invalid').waitFor();
  await page.getByLabel('Gateway resource group').fill('rg-capture');
  await page.getByLabel('Subscription').fill('00000000-0000-4000-8000-000000000093');
  await page.screenshot({ path: resolve(out, 'installer-ui-overview.png'), fullPage: true });
  await page.getByRole('button', { name: 'Run preflight' }).click();
  await page.getByText('target.tenant').waitFor();
  await page.screenshot({ path: resolve(out, 'installer-ui-preflight.png'), fullPage: true });
  await page.getByRole('button', { name: 'List steps' }).click();
  await page.getByLabel(/gateway-deployment/).check();
  await page.getByRole('button', { name: 'Run selected steps' }).click();
  await page.waitForFunction(() => document.querySelector('#run-output')?.textContent.includes('Resume:'));
  await page.screenshot({ path: resolve(out, 'installer-ui-run.png'), fullPage: true });
} finally {
  await browser.close();
  await server.cleanup();
  server.closeAllConnections?.();
  server.close();
  await rm(scratch, { recursive: true, force: true });
}
