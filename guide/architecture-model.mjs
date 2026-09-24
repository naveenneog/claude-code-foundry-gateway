import { createHash } from 'node:crypto';
import { existsSync, lstatSync, readFileSync, readdirSync, realpathSync } from 'node:fs';
import { dirname, isAbsolute, relative, resolve, sep } from 'node:path';

export const SPEC_DIR = 'docs/architecture';
export const IMAGE_DIR = 'docs/images/architecture';
export const MANIFEST = `${SPEC_DIR}/manifest.json`;
export const SHARED_INPUTS = [
  'guide/render-architecture.mjs', 'guide/architecture-model.mjs',
  'guide/architecture-layout.mjs', 'package-lock.json',
];
export const TONES = ['blue', 'teal', 'purple', 'amber', 'slate'];

export function fault(code, detail) {
  return `${code}: ${detail}`;
}

export function localPath(root, path) {
  if (typeof path !== 'string' || !path || path.includes('\\') ||
      isAbsolute(path) || /^[a-z]+:/i.test(path) || path.split('/').some(p => !p || p === '..' || p === '.')) {
    throw new Error(fault('PATH_UNSAFE', String(path)));
  }
  const result = resolve(root, ...path.split('/'));
  const back = relative(root, result);
  if (back.startsWith(`..${sep}`) || isAbsolute(back)) throw new Error(fault('PATH_UNSAFE', path));
  // Check the nearest existing ancestor too: an output may not exist yet,
  // while its parent is a junction pointing outside the checkout.
  let ancestor = result;
  while (!lstatSync(ancestor, { throwIfNoEntry: false })) ancestor = dirname(ancestor);
  let physical;
  try { physical = resolve(realpathSync(ancestor), relative(ancestor, result)); }
  catch { throw new Error(fault('PATH_UNSAFE', `${path}: unresolved link`)); }
  const physicalBack = relative(realpathSync(root), physical);
  if (physicalBack.startsWith(`..${sep}`) || isAbsolute(physicalBack)) {
    throw new Error(fault('PATH_UNSAFE', `${path}: link leaves repository`));
  }
  return result;
}

export function text(root, path) {
  return readFileSync(localPath(root, path), 'utf8').replace(/^\uFEFF/, '').replace(/\r\n/g, '\n');
}

export function sha256(value) {
  return createHash('sha256').update(value).digest('hex');
}

export function walk(root, path, extension) {
  const directory = localPath(root, path);
  if (!existsSync(directory)) return [];
  return readdirSync(directory, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name, 'en'))
    .flatMap(entry => {
      if (entry.isSymbolicLink()) throw new Error(fault('PATH_UNSAFE', `${path}/${entry.name}: symlink in input inventory`));
      return entry.isDirectory() ? walk(root, `${path}/${entry.name}`, extension)
        : entry.isFile() && entry.name.endsWith(extension) ? [`${path}/${entry.name}`] : [];
    });
}

export function loadSpecs(root) {
  const specs = [], errors = [];
  for (const file of walk(root, SPEC_DIR, '.json').filter(p => p !== MANIFEST)) {
    try {
      const spec = JSON.parse(text(root, file));
      if (spec.version !== 1 || !/^[a-z0-9-]+$/.test(spec.id) || !spec.title ||
          !['flow', 'inventory'].includes(spec.kind) || !Array.isArray(spec.outputs) ||
          !spec.outputs.length || !Array.isArray(spec.sources) || typeof spec.identifiers !== 'object') {
        throw new Error('Expected version, id, title, kind, outputs, sources and identifiers');
      }
      specs.push({ ...spec, file });
    } catch (error) { errors.push(fault('SPEC_INVALID', `${file}: ${error.message}`)); }
  }
  if (!specs.length) errors.push(fault('SPEC_MISSING', SPEC_DIR));
  return { specs, errors };
}

export function labelText(spec, value, decorate = v => v) {
  return String(value ?? '').replace(/\[\[([a-z0-9-]+)\]\]/g, (_, key) => {
    const identifier = spec.identifiers[key];
    if (!identifier) throw new Error(fault('IDENTIFIER_UNBOUND', `${spec.id}: ${key}`));
    return decorate(identifier.label);
  });
}

