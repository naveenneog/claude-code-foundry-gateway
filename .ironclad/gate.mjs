#!/usr/bin/env node
/**
 * Ironclad gate — the executable definition of done.
 *
 * Zero dependencies (node builtins only) so it runs in any repo, any CI, with no install.
 * Audits a repository against its charter (.ironclad/charter.json) and exits non-zero on failure.
 *
 *   node gate.mjs --stage packet
 *   node gate.mjs --dir ../SomeRepo --no-run     # audit a repo you didn't set up
 *   node gate.mjs --stage release --json
 *
 * See ../SKILL.md and ../references/anti-drift.md for what each check defends against.
 */

import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const VERSION = '1.0.0';
const STAGES = ['pre-commit', 'packet', 'release'];

// ─────────────────────────────────────────────────────────────────────────────
// CLI
// ─────────────────────────────────────────────────────────────────────────────

const HELP = `
Ironclad gate v${VERSION} — executable engineering-discipline audit.

Usage: node gate.mjs [options]

  --dir <path>      Repository to audit (default: cwd)
  --stage <stage>   pre-commit | packet | release   (default: packet)
                      pre-commit  fast, no command execution — for the git hook
                      packet      full: runs tests, lint, typecheck, build — the definition of done
                      release     packet + coverage floor + dependency audit + open unknowns
  --only <groups>   Comma-separated groups: charter,ledger,tests,quality,architecture,security,unknowns
  --skip <groups>   Comma-separated groups to skip
  --no-run          Never execute charter commands (audit-only; safe on an unknown repo)
  --strict          Treat warnings as failures (also set by charter.strictness = "strict")
  --json            Machine-readable report on stdout
  --verbose         Show output of failing commands
  --quiet           Only show problems and the summary
  --version         Print version
  --help            This

Exit codes: 0 = pass · 1 = one or more failures · 2 = usage or internal error
`.trimStart();

function parseArgs(argv) {
  const opts = {
    dir: process.cwd(), stage: 'packet', only: null, skip: null,
    run: true, strict: false, json: false, verbose: false, quiet: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const next = () => {
      const v = argv[++i];
      if (v === undefined) fatal(`Option ${a} needs a value`);
      return v;
    };
    switch (a) {
      case '--dir': opts.dir = path.resolve(next()); break;
      case '--stage': opts.stage = next(); break;
      case '--only': opts.only = next().split(',').map((s) => s.trim()).filter(Boolean); break;
      case '--skip': opts.skip = next().split(',').map((s) => s.trim()).filter(Boolean); break;
      case '--no-run': opts.run = false; break;
      case '--strict': opts.strict = true; break;
      case '--json': opts.json = true; break;
      case '--verbose': opts.verbose = true; break;
      case '--quiet': opts.quiet = true; break;
      case '--version': process.stdout.write(`${VERSION}\n`); process.exit(0); break;
      case '--help': case '-h': process.stdout.write(HELP); process.exit(0); break;
      default: fatal(`Unknown option: ${a}\n\n${HELP}`);
    }
  }
  if (!STAGES.includes(opts.stage)) fatal(`--stage must be one of: ${STAGES.join(', ')}`);
  if (!fs.existsSync(opts.dir)) fatal(`Directory not found: ${opts.dir}`);
  return opts;
}

function fatal(msg) {
  process.stderr.write(`ironclad: ${msg}\n`);
  process.exit(2);
}

// ─────────────────────────────────────────────────────────────────────────────
// Charter
// ─────────────────────────────────────────────────────────────────────────────

const DEFAULT_CHARTER = {
  version: 1,
  name: null,
  strictness: 'standard', // relaxed | standard | strict
  commands: { test: null, lint: null, typecheck: null, build: null, a11y: null, coverage: null },
  quality: {
    maxFileLines: 400,
    maxTestFileLines: 800,
    maxDebtMarkers: 20,
    coverageFloor: null,
    minTestRatio: 0.15, // test files / source files
    // [{ path: glob, maxLines: n, why: "..." }] — `why` is mandatory: an exception without a
    // recorded reason is exactly how a budget quietly stops being a budget (anti-drift M1).
    fileSizeExceptions: [],
  },
  ledger: {
    requireRoadmap: true,
    requireStatus: true,
    requireChangelog: true,
    requireAdr: true,
    maxUncommittedFiles: 15,
    maxUncommittedLines: 500,
    maxCommitsWithoutAdr: 40,
    architectureSignificantPaths: [],
  },
  architecture: { boundaries: [] },
  security: { secretAllowlist: [], auditDependencies: true },
  tests: { skipAllowlist: [] },
  // [{ check: "tests.only" | ["a","b"] | "*", path: glob, why: "..." }] — suppress scan findings
  // for paths that legitimately contain the pattern (a scanner's own fixtures, teaching examples).
  // `why` is mandatory; an entry without one is ignored AND reported by charter.exceptions.
  ignoreFindings: [],
  ignore: [],
  commandTimeoutMs: 900_000,
};

