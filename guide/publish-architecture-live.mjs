#!/usr/bin/env node
import { createHash } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { copyFile, mkdir, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { publicCaptureReceipt } from './architecture-live.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const ids = process.argv.slice(2);
if (!ids.length || ids.some(id => !/^[a-z0-9-]+$/.test(id))) {
  throw new Error('After viewing each staged image, pass its explicit capture id. There is no publish-all default.');
}
const staged = join(root, '.shots-entra', 'architecture-live');
const receipts = JSON.parse(readFileSync(join(staged, 'captures.json'), 'utf8')).captures;
const destination = join(root, 'docs', 'images', 'architecture-live');
await mkdir(destination, { recursive: true });
const manifestPath = join(destination, 'captures.json');
const current = existsSync(manifestPath) ? JSON.parse(readFileSync(manifestPath, 'utf8')).captures : [];
const byId = new Map(current.map(receipt => [receipt.id, receipt]));
for (const id of ids) {
  const receipt = receipts.find(item => item.id === id && item.status === 'captured');
  if (!receipt) throw new Error(`${id}: no successful staged capture`);
  const source = join(staged, 'redacted', `${id}.png`);
  const bytes = readFileSync(source);
  if (createHash('sha256').update(bytes).digest('hex') !== receipt.sha256) {
    throw new Error(`${id}: staged pixels no longer match the reviewed receipt`);
  }
  await copyFile(source, join(destination, `${id}.png`));
  byId.set(id, publicCaptureReceipt(receipt));
  console.log(`${id}: published reviewed capture`);
}
await writeFile(manifestPath, JSON.stringify({ version: 1, captures: [...byId.values()].sort((a, b) => a.id.localeCompare(b.id)) }, null, 2) + '\n');
