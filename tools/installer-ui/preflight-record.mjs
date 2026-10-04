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

export function preflightFingerprint({ answers, scope, engine = 'pwsh' }) {
  return sha256Hex(canonicalize({ schemaVersion: 1, engine, answers: answers || {}, steps: scope }));
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
  return {
    replaceForAnswers({ fingerprint, answersDigest: digest, engine, scope, time }) {
      records = records.filter((record) => !(record.answersDigest === digest && record.engine === engine));
      if (fingerprint) records.push({ fingerprint, answersDigest: digest, engine, scope, time });
      records = records.slice(-limit);
    },
    clearForAnswers(digest, engine) {
      records = records.filter((record) => !(record.answersDigest === digest && record.engine === engine));
    },
    lookup(fingerprint) {
      return records.find((record) => record.fingerprint === fingerprint) || null;
    },
    all() {
      return [...records];
    },
  };
}