export function visualStrings(spec) {
  const strings = [spec.title, spec.subtitle, spec.notice ?? ''];
  if (spec.kind === 'flow') {
    for (const group of spec.groups ?? []) strings.push(group.title, group.subtitle ?? '');
    for (const node of spec.nodes ?? []) strings.push(node.title, node.eyebrow ?? '', ...(node.lines ?? []));
    for (const edge of spec.edges ?? []) strings.push(edge.label ?? '');
  } else {
    for (const section of spec.sections ?? []) strings.push(section.title, section.note, ...section.types);
  }
  return strings.filter(Boolean);
}

function sourceFor(root, spec, id) {
  if (id.source) return { path: id.source, content: text(root, id.source) };
  const upstream = spec.upstream?.[id.upstream];
  if (!upstream || !/^[a-z0-9-]+\/[a-z0-9-]+$/i.test(upstream.repository) ||
      !/^[a-f0-9]{40}$/.test(upstream.revision) || !upstream.path || !upstream.excerpt) {
    throw new Error('An external label needs a pinned repository, revision, path and code excerpt');
  }
  // A pending feature automatically switches to the real file once merged.
  if (upstream.repository === 'naveenneog/claude-code-foundry-gateway' &&
      existsSync(localPath(root, upstream.path))) {
    return { path: upstream.path, content: text(root, upstream.path) };
  }
  return { path: null, content: upstream.excerpt };
}

export function inputsFor(root, spec) {
  const paths = new Set([spec.file, ...SHARED_INPUTS, ...spec.sources]);
  for (const identifier of Object.values(spec.identifiers)) {
    const source = sourceFor(root, spec, identifier);
    if (source.path) paths.add(source.path);
  }
  return Object.fromEntries([...paths].sort().map(path => [path, sha256(text(root, path))]));
}

// Tokens, not a regex over comments: a commented example or bootstrap string
// is not a resource declaration. Relative child types fail visibly, not silently.
export function bicepResources(source) {
  const tokens = [];
  for (let i = 0; i < source.length;) {
    if (/\s/.test(source[i])) { i++; continue; }
    if (source.startsWith('//', i)) { const end = source.indexOf('\n', i); i = end < 0 ? source.length : end; continue; }
    if (source.startsWith('/*', i)) { const end = source.indexOf('*/', i + 2); i = end < 0 ? source.length : end + 2; continue; }
    if (source.startsWith("'''", i)) {
      const end = source.indexOf("'''", i + 3);
      tokens.push({ type: 'string', value: '' }); i = end < 0 ? source.length : end + 3; continue;
    }
    if (source[i] === "'") {
      let value = ''; i++;
      while (i < source.length && source[i] !== "'") {
        if (source[i] === '\\') { value += source[i + 1] ?? ''; i += 2; }
        else value += source[i++];
      }
      i++; tokens.push({ type: 'string', value }); continue;
    }
    const word = /^[a-zA-Z_][a-zA-Z0-9_-]*/.exec(source.slice(i));
    if (word) { tokens.push({ type: 'word', value: word[0] }); i += word[0].length; }
    else { tokens.push({ type: 'punctuation', value: source[i++] }); }
  }
  const resources = [];
  for (let i = 0; i < tokens.length - 2; i++) {
    if (tokens[i].type !== 'word' || tokens[i].value !== 'resource' ||
        tokens[i + 1].type !== 'word' || tokens[i + 2].type !== 'string') continue;
    const type = tokens[i + 2].value.split('@')[0];
    if (!/^Microsoft\.[A-Za-z]+\/[A-Za-z0-9/]+$/.test(type)) {
      throw new Error(fault('RESOURCE_UNRESOLVED', type));
    }
    resources.push(type);
  }
  return resources;
}

