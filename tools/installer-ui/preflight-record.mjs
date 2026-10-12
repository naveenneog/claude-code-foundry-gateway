import { createHash } from 'node:crypto';

export function canonicalize(value) {
  if (Array.isArray(value)) return `[${value.map((item) => canonicalize(item)).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonicalize(value[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

export function sha256Hex(text) {
  return createHash('sha256').update(text, 'utf8').digest('hex');
}

export function sortedUniqueSteps(steps) {
  return [...new Set((steps || []).map(String).filter(Boolean))].sort();
}

export function scopeFromBody(body, steps = []) {
  if (body.fullRun || (!steps.length && !Array.isArray(body.steps))) return 'full';
  return sortedUniqueSteps(steps);
}

export function answersDigest(answers) {
  return sha256Hex(canonicalize(answers || {}));
}

export function preflightFingerprint({ answers, scope, engine = 'pwsh', identity = null }) {
  return sha256Hex(canonicalize({ schemaVersion: 1, engine, identity, answers: answers || {}, steps: scope }));
}

export function scopeCovers(recordScope, runScope) {
  if (recordScope === 'full') return true;
  if (runScope === 'full') return false;
  const allowed = new Set(recordScope);
  return runScope.every((step) => allowed.has(step));
}

export function preflightRequired(reason) {
  const error = new Error(reason || 'The answers or steps changed since the last passing preflight, or no passing preflight exists.');
  error.status = 409;
  error.reason = 'preflight-required';
  return error;
}

export function createPreflightStore(limit = 20) {
  let records = [];
  // The latest attempt number for each answers digest and engine; past 200 keys the oldest key is dropped, so a
  // long-running attempt for it can no longer store a pass.
  const latest = new Map();
  let attempts = 0;
  const keyFor = (digest, engine) => `${engine}:${digest}`;
  const clear = (digest, engine) => {
    records = records.filter((record) => !(record.answersDigest === digest && record.engine === engine));
  };
  return {
    // An attempt clears the pass for its answers and becomes the only attempt that may store the next one.
    beginAttempt(digest, engine) {
      const key = keyFor(digest, engine);
      const attempt = ++attempts;
      latest.delete(key);
      latest.set(key, attempt);
      if (latest.size > 200) latest.delete(latest.keys().next().value);
      clear(digest, engine);
      return attempt;
    },
    isLatest(digest, engine, attempt) {
      return latest.get(keyFor(digest, engine)) === attempt;
    },
    replaceForAnswers({ fingerprint, answersDigest: digest, engine, scope, time, identity }) {
      clear(digest, engine);
      if (fingerprint) records.push({ fingerprint, answersDigest: digest, engine, scope, time, identity });
      records = records.slice(-limit);
    },
    lookup(fingerprint) {
      return records.find((record) => record.fingerprint === fingerprint) || null;
    },
    all() {
      return [...records];
    },
  };
}
