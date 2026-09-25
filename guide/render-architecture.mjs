#!/usr/bin/env node
/**
 * Deterministic HTML/SVG, not image-model lettering. ApiManagementGatewayLlmLog
 * and the measured 38.7% cache caveat are source-backed labels, not invented art.
 *
 * node guide/render-architecture.mjs       render every spec, then write hashes
 * node guide/check-architecture.mjs        offline check, no browser required
 *
 * Add one docs/architecture/*.json spec and reference its PNG in the concept
 * article. No switch statement or hard-coded diagram list needs changing.
 */
import { randomUUID } from 'node:crypto';
import { mkdir, rm, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { diagramHtml } from './architecture-layout.mjs';
import { MANIFEST, inputsFor, loadSpecs, localPath, sha256, validateSpecs } from './architecture-model.mjs';
import { checkArchitecture } from './check-architecture.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const loaded = loadSpecs(root);
const problems = [...loaded.errors, ...validateSpecs(root, loaded.specs)];
if (problems.length) throw new Error(problems.join('\n'));

// Playwright's profiles and browser artifacts stay in this checkout. Nothing
// reads the operator's browser state, and no diagram makes a network request.
const workspace = join(root, 'guide', `.architecture-render-${randomUUID()}`);
await mkdir(workspace, { recursive: true });
const oldEnvironment = { TMPDIR: process.env.TMPDIR, TEMP: process.env.TEMP, TMP: process.env.TMP };
for (const key of Object.keys(oldEnvironment)) process.env[key] = workspace;
let browser;
try {
  const { chromium } = await import('playwright');
  browser = await chromium.launch({ headless: true });
  const images = new Map(), diagrams = [];
  for (const spec of loaded.specs) {
    const page = await browser.newPage({
      viewport: { width: spec.width + 64, height: 900 }, deviceScaleFactor: 2,
      locale: 'en-US', timezoneId: 'UTC', colorScheme: 'light', reducedMotion: 'reduce',
    });
    await page.route('**/*', route => route.abort());
    await page.setContent(diagramHtml(spec), { waitUntil: 'load' });
    await page.evaluate(() => document.fonts.ready);
    const overflow = await page.locator('[data-fit]').evaluateAll(nodes =>
      nodes.filter(node => node.scrollHeight > node.clientHeight + 1 || node.scrollWidth > node.clientWidth + 1)
        .map(node => node.dataset.fit));
    if (overflow.length) throw new Error(`${spec.id}: labels overflow ${overflow.join(', ')}`);
    const png = await page.locator('.sheet').screenshot({ animations: 'disabled' });
    const outputs = spec.outputs.map(path => {
      images.set(path, png);
      return { path, sha256: sha256(png) };
    });
    diagrams.push({ id: spec.id, source: spec.file, inputs: inputsFor(root, spec), outputs });
    await page.close();
  }
  // Nothing is published until every diagram has rendered without clipped text.
  for (const [path, png] of images) {
    const output = localPath(root, path);
    await mkdir(dirname(output), { recursive: true });
    await writeFile(output, png);
    console.log(`wrote ${path}`);
  }
  await writeFile(localPath(root, MANIFEST), JSON.stringify({ version: 1, diagrams }, null, 2) + '\n');
  const errors = checkArchitecture(root);
  if (errors.length) throw new Error(errors.join('\n'));
  console.log(`Architecture: ${diagrams.length} specs, ${images.size} PNGs, source and image SHA-256 verified.`);
} finally {
  if (browser) await browser.close();
  for (const [key, value] of Object.entries(oldEnvironment)) {
    if (value === undefined) delete process.env[key]; else process.env[key] = value;
  }
  await rm(workspace, { recursive: true, force: true });
}
