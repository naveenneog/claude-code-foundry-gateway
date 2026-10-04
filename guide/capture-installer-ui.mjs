import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
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
    P93_INSTALLER_UI_STUB_FAIL_STEP: 'gateway-deployment',
    P93_INSTALLER_UI_STUB_SIGNED_IN: '1',
    P93_INSTALLER_UI_STUB_USER: 'operator@example.invalid',
    P93_INSTALLER_UI_STUB_TENANT: 'tenant-capture',
  }
});
const address = await server.listenAsync('127.0.0.1');
const browser = await chromium.launch({ headless: true });
try {
  const page = await browser.newPage({ viewport: { width: 1365, height: 900 }, deviceScaleFactor: 1, locale: 'en-US', timezoneId: 'UTC', reducedMotion: 'reduce' });
  await page.goto(`http://127.0.0.1:${address.port}/?token=${encodeURIComponent(server.token)}`);
  async function assertCoherentTenant() {
    const banner = await page.locator('#identity').textContent();
    if (!/operator@example.invalid/.test(banner || '')) throw new Error(`capture identity mismatch: ${banner}`);
    const tenantRows = await page.locator('tr', { hasText: 'target.tenant' }).count();
    if (!tenantRows) return;
    const tenantResult = await page.locator('tr', { hasText: 'target.tenant' }).locator('td').nth(1).textContent();
    const tenantMessage = await page.locator('tr', { hasText: 'target.tenant' }).locator('td').nth(2).textContent();
    if (tenantResult !== 'PASS' || !/signed in as operator@example.invalid in tenant tenant-capture/.test(tenantMessage || '')) throw new Error(`capture identity mismatch: ${banner} / ${tenantResult} / ${tenantMessage}`);
  }
  async function capture(name) {
    await assertCoherentTenant();
    await page.screenshot({ path: resolve(out, name), fullPage: true });
  }
  await page.getByText('operator@example.invalid').waitFor();
  await page.getByLabel('Gateway resource group').fill('rg-capture');
  await page.getByLabel('Subscription').fill('00000000-0000-4000-8000-000000000093');
  await page.getByRole('button', { name: 'List steps' }).click();
  await page.getByLabel(/gateway-deployment/).check();
  await capture('installer-ui-overview.png');
  await page.getByRole('button', { name: 'Run preflight' }).click();
  await page.getByText('target.tenant').waitFor();
  await capture('installer-ui-preflight.png');
  await page.getByRole('button', { name: 'Run selected steps' }).click();
  await page.waitForFunction(() => document.querySelector('#run-output')?.textContent.includes('Resume:'));
  await capture('installer-ui-run.png');
  const hashes = await Promise.all(['installer-ui-overview.png', 'installer-ui-preflight.png', 'installer-ui-run.png'].map(async (name) => createHash('sha256').update(await readFile(resolve(out, name))).digest('hex')));
  if (new Set(hashes).size !== hashes.length) throw new Error(`capture produced duplicate PNG hashes: ${hashes.join(', ')}`);
} finally {
  await browser.close();
  await server.cleanup();
  server.closeAllConnections?.();
  server.close();
  await rm(scratch, { recursive: true, force: true });
}