function isPlainObject(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

function deepMerge(base, override) {
  const out = Array.isArray(base) ? [...base] : { ...base };
  for (const [k, v] of Object.entries(override ?? {})) {
    out[k] = isPlainObject(v) && isPlainObject(base?.[k]) ? deepMerge(base[k], v) : v;
  }
  return out;
}

function loadCharter(dir) {
  const file = path.join(dir, '.ironclad', 'charter.json');
  if (!fs.existsSync(file)) return { charter: DEFAULT_CHARTER, found: false, error: null, file };
  try {
    const parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
    return { charter: deepMerge(DEFAULT_CHARTER, parsed), found: true, error: null, file };
  } catch (err) {
    return { charter: DEFAULT_CHARTER, found: true, error: err.message, file };
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// File system
// ─────────────────────────────────────────────────────────────────────────────

const IGNORED_DIRS = new Set([
  '.git', '.ironclad', 'node_modules', 'dist', 'build', 'out', '.next', '.nuxt', '.svelte-kit', '.output',
  'coverage', '.nyc_output', 'venv', '.venv', 'env', '__pycache__', '.pytest_cache', '.mypy_cache',
  '.ruff_cache', '.tox', 'bin', 'obj', 'target', 'vendor', '.cache', '.turbo', '.parcel-cache',
  '.gradle', '.idea', '.vs', '.vscode', 'Library', 'Temp', 'Logs', 'Builds', 'Pods',
  'DerivedData', 'site-packages', 'bower_components', '.terraform', 'artifacts', 'packages',
]);

const SOURCE_EXT = new Set([
  '.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs', '.mts', '.cts', '.vue', '.svelte',
  '.py', '.cs', '.go', '.java', '.kt', '.rb', '.rs', '.php', '.swift', '.scala', '.dart',
  '.c', '.cc', '.cpp', '.h', '.hpp', '.m', '.mm', '.sh', '.ps1',
]);

const SCANNABLE_EXT = new Set([
  ...SOURCE_EXT, '.json', '.yml', '.yaml', '.toml', '.env', '.ini', '.cfg', '.xml',
  '.md', '.txt', '.html', '.css', '.scss', '.sql', '.tf', '.gradle', '.properties',
]);

const MAX_SCAN_BYTES = 512 * 1024;
const MAX_FILES = 25_000;

function listFiles(dir) {
  const fromGit = listFilesFromGit(dir);
  const rels = fromGit ?? walk(dir);
  return rels
    .filter((rel) => !rel.split('/').some((seg) => IGNORED_DIRS.has(seg)))
    .filter((rel) => !/\.min\.(js|css)$|\.map$|-lock\.json$|\.lock$/.test(rel))
    .slice(0, MAX_FILES);
}

function listFilesFromGit(dir) {
  const res = spawnSync('git', ['ls-files', '-co', '--exclude-standard', '-z'], {
    cwd: dir, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024,
  });
  if (res.status !== 0 || typeof res.stdout !== 'string') return null;
  return res.stdout.split('\0').filter(Boolean);
}

function walk(dir) {
  const out = [];
  const stack = [''];
  while (stack.length && out.length < MAX_FILES) {
    const rel = stack.pop();
    let entries;
    try {
      entries = fs.readdirSync(path.join(dir, rel), { withFileTypes: true });
    } catch { continue; }
    for (const e of entries) {
      const childRel = rel ? `${rel}/${e.name}` : e.name;
      if (e.isDirectory()) {
        if (!IGNORED_DIRS.has(e.name)) stack.push(childRel);
      } else if (e.isFile()) {
        out.push(childRel);
      }
    }
  }
  return out;
}

function globToRegExp(glob) {
  let re = '';
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === '*') {
      if (glob[i + 1] === '*') {
        const slash = glob[i + 2] === '/';
        re += slash ? '(?:.*/)?' : '.*';
        i += slash ? 2 : 1;
      } else {
        re += '[^/]*';
      }
    } else if (c === '?') re += '[^/]';
    else if (c === '{') re += '(?:';
    else if (c === '}') re += ')';
    else if (c === ',') re += '|';
    else re += c.replace(/[.+^$()|[\]\\]/g, '\\$&');
  }
  return new RegExp(`^${re}$`);
}

function matchesAny(rel, globs) {
  return (globs ?? []).some((g) => globToRegExp(g).test(rel));
}

// ─────────────────────────────────────────────────────────────────────────────
// Classification
// ─────────────────────────────────────────────────────────────────────────────

const TEST_PATH = /(^|\/)(tests?|__tests__|spec|specs|e2e|testing)(\/|$)/i;
const TEST_FILE = /(\.|_|-)(test|spec)\.[a-z]+$|^test_[^/]+\.py$|_test\.(py|go|ts|js|rb)$|Tests?\.cs$|^conftest\.py$/i;

/**
 * A test file is source code that lives in a test location or carries a test name.
 * The source-extension requirement matters: `fixtures/sample.spec.json` and `spec/schema.yaml`
 * are data, not tests, and counting them inflates the test ratio into a lie.
 */
function isTestFile(rel) {
  if (!isSourceFile(rel)) return false;
  const base = rel.split('/').pop();
  return TEST_PATH.test(rel) || TEST_FILE.test(base) || TEST_FILE.test(rel);
}

function isSourceFile(rel) {
  return SOURCE_EXT.has(path.extname(rel).toLowerCase());
}

// ─────────────────────────────────────────────────────────────────────────────
// Context
// ─────────────────────────────────────────────────────────────────────────────

function buildContext(opts) {
  const { charter, found: charterFound, error: charterError, file: charterFile } = loadCharter(opts.dir);
  const cache = new Map();

  const ctx = {
    opts,
    dir: opts.dir,
    stage: opts.stage,
    charter,
    charterFound,
    charterError,
    charterFile,
    git: gitInfo(opts.dir),
    files: [],
    sourceFiles: [],
    testFiles: [],

    exists(rel) { return fs.existsSync(path.join(opts.dir, rel)); },

    read(rel) {
      if (cache.has(rel)) return cache.get(rel);
      let text = null;
      try {
        const abs = path.join(opts.dir, rel);
        if (fs.statSync(abs).size <= MAX_SCAN_BYTES) text = fs.readFileSync(abs, 'utf8');
      } catch { /* unreadable or binary */ }
      cache.set(rel, text);
      return text;
    },

    /** Find the first existing path from a list of candidates. */
    firstExisting(cands) { return cands.find((c) => ctx.exists(c)) ?? null; },

    /** Scan files for a set of regexes; returns [{ rel, line, text, label }]. */
    scan(files, patterns, { limit = 60 } = {}) {
      const hits = [];
      for (const rel of files) {
        if (hits.length >= limit) break;
        if (ctx.isIgnored(rel)) continue;
        const text = ctx.read(rel);
        if (!text) continue;
        const lines = text.split(/\r?\n/);
        for (let i = 0; i < lines.length && hits.length < limit; i++) {
          for (const { re, label } of patterns) {
            re.lastIndex = 0;
            if (re.test(lines[i])) {
              hits.push({ rel, line: i + 1, text: lines[i].trim().slice(0, 120), label });
              break;
            }
          }
        }
      }
      return hits;
    },

    /** Is this path exempted from the check currently running? */
    isIgnored(rel) {
      return charter.ignoreFindings.some((entry) => {
        if (!entry.why?.trim()) return false;
        const checks = entry.check === '*' || entry.check === undefined
          ? null
          : [].concat(entry.check);
        if (checks && !checks.includes(ctx.currentCheckId)) return false;
        return globToRegExp(entry.path ?? '**').test(rel);
      });
    },

    /** Files worth scanning as text (source, config, docs) plus any .env. */
    scannableFiles() {
      return ctx.files.filter((r) => SCANNABLE_EXT.has(path.extname(r).toLowerCase()) || /(^|\/)\.env/.test(r));
    },

    run(command, { timeoutMs = charter.commandTimeoutMs } = {}) {
      const started = Date.now();
      const res = spawnSync(command, {
        cwd: opts.dir, shell: true, encoding: 'utf8', timeout: timeoutMs,
        maxBuffer: 32 * 1024 * 1024, env: { ...process.env, CI: process.env.CI ?? '1', FORCE_COLOR: '0' },
      });
      return {
        command,
        code: res.status,
        signal: res.signal,
        timedOut: res.error?.code === 'ETIMEDOUT' || res.signal === 'SIGTERM',
        stdout: res.stdout ?? '',
        stderr: res.stderr ?? '',
        error: res.error ? String(res.error.message) : null,
        ms: Date.now() - started,
      };
    },
  };

  ctx.files = listFiles(opts.dir).filter((rel) => !matchesAny(rel, charter.ignore));
  ctx.sourceFiles = ctx.files.filter((r) => isSourceFile(r) && !isTestFile(r));
  ctx.testFiles = ctx.files.filter(isTestFile);
  return ctx;
}

function gitInfo(dir) {
  const git = (args) => spawnSync('git', args, { cwd: dir, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
  const rev = git(['rev-parse', '--is-inside-work-tree']);
  if (rev.status !== 0 || rev.stdout.trim() !== 'true') return { isRepo: false };
  const status = git(['status', '--porcelain']);
  const tracked = git(['ls-files']);
  const numstat = git(['diff', 'HEAD', '--numstat']);
  const changedLines = (numstat.stdout || '')
    .split('\n').filter(Boolean)
    .reduce((sum, l) => {
      const [add, del] = l.split('\t');
      return sum + (Number(add) || 0) + (Number(del) || 0);
    }, 0);
  const entries = (status.stdout || '').split('\n').filter(Boolean);
  return {
    isRepo: true,
    dirtyFiles: entries.map((l) => l.slice(3)),
    dirtyCount: entries.length,
    changedLines,
    trackedFiles: (tracked.stdout || '').split('\n').filter(Boolean),
    lastCommit: git(['log', '-1', '--format=%h %ad %s', '--date=short']).stdout.trim() || null,
    run: git,
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// Checks
// ─────────────────────────────────────────────────────────────────────────────

const ALL = ['pre-commit', 'packet', 'release'];
const FULL = ['packet', 'release'];

/**
 * Each check: { id, group, role, title, stages, severity, run(ctx) }
 * run() returns { ok, detail, items?, remedy?, skip?, info? }
 * severity: 'fail' | 'warn' | { <stage>: 'fail' | 'warn' }
 */
const CHECKS = [
  // ── charter ───────────────────────────────────────────────────────────────
  {
    id: 'charter.present', group: 'charter', role: 'Architect', stages: ALL,
    severity: { 'pre-commit': 'warn', packet: 'fail', release: 'fail' },
    title: 'Project charter exists and parses',
    run(ctx) {
      if (!ctx.charterFound) {
        return {
          ok: false,
          detail: 'No .ironclad/charter.json — this project has no machine-checkable contract',
          remedy: 'node <skill>/scripts/init.mjs --dir . --name <project>',
        };
      }
      if (ctx.charterError) {
        return { ok: false, detail: `charter.json is invalid JSON: ${ctx.charterError}`, remedy: 'Fix the JSON syntax' };
      }
      const c = ctx.charter;
      const declared = Object.entries(c.commands).filter(([, v]) => v).map(([k]) => k);
      return { ok: true, detail: `v${c.version} · strictness: ${c.strictness} · commands: ${declared.join(', ') || 'none declared'}` };
    },
  },
  {
    id: 'charter.commands', group: 'charter', role: 'Architect', stages: FULL, severity: 'warn',
    title: 'Declared commands are backed by real scripts',
    run(ctx) {
      if (!ctx.charterFound) return { skip: 'no charter' };
      const declared = Object.entries(ctx.charter.commands).filter(([, v]) => v);
      if (!declared.length) {
        return {
          ok: false,
          detail: 'No commands declared — the gate cannot prove anything about this code',
          remedy: 'Declare at least commands.test in .ironclad/charter.json',
        };
      }
      const pkgRaw = ctx.read('package.json');
      if (!pkgRaw) return { ok: true, detail: `${declared.length} command(s) declared` };
      let scripts = {};
      try { scripts = JSON.parse(pkgRaw).scripts ?? {}; } catch { /* ignore */ }
      const missing = [];
      for (const [key, cmd] of declared) {
        const m = /^npm\s+(?:run\s+)?([\w:-]+)/.exec(cmd);
        const scriptName = m ? (m[1] === 'run' ? null : m[1]) : null;
        if (scriptName && !['install', 'ci', 'audit', 'exec', 'x'].includes(scriptName) && !scripts[scriptName]) {
          missing.push(`${key}: "${cmd}" → package.json has no "${scriptName}" script`);
        }
      }
      return missing.length
        ? { ok: false, detail: 'Charter references scripts that do not exist', items: missing, remedy: 'Add the script, or fix the charter command' }
        : { ok: true, detail: `${declared.length} command(s) declared and resolvable` };
    },
  },

  {
    id: 'charter.exceptions', group: 'charter', role: 'Architect', stages: ALL, severity: 'fail',
    title: 'Every charter exception states why it exists',
    run(ctx) {
      // Anti-drift M1, applied to the charter itself: an exception you cannot justify in writing
      // is a rule you have quietly abandoned. Entries without a `why` are ignored *and* reported.
      const bad = [
        ...ctx.charter.quality.fileSizeExceptions.map((e, i) => ({ kind: `quality.fileSizeExceptions[${i}]`, ...e })),
        ...ctx.charter.ignoreFindings.map((e, i) => ({ kind: `ignoreFindings[${i}]`, ...e })),
      ].filter((e) => !e.why?.trim());
      return bad.length
        ? {
            ok: false,
            detail: `${bad.length} charter exception(s) with no stated reason`,
            items: bad.map((e) => `${e.kind}  path: ${e.path ?? '**'}`),
            remedy: 'State why the exception exists (and record an ADR if it is significant), or remove it. Unjustified exceptions are ignored by the gate.',
          }
        : { ok: true, detail: `${ctx.charter.quality.fileSizeExceptions.length + ctx.charter.ignoreFindings.length} documented exception(s)` };
    },
  },

  // ── ledger ────────────────────────────────────────────────────────────────
  {
    id: 'ledger.git', group: 'ledger', role: 'Ledger', stages: ALL, severity: 'fail',
    title: 'Work is under version control',
    run(ctx) {
      return ctx.git.isRepo
        ? { ok: true, detail: ctx.git.lastCommit ? `last commit: ${ctx.git.lastCommit}` : 'repo initialised, no commits yet' }
        : { ok: false, detail: 'Not a git repository — nothing here is recoverable or reviewable', remedy: 'git init && git add -A && git commit' };
    },
  },
  {
    id: 'ledger.readme', group: 'ledger', role: 'Ledger', stages: FULL, severity: 'warn',
    title: 'README explains what this is and how to run it',
    run(ctx) {
      const rel = ctx.firstExisting(['README.md', 'readme.md', 'README.rst', 'docs/README.md']);
      if (!rel) return { ok: false, detail: 'No README', remedy: 'Write one: what it is, how to run it, how to test it' };
      const lines = (ctx.read(rel) ?? '').split('\n').filter((l) => l.trim()).length;
      return lines < 10
        ? { ok: false, detail: `${rel} is a stub (${lines} non-empty lines)`, remedy: 'Cover: purpose, install, run, test' }
        : { ok: true, detail: `${rel} · ${lines} lines` };
    },
  },
  {
    id: 'ledger.roadmap', group: 'ledger', role: 'Ledger', stages: FULL,
    severity: { packet: 'warn', release: 'fail' },
    title: 'Roadmap exists with planned packets',
    run(ctx) {
      if (!ctx.charter.ledger.requireRoadmap) return { skip: 'not required by charter' };
      const rel = ctx.firstExisting(['docs/ROADMAP.md', 'ROADMAP.md', 'docs/roadmap.md']);
      if (!rel) return { ok: false, detail: 'No roadmap — work has no plan to drift from', remedy: 'Create docs/ROADMAP.md (see templates/docs/ROADMAP.md)' };
      const text = ctx.read(rel) ?? '';
      const open = (text.match(/^\s*[-*]\s*\[ \]/gm) ?? []).length;
      const done = (text.match(/^\s*[-*]\s*\[[xX]\]/gm) ?? []).length;
      return open + done === 0
        ? { ok: false, detail: `${rel} has no packets (checklist items)`, remedy: 'Add packets as "- [ ] P-n  <behaviour>" with acceptance criteria' }
        : { ok: true, detail: `${rel} · ${done} done, ${open} open` };
    },
  },
  {
    id: 'ledger.status', group: 'ledger', role: 'Ledger', stages: ALL,
    severity: { 'pre-commit': 'warn', packet: 'warn', release: 'fail' },
    title: 'Exactly one active packet is named',
    run(ctx) {
      if (!ctx.charter.ledger.requireStatus) return { skip: 'not required by charter' };
      const rel = ctx.firstExisting(['docs/STATUS.md', 'STATUS.md', 'IMPLEMENTATION-STATUS.md', 'docs/status.md']);
      if (!rel) return { ok: false, detail: 'No STATUS file — a new session cannot tell what is in flight', remedy: 'Create docs/STATUS.md naming the ONE active packet' };
      const text = ctx.read(rel) ?? '';
      const m = /^\s*\*{0,2}Active packet:?\*{0,2}\s*:?\s*(.+)$/im.exec(text);
      const value = m?.[1]?.replace(/[*_`]/g, '').trim();
      if (!value || /^(none|tbd|-{1,3}|n\/a)$/i.test(value)) {
        return { ok: false, detail: `${rel} does not name an active packet`, remedy: 'Set "**Active packet:** P-n — <behaviour>"' };
      }
      return { ok: true, detail: `${value.slice(0, 80)}` };
    },
  },
  {
    id: 'ledger.changelog', group: 'ledger', role: 'Ledger', stages: FULL, severity: 'warn',
    title: 'Changelog records user-visible change',
    run(ctx) {
      if (!ctx.charter.ledger.requireChangelog) return { skip: 'not required by charter' };
      const rel = ctx.firstExisting(['CHANGELOG.md', 'docs/CHANGELOG.md', 'changelog.md']);
      return rel ? { ok: true, detail: rel } : { ok: false, detail: 'No CHANGELOG', remedy: 'Create CHANGELOG.md (Keep a Changelog format)' };
    },
  },
  {
    id: 'ledger.adr', group: 'ledger', role: 'Architect', stages: FULL, severity: 'warn',
    title: 'Architecture decisions are recorded',
    run(ctx) {
      if (!ctx.charter.ledger.requireAdr) return { skip: 'not required by charter' };
      const adrs = ctx.files.filter((r) => /(^|\/)(docs\/)?adrs?\//i.test(r) && r.endsWith('.md') && !/template/i.test(r));
      if (!adrs.length) {
        return { ok: false, detail: 'No ADRs — the reasoning behind this design exists nowhere on disk', remedy: 'Write docs/adr/0001-<decision>.md (see templates)' };
      }
      const sig = ctx.charter.ledger.architectureSignificantPaths;
      if (ctx.git.isRepo && sig.length) {
        const last = ctx.git.run(['log', '-1', '--format=%H', '--', 'docs/adr']).stdout.trim();
        if (last) {
          const since = ctx.git.run(['rev-list', '--count', `${last}..HEAD`, '--', ...sig]).stdout.trim();
          const n = Number(since);
          if (Number.isFinite(n) && n > ctx.charter.ledger.maxCommitsWithoutAdr) {
            return {
              ok: false,
              detail: `${adrs.length} ADR(s), but ${n} commits have touched architecture-significant paths since the last one`,
              remedy: 'Record the decisions made since, or lower ledger.maxCommitsWithoutAdr deliberately',
            };
          }
        }
      }
      return { ok: true, detail: `${adrs.length} ADR(s)` };
    },
  },
  {
    id: 'ledger.wip', group: 'ledger', role: 'Ledger', stages: ALL,
    severity: { 'pre-commit': 'warn', packet: 'warn', release: 'fail' },
    title: 'Uncommitted work stays small and recoverable',
    run(ctx) {
      if (!ctx.git.isRepo) return { skip: 'not a git repo' };
      const { dirtyCount, changedLines } = ctx.git;
      const { maxUncommittedFiles, maxUncommittedLines } = ctx.charter.ledger;
      if (dirtyCount > maxUncommittedFiles || changedLines > maxUncommittedLines) {
        return {
          ok: false,
          detail: `${dirtyCount} changed file(s), ~${changedLines} changed line(s) uncommitted (budget: ${maxUncommittedFiles} files / ${maxUncommittedLines} lines)`,
          items: ctx.git.dirtyFiles.slice(0, 12),
          remedy: 'Commit at every green (Contract rule 5) — this is unreviewable and unrevertable as one unit',
        };
      }
      return { ok: true, detail: dirtyCount ? `${dirtyCount} file(s) in progress` : 'clean tree' };
    },
  },

  // ── tests ─────────────────────────────────────────────────────────────────
  {
    id: 'tests.exist', group: 'tests', role: 'QA', stages: ALL, severity: 'fail',
    title: 'Tests exist',
    run(ctx) {
      if (!ctx.sourceFiles.length) return { skip: 'no source files detected' };
      return ctx.testFiles.length
        ? { ok: true, detail: `${ctx.testFiles.length} test file(s)` }
        : { ok: false, detail: 'No test files found anywhere in this repo', remedy: 'Contract rule 2: a feature without a test is a rumour. Start with one failing test.' };
    },
  },
  {
    id: 'tests.ratio', group: 'tests', role: 'QA', stages: FULL, severity: 'warn',
    title: 'Test coverage of the codebase is plausible',
    run(ctx) {
      const src = ctx.sourceFiles.length;
      if (!src || !ctx.testFiles.length) return { skip: 'no source or no tests' };
      const ratio = ctx.testFiles.length / src;
      const floor = ctx.charter.quality.minTestRatio;
      return ratio < floor
        ? { ok: false, detail: `${ctx.testFiles.length} test files for ${src} source files (${(ratio * 100).toFixed(0)}%, floor ${(floor * 100).toFixed(0)}%)`, remedy: 'Most of this code has no test at any level' }
        : { ok: true, detail: `${ctx.testFiles.length}/${src} (${(ratio * 100).toFixed(0)}%)` };
    },
  },
  {
    id: 'tests.skipped', group: 'tests', role: 'QA', stages: ALL, severity: 'fail',
    title: 'No skipped or disabled tests',
    run(ctx) {
      const files = ctx.testFiles.filter((r) => !matchesAny(r, ctx.charter.tests.skipAllowlist));
      // Only definition-time disables. `test.skip(browserName === "webkit", "reason")` and
      // `if (short) t.Skip()` are *conditional* platform gating, which is legitimate engineering —
      // flagging them trains people to ignore this check, and then it protects nothing.
      const hits = ctx.scan(files, [
        { re: /\b(?:it|test|describe|context|suite|bench)\.skip\s*\(\s*['"`]/, label: 'disabled test' },
        { re: /\bx(?:it|describe|test|context)\s*\(\s*['"`]/, label: 'x-prefixed' },
        { re: /\b(?:it|test)\.todo\s*\(/, label: 'todo' },
        { re: /@pytest\.mark\.skip\b(?!if)|@unittest\.skip\b(?!If|Unless)/, label: 'python skip' },
        { re: /\[(?:Ignore|Skip)[\](]|\bSkip\s*=\s*"/, label: 'dotnet ignore' },
      ]);
      return hits.length
        ? {
            ok: false,
            detail: `${hits.length} skipped/disabled test(s) — the suite is lying about what it proves`,
            items: hits.map((h) => `${h.rel}:${h.line}  ${h.text}`),
            remedy: 'Re-enable it, or delete it with an ADR saying why the behaviour is no longer required (D2). Never skip to get green.',
          }
        : { ok: true, detail: 'none' };
    },
  },
  {
    id: 'tests.only', group: 'tests', role: 'QA', stages: ALL, severity: 'fail',
    title: 'No focused tests (.only) silently disabling the suite',
    run(ctx) {
      const hits = ctx.scan(ctx.testFiles, [
        { re: /\b(?:it|test|describe|context|suite)\.only\s*\(/, label: 'only' },
        { re: /\bf(?:it|describe|test)\s*\(/, label: 'f-prefixed' },
        { re: /\.only\s*\(\s*['"`]/, label: 'only' },
      ]);
      return hits.length
        ? {
            ok: false,
            detail: `${hits.length} focused test(s) — everything else in that file is not running`,
            items: hits.map((h) => `${h.rel}:${h.line}  ${h.text}`),
            remedy: 'Remove .only/fit/fdescribe before committing. This is the most dangerous leftover in a suite.',
          }
        : { ok: true, detail: 'none' };
    },
  },
  {
    id: 'tests.run', group: 'tests', role: 'QA', stages: FULL, severity: 'fail',
    title: 'The test suite passes',
    run(ctx) {
      const cmd = ctx.charter.commands.test;
      if (!cmd) return { skip: 'no commands.test declared' };
      if (!ctx.opts.run) return { skip: '--no-run' };
      const r = ctx.run(cmd);
      if (r.timedOut) return { ok: false, detail: `\`${cmd}\` timed out after ${Math.round(r.ms / 1000)}s`, remedy: 'A suite too slow to run is a suite that stops being run' };
      return r.code === 0
        ? { ok: true, detail: `\`${cmd}\` passed in ${(r.ms / 1000).toFixed(1)}s` }
        : { ok: false, detail: `\`${cmd}\` exited ${r.code}`, items: tail(r.stdout + r.stderr, ctx.opts.verbose ? 40 : 12), remedy: 'Fix the code. Never fix the test to match the code (D2).' };
    },
  },
  {
    id: 'tests.coverage', group: 'tests', role: 'QA', stages: ['release'], severity: 'fail',
    title: 'Coverage is at or above the floor',
    run(ctx) {
      const floor = ctx.charter.quality.coverageFloor;
      if (floor == null) return { skip: 'no coverageFloor set' };
      const pct = readCoverage(ctx);
      if (pct == null) return { ok: false, detail: 'No coverage report found (coverage/coverage-summary.json, coverage.xml, .coverage)', remedy: 'Run the coverage command before the release gate' };
      return pct >= floor
        ? { ok: true, detail: `${pct.toFixed(1)}% ≥ ${floor}%` }
        : { ok: false, detail: `${pct.toFixed(1)}% < floor ${floor}%`, remedy: 'Cover the untested branches — especially error paths' };
    },
  },

  // ── quality ───────────────────────────────────────────────────────────────
  {
    id: 'quality.lint', group: 'quality', role: 'Coder', stages: FULL, severity: 'fail',
    title: 'Linter is clean',
    run(ctx) { return runDeclared(ctx, 'lint'); },
  },
  {
    id: 'quality.typecheck', group: 'quality', role: 'Coder', stages: FULL, severity: 'fail',
    title: 'Types check',
    run(ctx) { return runDeclared(ctx, 'typecheck'); },
  },
  {
    id: 'quality.build', group: 'quality', role: 'Coder', stages: FULL, severity: 'fail',
    title: 'Build succeeds',
    run(ctx) { return runDeclared(ctx, 'build'); },
  },
  {
    id: 'quality.filesize', group: 'quality', role: 'Coder', stages: ALL, severity: 'warn',
    title: 'No file exceeds its size budget',
    run(ctx) {
      const { maxFileLines, maxTestFileLines, fileSizeExceptions } = ctx.charter.quality;
      const over = [];
      for (const rel of ctx.files) {
        if (!isSourceFile(rel)) continue;
        const exception = fileSizeExceptions.find((e) => e.why?.trim() && globToRegExp(e.path).test(rel));
        const limit = exception?.maxLines ?? (isTestFile(rel) ? maxTestFileLines : maxFileLines);
        const text = ctx.read(rel);
        if (!text) continue;
        const n = text.split('\n').length;
        if (n > limit) over.push({ rel, n, limit });
      }
      over.sort((a, b) => b.n - a.n);
      return over.length
        ? {
            ok: false,
            detail: `${over.length} file(s) over budget — complexity only ratchets upward (D10)`,
            items: over.slice(0, 10).map((o) => `${o.rel}  ${o.n} lines (budget ${o.limit})`),
            remedy: 'Split by responsibility, not by line count',
          }
        : { ok: true, detail: `all within budget (${maxFileLines} lines${fileSizeExceptions.length ? `, ${fileSizeExceptions.length} recorded exception(s)` : ''})` };
    },
  },
  {
    id: 'quality.debt', group: 'quality', role: 'Coder', stages: ALL,
    severity: { 'pre-commit': 'warn', packet: 'warn', release: 'fail' },
    title: 'TODO/FIXME debt is within budget',
    run(ctx) {
      const budget = ctx.charter.quality.maxDebtMarkers;
      const hits = ctx.scan(ctx.files.filter(isSourceFile), [
        { re: /\b(?:TODO|FIXME|HACK|XXX)\b[:\s(]/, label: 'debt' },
      ], { limit: 500 });
      return hits.length > budget
        ? {
            ok: false,
            detail: `${hits.length} debt marker(s), budget ${budget}`,
            items: hits.slice(0, 8).map((h) => `${h.rel}:${h.line}  ${h.text}`),
            remedy: 'Convert each into a roadmap packet or fix it. A budget is a number that does not go up.',
          }
        : { ok: true, detail: `${hits.length}/${budget}` };
    },
  },
  {
    id: 'quality.debug', group: 'quality', role: 'Coder', stages: ALL, severity: 'fail',
    title: 'No debugger statements or breakpoints left behind',
    run(ctx) {
      const hits = ctx.scan(ctx.files.filter(isSourceFile), [
        { re: /(?:^|[;{}\s])debugger\s*(?:;|$)/, label: 'debugger' },
        { re: /\b(?:pdb|ipdb)\.set_trace\s*\(|(?:^|[;\s])breakpoint\s*\(\s*\)/, label: 'pdb' },
        { re: /\bbinding\.pry\b|\bdebug\.set_trace\b/, label: 'pry' },
      ]);
      return hits.length
        ? { ok: false, detail: `${hits.length} debug breakpoint(s) left in source`, items: hits.map((h) => `${h.rel}:${h.line}  ${h.text}`), remedy: 'Remove before committing' }
        : { ok: true, detail: 'none' };
    },
  },

  // ── architecture ──────────────────────────────────────────────────────────
  {
    id: 'architecture.boundaries', group: 'architecture', role: 'Architect', stages: ALL, severity: 'fail',
    title: 'Declared module boundaries are respected',
    run(ctx) {
      const rules = ctx.charter.architecture.boundaries;
      if (!rules.length) {
        return { ok: true, detail: 'no boundaries declared', note: 'An undeclared boundary is a preference, and preferences erode (D9)' };
      }
      const violations = [];
      for (const rule of rules) {
        const re = globToRegExp(rule.from);
        const forbid = (rule.forbid ?? []).map((f) => new RegExp(f.includes('/') || /[\\^$*+?()[\]{}|]/.test(f) ? f : `^${f}(?:/|$)`));
        for (const rel of ctx.files.filter((r) => re.test(r) && isSourceFile(r))) {
          const text = ctx.read(rel);
          if (!text) continue;
          const lines = text.split(/\r?\n/);
          for (let i = 0; i < lines.length; i++) {
            for (const spec of importSpecifiers(lines[i], rel)) {
              if (forbid.some((f) => f.test(spec))) {
                violations.push(`${rel}:${i + 1}  imports "${spec}"  — ${rule.why ?? rule.from + ' must not depend on it'}`);
              }
            }
          }
        }
      }
      return violations.length
        ? { ok: false, detail: `${violations.length} boundary violation(s)`, items: violations.slice(0, 15), remedy: 'Invert the dependency, or record an ADR changing the boundary deliberately (never silently)' }
        : { ok: true, detail: `${rules.length} boundary rule(s) upheld` };
    },
  },

  // ── security ──────────────────────────────────────────────────────────────
  {
    id: 'security.secrets', group: 'security', role: 'Security', stages: ALL, severity: 'fail',
    title: 'No secrets in the source tree',
    run(ctx) {
      // High-confidence only: these shapes are issued by a provider and are never a coincidence.
      // A real key in a test fixture is still a real leak, so this scans every file.
      const hits = scanForSecrets(ctx, ctx.scannableFiles(), [
        { re: /AKIA[0-9A-Z]{16}/, label: 'AWS access key' },
        { re: /\bgh[pousr]_[A-Za-z0-9]{30,}/, label: 'GitHub token' },
        { re: /\bxox[abprs]-[A-Za-z0-9-]{10,}/, label: 'Slack token' },
        { re: /\bsk_live_[A-Za-z0-9]{16,}/, label: 'Stripe live key' },
        { re: /\bAIza[0-9A-Za-z_-]{35}\b/, label: 'Google API key' },
        { re: /-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----/, label: 'private key' },
        { re: /AccountKey=[A-Za-z0-9+/=]{40,}/, label: 'Azure storage key' },
        { re: /\bglpat-[A-Za-z0-9_-]{20,}/, label: 'GitLab token' },
        { re: /\bnpm_[A-Za-z0-9]{36}\b/, label: 'npm token' },
      ]);
      return hits.length
        ? {
            ok: false,
            detail: `${hits.length} secret(s) in source`,
            items: hits.map((h) => `${h.rel}:${h.line}  [${h.label}] ${redact(h.text)}`),
            remedy: 'Move to env/vault and ROTATE the exposed value — removing it from HEAD does not un-leak it',
          }
        : { ok: true, detail: 'none found' };
    },
  },
  {
    id: 'security.credentials', group: 'security', role: 'Security', stages: ALL, severity: 'warn',
    title: 'No hardcoded credentials outside test fixtures',
    run(ctx) {
      // Deliberately a WARN and deliberately skips test files: fixtures legitimately contain fake
      // tokens, and a check with a high false-positive rate is a check everyone learns to ignore.
      const files = ctx.scannableFiles().filter((r) => !isTestFile(r) && !/fixture|mock|sample|example|seed|synthetic/i.test(r));
      const hits = scanForSecrets(ctx, files, [
        { re: /(?:api[_-]?key|secret|password|passwd|pwd|token|client[_-]?secret|connection[_-]?string)\s*[:=]\s*["'][^"'\s${}<>]{12,}["']/i, label: 'assigned credential' },
      ]);
      return hits.length
        ? {
            ok: false,
            detail: `${hits.length} hardcoded credential-shaped literal(s)`,
            items: hits.map((h) => `${h.rel}:${h.line}  ${redact(h.text)}`),
            remedy: 'Read it from the environment or a vault. If it is genuinely not a secret, add a marker to security.secretAllowlist.',
          }
        : { ok: true, detail: 'none found' };
    },
  },
  {
    id: 'security.env', group: 'security', role: 'Security', stages: ALL, severity: 'fail',
    title: '.env files are ignored, never tracked',
    run(ctx) {
      if (!ctx.git.isRepo) return { skip: 'not a git repo' };
      const tracked = ctx.git.trackedFiles.filter((f) => /(^|\/)\.env(\.|$)/.test(f) && !/\.(example|sample|template|dist)$/.test(f));
      if (tracked.length) {
        return { ok: false, detail: 'Environment files are committed to git', items: tracked, remedy: 'git rm --cached them, add to .gitignore, and ROTATE every value they contained' };
      }
      const hasEnv = ctx.files.some((f) => /(^|\/)\.env(\.|$)/.test(f) && !/\.(example|sample|template)$/.test(f));
      const ignore = ctx.read('.gitignore') ?? '';
      if (hasEnv && !/^\s*\.?\*?\.?env/m.test(ignore)) {
        return { ok: false, detail: '.env exists but is not in .gitignore — one `git add -A` from a leak', remedy: 'Add `.env` and `.env.*` to .gitignore (keep `!.env.example`)' };
      }
      return { ok: true, detail: hasEnv ? '.env present and ignored' : 'no .env files' };
    },
  },
  {
    id: 'security.deps', group: 'security', role: 'Security', stages: ['release'], severity: 'fail',
    title: 'No known-vulnerable dependencies',
    run(ctx) {
      if (!ctx.charter.security.auditDependencies) return { skip: 'disabled in charter' };
      if (!ctx.opts.run) return { skip: '--no-run' };
      if (!ctx.exists('package.json')) return { skip: 'no package.json (audit other ecosystems manually)' };
      const r = ctx.run('npm audit --omit=dev --json', { timeoutMs: 120_000 });
      let data;
      try { data = JSON.parse(r.stdout); } catch { return { skip: 'npm audit unavailable (offline?)' }; }
      const v = data?.metadata?.vulnerabilities ?? {};
      const bad = (v.critical ?? 0) + (v.high ?? 0);
      const detail = `critical ${v.critical ?? 0} · high ${v.high ?? 0} · moderate ${v.moderate ?? 0} · low ${v.low ?? 0}`;
      return bad > 0
        ? { ok: false, detail, remedy: 'npm audit fix, or upgrade/replace the dependency. High and critical do not ship.' }
        : { ok: true, detail };
    },
  },

  // ── unknowns ──────────────────────────────────────────────────────────────
  {
    id: 'unknowns.open', group: 'unknowns', role: 'Architect', stages: FULL,
    severity: { packet: 'warn', release: 'fail' },
    title: 'No unresolved unknowns behind shipped work',
    run(ctx) {
      const rel = ctx.firstExisting(['docs/UNKNOWNS.md', 'UNKNOWNS.md']);
      if (!rel) {
        return { ok: false, detail: 'No unknowns register — silent guesses are the most expensive failure mode (D4)', remedy: 'Create docs/UNKNOWNS.md; list what you do not know BEFORE implementing' };
      }
      const lines = (ctx.read(rel) ?? '').split('\n');
      const open = lines.filter((l) => /^\s*\|/.test(l) && /\bOPEN\b/.test(l) && !/^\s*\|\s*-+/.test(l));
      return open.length
        ? { ok: false, detail: `${open.length} OPEN unknown(s)`, items: open.map((l) => l.trim().slice(0, 140)), remedy: 'Research it (cite the source) or mark it ASSUMED with its blast radius and a detector' }
        : { ok: true, detail: `${rel} · none open` };
    },
  },
];

// ─────────────────────────────────────────────────────────────────────────────
// Check helpers
// ─────────────────────────────────────────────────────────────────────────────

function runDeclared(ctx, key) {
  const cmd = ctx.charter.commands[key];
  if (!cmd) return { skip: `no commands.${key} declared` };
  if (!ctx.opts.run) return { skip: '--no-run' };
  const r = ctx.run(cmd);
  if (r.timedOut) return { ok: false, detail: `\`${cmd}\` timed out`, remedy: 'Investigate the hang' };
  return r.code === 0
    ? { ok: true, detail: `\`${cmd}\` passed in ${(r.ms / 1000).toFixed(1)}s` }
    : { ok: false, detail: `\`${cmd}\` exited ${r.code}`, items: tail(r.stdout + r.stderr, ctx.opts.verbose ? 40 : 12) };
}

const IMPORT_PATTERNS = {
  // Language-specific so a JS line like `import pg from "pg"` isn't also parsed by the Python
  // rule (which would yield the local alias `pg` and report the same violation twice).
  js: [
    /(?:^|\s)import\s+[^'"]*from\s*['"]([^'"]+)['"]/,
    /(?:^|\s)import\s*['"]([^'"]+)['"]/,
    /\brequire\s*\(\s*['"]([^'"]+)['"]\s*\)/,
    /\bimport\s*\(\s*['"]([^'"]+)['"]\s*\)/,
    /(?:^|\s)export\s+[^'"]*from\s*['"]([^'"]+)['"]/,
  ],
  py: [
    /^\s*from\s+([\w.]+)\s+import\s/,
    /^\s*import\s+([\w.]+)/,
  ],
  cs: [/^\s*using\s+(?:static\s+)?([\w.]+)\s*;/],
  go: [/^\s*(?:[\w.]+\s+)?"([^"]+)"\s*$/, /^\s*import\s+(?:[\w.]+\s+)?"([^"]+)"/],
};

const LANG_BY_EXT = {
  '.js': 'js', '.jsx': 'js', '.mjs': 'js', '.cjs': 'js', '.ts': 'js', '.tsx': 'js',
  '.mts': 'js', '.cts': 'js', '.vue': 'js', '.svelte': 'js',
  '.py': 'py', '.cs': 'cs', '.go': 'go',
};

function importSpecifiers(line, rel) {
  const lang = LANG_BY_EXT[path.extname(rel).toLowerCase()] ?? 'js';
  const out = new Set();
  for (const re of IMPORT_PATTERNS[lang]) {
    const m = re.exec(line);
    if (m?.[1]) out.add(m[1]);
  }
  return out;
}

function scanForSecrets(ctx, files, patterns) {
  const allow = ctx.charter.security.secretAllowlist;
  return ctx.scan(files, patterns)
    .filter((h) => !isPlaceholder(h.text))
    .filter((h) => !allow.some((a) => h.text.includes(a) || h.rel.includes(a)));
}

const PLACEHOLDER = /\b(?:process\.env|os\.environ|getenv|System\.getenv|ConfigurationManager|Deno\.env|import\.meta\.env|your[_-]|example|changeme|placeholder|dummy|redacted|xxxx|test|fake|sample|synthetic|demo|local(?:host)?|not[_-]?a[_-]?secret|<[^>]+>|\$\{|%[A-Z_]+%|\*{4,})\b/i;

function isPlaceholder(text) {
  if (PLACEHOLDER.test(text)) return true;
  const value = /["']([^"']{8,})["']/.exec(text)?.[1];
  if (!value) return false;
  // "aaaaaaaaaa" / "xxxxxxxx" / "0000000000" — filler, not a credential.
  return new Set(value).size <= 3;
}

function redact(text) {
  return text.replace(/(["'])([^"']{8,})\1/g, (_, q, v) => `${q}${v.slice(0, 4)}…${v.slice(-2)}${q}`);
}

function tail(text, n) {
  return (text || '').split(/\r?\n/).filter((l) => l.trim()).slice(-n);
}

function readCoverage(ctx) {
  const summary = ctx.read('coverage/coverage-summary.json');
  if (summary) {
    try {
      const pct = JSON.parse(summary)?.total?.lines?.pct;
      if (typeof pct === 'number') return pct;
    } catch { /* fall through */ }
  }
  const cobertura = ctx.firstExisting(['coverage/cobertura-coverage.xml', 'coverage.xml', 'coverage/coverage.xml']);
  if (cobertura) {
    const m = /line-rate="([0-9.]+)"/.exec(ctx.read(cobertura) ?? '');
    if (m) return Number(m[1]) * 100;
  }
  const lcov = ctx.firstExisting(['coverage/lcov.info']);
  if (lcov) {
    const text = ctx.read(lcov) ?? '';
    const found = (text.match(/^LF:(\d+)/gm) ?? []).reduce((s, l) => s + Number(l.slice(3)), 0);
    const hit = (text.match(/^LH:(\d+)/gm) ?? []).reduce((s, l) => s + Number(l.slice(3)), 0);
    if (found > 0) return (hit / found) * 100;
  }
  return null;
}

// ─────────────────────────────────────────────────────────────────────────────
// Runner
// ─────────────────────────────────────────────────────────────────────────────

function severityFor(check, stage) {
  return typeof check.severity === 'string' ? check.severity : (check.severity?.[stage] ?? 'warn');
}

function runChecks(ctx) {
  const { stage, only, skip } = ctx.opts;
  const results = [];
  for (const check of CHECKS) {
    if (!check.stages.includes(stage)) continue;
    if (only && !only.includes(check.group)) continue;
    if (skip && skip.includes(check.group)) continue;

    let outcome;
    try {
      ctx.currentCheckId = check.id;
      outcome = check.run(ctx) ?? { ok: true };
    } catch (err) {
      outcome = { ok: false, detail: `check crashed: ${err.message}` };
    }

    const status = outcome.skip ? 'skip' : outcome.ok ? 'pass' : severityFor(check, stage);
    results.push({
      id: check.id, group: check.group, role: check.role, title: check.title, status,
      detail: outcome.skip ? String(outcome.skip) : (outcome.detail ?? ''),
      items: outcome.items ?? [], remedy: outcome.remedy ?? null, note: outcome.note ?? null,
    });
  }
  return results;
}

// ─────────────────────────────────────────────────────────────────────────────
// Reporting
// ─────────────────────────────────────────────────────────────────────────────

const useColor = process.stdout.isTTY && !process.env.NO_COLOR;
const C = {
  reset: useColor ? '\x1b[0m' : '', bold: useColor ? '\x1b[1m' : '', dim: useColor ? '\x1b[2m' : '',
  red: useColor ? '\x1b[31m' : '', green: useColor ? '\x1b[32m' : '',
  yellow: useColor ? '\x1b[33m' : '', cyan: useColor ? '\x1b[36m' : '', grey: useColor ? '\x1b[90m' : '',
};

const BADGE = {
  pass: `${C.green}PASS${C.reset}`, warn: `${C.yellow}WARN${C.reset}`,
  fail: `${C.red}FAIL${C.reset}`, skip: `${C.grey}skip${C.reset}`,
};

const GROUP_TITLES = {
  charter: 'CHARTER — the contract',
  ledger: 'LEDGER — plan, status, decisions, version control',
  tests: 'TESTS — QA seat',
  quality: 'QUALITY — Coder seat',
  architecture: 'ARCHITECTURE — Architect seat',
  security: 'SECURITY — Security seat',
  unknowns: 'UNKNOWNS — acknowledged gaps',
};

function report(ctx, results, failed) {
  const out = [];
  const w = (s = '') => out.push(s);
  const name = ctx.charter.name ?? path.basename(ctx.dir);

  w('');
  w(`${C.bold}IRONCLAD GATE${C.reset} ${C.dim}v${VERSION}${C.reset}  ·  stage ${C.cyan}${ctx.stage}${C.reset}  ·  ${C.bold}${name}${C.reset}`);
  w(`${C.grey}${ctx.dir}${ctx.opts.run ? '' : '  (--no-run: commands not executed)'}${C.reset}`);

  let lastGroup = null;
  for (const r of results) {
    if (ctx.opts.quiet && (r.status === 'pass' || r.status === 'skip')) continue;
    if (r.group !== lastGroup) {
      w('');
      w(`${C.bold}${GROUP_TITLES[r.group] ?? r.group.toUpperCase()}${C.reset}`);
      lastGroup = r.group;
    }
    w(`  ${BADGE[r.status]}  ${pad(r.id, 26)} ${r.status === 'skip' ? C.grey : ''}${r.detail}${C.reset}`);
    if (r.status === 'fail' || r.status === 'warn') {
      for (const item of r.items.slice(0, 12)) w(`        ${C.grey}·${C.reset} ${item}`);
      if (r.items.length > 12) w(`        ${C.grey}… ${r.items.length - 12} more${C.reset}`);
      if (r.remedy) w(`        ${C.cyan}→${C.reset} ${r.remedy}`);
    } else if (r.note) {
      w(`        ${C.grey}${r.note}${C.reset}`);
    }
  }

  const tally = { pass: 0, warn: 0, fail: 0, skip: 0 };
  for (const r of results) tally[r.status]++;

  w('');
  w(`${C.grey}${'─'.repeat(72)}${C.reset}`);
  w(`  ${C.green}${tally.pass} passed${C.reset} · ${C.yellow}${tally.warn} warned${C.reset} · ${C.red}${tally.fail} failed${C.reset} · ${C.grey}${tally.skip} skipped${C.reset}`);
  if (failed) {
    const blockers = results.filter((r) => r.status === 'fail').map((r) => r.id);
    w(`  ${C.red}${C.bold}GATE: FAIL${C.reset} — not done. Blocking: ${blockers.join(', ')}`);
    if (ctx.opts.strict && !results.some((r) => r.status === 'fail')) {
      w(`  ${C.grey}(--strict: warnings are treated as failures)${C.reset}`);
    }
  } else {
    w(`  ${C.green}${C.bold}GATE: PASS${C.reset}${tally.warn ? ` ${C.yellow}— ${tally.warn} warning(s) to file as roadmap entries${C.reset}` : ''}`);
  }
  w('');
  process.stdout.write(out.join('\n') + '\n');
}

function pad(s, n) {
  return s.length >= n ? s : s + ' '.repeat(n - s.length);
}

// ─────────────────────────────────────────────────────────────────────────────
// Main
// ─────────────────────────────────────────────────────────────────────────────

function main() {
  const opts = parseArgs(process.argv.slice(2));
  const ctx = buildContext(opts);
  if (ctx.charter.strictness === 'strict') opts.strict = true;

  const results = runChecks(ctx);
  const failed = results.some((r) => r.status === 'fail' || (opts.strict && r.status === 'warn'));

  if (opts.json) {
    process.stdout.write(JSON.stringify({
      version: VERSION,
      stage: opts.stage,
      dir: ctx.dir,
      project: ctx.charter.name ?? path.basename(ctx.dir),
      charterFound: ctx.charterFound,
      passed: !failed,
      summary: results.reduce((acc, r) => ({ ...acc, [r.status]: (acc[r.status] ?? 0) + 1 }), {}),
      results,
    }, null, 2) + '\n');
  } else {
    report(ctx, results, failed);
  }
  process.exit(failed ? 1 : 0);
}

main();
