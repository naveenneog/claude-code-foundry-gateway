#!/usr/bin/env node
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { dirname, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  IMAGE_DIR, MANIFEST, fault, inputsFor, loadSpecs, localPath, sha256, text, validateSpecs, walk, withSourceSnapshot,
} from './architecture-model.mjs';

export function checkArchitecture(root) {
  return withSourceSnapshot(root, () => checkSnapshot(root));
}

function checkSnapshot(root) {
  const loaded = loadSpecs(root);
  const errors = [...loaded.errors, ...validateSpecs(root, loaded.specs)];
  let manifest;
  try {
    manifest = JSON.parse(text(root, MANIFEST));
    if (manifest.version !== 1 || !Array.isArray(manifest.diagrams)) throw new Error('Invalid manifest schema');
  } catch (error) { return [...errors, fault('MANIFEST_MISSING', error.message)]; }
  const entries = new Map(manifest.diagrams.map(entry => [entry.id, entry]));
  if (entries.size !== manifest.diagrams.length) errors.push(fault('MANIFEST_INVALID', 'Duplicate diagram id'));
  const owned = new Set(), referenced = new Set();
  const docs = [...walk(root, 'docs', '.md'), ...readdirSync(root).filter(p => p.endsWith('.md'))];
  for (const doc of docs) {
    const content = text(root, doc);
    const references = [
      ...content.matchAll(/!\[[^\]]*\]\(<?([^)\s>]+\.png)>?(?:\s+["'][^"']*["'])?\)/g),
      ...content.matchAll(/<img\b[^>]*\bsrc=["']([^"']+\.png)["']/g),
    ];
    for (const match of references) {
      if (/^https?:/i.test(match[1])) continue;
      const full = resolve(dirname(localPath(root, doc)), decodeURI(match[1]));
      referenced.add(relative(root, full).replaceAll('\\', '/'));
    }
  }
  for (const spec of loaded.specs) {
    const entry = entries.get(spec.id);
    if (!entry) errors.push(fault('SOURCE_UNRENDERED', spec.file));
    if (entry) {
      try {
        const current = inputsFor(root, spec);
        if (entry.source !== spec.file || JSON.stringify(current) !== JSON.stringify(entry.inputs)) {
          const changed = [...new Set([...Object.keys(current), ...Object.keys(entry.inputs ?? {})])]
            .filter(path => current[path] !== entry.inputs?.[path]);
          errors.push(fault('SOURCE_STALE', `${spec.id}: ${changed.join(', ') || 'source path changed'}`));
        }
      } catch (error) { errors.push(fault('SOURCE_MISSING', `${spec.id}: ${error.message}`)); }
      const recorded = (entry.outputs ?? []).map(output => output.path);
      if (JSON.stringify(recorded) !== JSON.stringify(spec.outputs)) errors.push(fault('MANIFEST_INVALID', `${spec.id}: output list changed`));
      if (new Set((entry.outputs ?? []).map(output => output.sha256)).size > 1) {
        errors.push(fault('IMAGE_ALIAS_MISMATCH', spec.id));
      }
    }
    for (const output of spec.outputs) {
      owned.add(output);
      try {
        const path = localPath(root, output);
        if (!existsSync(path)) errors.push(fault('IMAGE_MISSING', output));
        else {
          const record = entry?.outputs?.find(item => item.path === output);
          const image = readFileSync(path);
          if (record?.sha256 !== sha256(image)) errors.push(fault('IMAGE_STALE', output));
          if (!image.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) {
            errors.push(fault('IMAGE_INVALID', output));
          }
        }
      } catch (error) { errors.push(error.message); }
      if (!referenced.has(output)) errors.push(fault('IMAGE_UNREFERENCED', output));
    }
  }
  for (const path of [...walk(root, IMAGE_DIR, ''), 'docs/images/architecture.png', 'docs/images/request-flow.png']) {
    if (!owned.has(path)) errors.push(fault('IMAGE_ORPHAN', path));
  }
  for (const entry of manifest.diagrams) {
    if (!loaded.specs.some(spec => spec.id === entry.id)) errors.push(fault('MANIFEST_ORPHAN', entry.id));
  }
  return [...new Set(errors)];
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  if (args.length && (args.length !== 2 || args[0] !== '--root')) {
    console.error('Usage: node guide/check-architecture.mjs [--root <repository>]');
    process.exitCode = 1;
  } else {
    const root = args.length ? resolve(args[1]) : resolve(dirname(fileURLToPath(import.meta.url)), '..');
    try {
      const errors = checkArchitecture(root);
      if (errors.length) { console.error(errors.join('\n')); process.exitCode = 1; }
      else console.log('Architecture PASS: sources, renderer, PNG hashes, references, labels and Azure resource coverage agree.');
    } catch (error) { console.error(fault('CHECK_FAILED', error.message)); process.exitCode = 1; }
  }
}