export function validateSpecs(root, specs) {
  const errors = [], outputs = new Set(), ids = new Set(), represented = new Set(), externalResources = new Set();
  for (const spec of specs) {
    if (ids.has(spec.id)) errors.push(fault('SPEC_DUPLICATE', spec.id));
    ids.add(spec.id);
    for (const output of spec.outputs) {
      try {
        localPath(root, output);
        if (!/^docs\/images\/architecture\/[a-z0-9-]+\.png$/.test(output) &&
            !['docs/images/architecture.png', 'docs/images/request-flow.png'].includes(output)) {
          throw new Error(fault('PATH_UNSAFE', output));
        }
        if (outputs.has(output)) errors.push(fault('OUTPUT_DUPLICATE', output));
        outputs.add(output);
      } catch (error) { errors.push(error.message); }
    }
    const rendered = [];
    for (const value of visualStrings(spec)) {
      try { rendered.push(labelText(spec, value)); }
      catch (error) { errors.push(error.message); }
    }
    const allText = rendered.join('\n');
    for (const [key, identifier] of Object.entries(spec.identifiers)) {
      try {
        const source = sourceFor(root, spec, identifier);
        if (!identifier.label || !allText.includes(identifier.label)) {
          throw new Error('The declared label is not drawn');
        }
        if (identifier.kind === 'file') {
          if (!source.path || !source.path.endsWith(`/${identifier.label}`)) throw new Error('File label must name its own source');
        } else if (!identifier.match || !source.content.includes(identifier.match)) {
          throw new Error(`Missing code witness: ${identifier.match ?? identifier.label}`);
        }
        if (identifier.kind === 'resource') {
          const type = identifier.label.toLowerCase();
          const witnessPath = identifier.source ?? spec.upstream?.[identifier.upstream]?.path;
          if (!witnessPath?.endsWith('.bicep') ||
              !bicepResources(source.content).some(declared => declared.toLowerCase() === type)) {
            throw new Error(fault('RESOURCE_LABEL_INVALID', `${identifier.label} has no resource declaration`));
          }
          represented.add(type);
          if (!source.path) externalResources.add(type);
        }
      } catch (error) { errors.push(fault('IDENTIFIER_MISSING', `${spec.id}/${key}: ${error.message}`)); }
    }
    // Script, route, table, role and named-value-shaped labels cannot be added
    // as unverified prose instead of a [[reference]].
    const known = Object.values(spec.identifiers).map(id => id.label);
    const candidates = allText.match(/\b[\w-]+\.(?:ps1|mjs|bicep)\b|\bTurnstile\.[A-Z]\w+|\b(?:ApiManagementGatewayLlmLog|AppTraces)\b|\/api\/v1\/[\w/-]+|\b(?:quota|tpm|allow|models|bu|entitlement)-[a-z][a-z-]*\b/g) ?? [];
    for (const candidate of new Set(candidates)) {
      if (!known.some(label => label.includes(candidate))) errors.push(fault('IDENTIFIER_UNBOUND', `${spec.id}: ${candidate}`));
    }
    if (spec.kind === 'inventory') {
      for (const type of (spec.sections ?? []).flatMap(section => section.types)) represented.add(type.toLowerCase());
    }
    try { inputsFor(root, spec); }
    catch (error) { errors.push(fault('SOURCE_MISSING', `${spec.id}: ${error.message}`)); }
    if (spec.kind === 'flow') {
      const { width, height } = spec;
      if (!Number.isInteger(width) || width < 800 || width > 1800 ||
          !Number.isInteger(height) || height < 200 || height > 4000) errors.push(fault('LAYOUT_INVALID', spec.id));
      const nodes = new Set();
      for (const item of [...(spec.groups ?? []), ...(spec.nodes ?? [])]) {
        if (![item.x, item.y, item.w, item.h].every(Number.isFinite) ||
            item.x < 0 || item.y < 0 || item.x + item.w > width || item.y + item.h > height ||
            !TONES.includes(item.tone ?? 'slate')) errors.push(fault('LAYOUT_INVALID', `${spec.id}: ${item.title}`));
      }
      for (const node of spec.nodes ?? []) {
        if (!node.id || nodes.has(node.id)) errors.push(fault('LAYOUT_INVALID', `${spec.id}: duplicate node`));
        nodes.add(node.id);
      }
      for (const edge of spec.edges ?? []) {
        if (!nodes.has(edge.from) || !nodes.has(edge.to) || !['data', 'control', 'identity'].includes(edge.kind) ||
            !Array.isArray(edge.points) || edge.points.length < 2 ||
            !edge.points.every(p => p.length === 2 && p.every(Number.isFinite) && p[0] >= 0 && p[0] <= width && p[1] >= 0 && p[1] <= height)) {
          errors.push(fault('LAYOUT_INVALID', `${spec.id}: edge ${edge.from}/${edge.to}`));
        }
      }
    }
  }
  const declared = new Set();
  for (const file of walk(root, 'infra', '.bicep')) {
    try {
      for (const type of bicepResources(text(root, file))) {
        declared.add(type.toLowerCase());
        if (!represented.has(type.toLowerCase())) errors.push(fault('RESOURCE_UNCOVERED', `${file}: ${type}`));
      }
    } catch (error) { errors.push(error.message); }
  }
  for (const type of represented) {
    if (!declared.has(type) && !externalResources.has(type)) errors.push(fault('RESOURCE_UNKNOWN', type));
  }
  return [...new Set(errors)];
}
