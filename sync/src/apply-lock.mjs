import { APPLY_LOCK_ID, APPLY_LOCK_RECORD_TYPE } from './plan.mjs';

export const APPLY_LOCK_LEASE_SECONDS = 300;
const RENEW_AFTER_MS = (APPLY_LOCK_LEASE_SECONDS * 1000) / 3;

export async function acquireApplyLock(container, {
  runId,
  mode,
  waitSeconds = 900,
  now = () => new Date(),
  sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
} = {}) {
  validateLockWait(waitSeconds);
  const started = now().getTime();
  while (true) {
    const attemptedAt = now();
    try {
      const response = await container.items.create(lockDocument({ runId, mode, at: attemptedAt }));
      return new ApplyLock(container, response.resource, etagOf(response), now);
    } catch (error) {
      if (!isStatus(error, 409)) throw error;
    }

    const held = await readLock(container);
    if (!held.resource || isExpired(held.resource, now())) {
      try {
        const response = await lockItem(container).replace(
          lockDocument({ runId, mode, at: now() }),
          { accessCondition: { type: 'IfMatch', condition: held.etag } },
        );
        return new ApplyLock(container, response.resource, etagOf(response), now);
      } catch (error) {
        if (!isStatus(error, 412) && !isStatus(error, 404)) throw error;
      }
    } else if (now().getTime() - started >= waitSeconds * 1000) {
      throw lockError(timeoutMessage(held.resource));
    }

    const remaining = Math.max(0, waitSeconds * 1000 - (now().getTime() - started));
    if (remaining <= 0) throw lockError(timeoutMessage(held.resource));
    await sleep(Math.min(1000, remaining));
  }
}

export function validateLockWait(value) {
  if (!Number.isInteger(value) || value < 0 || value > 3600) {
    throw new Error('--lock-wait-seconds must be an integer from 0 to 3600. Remedy: rerun scripts/Sync-ClaudeAccess.ps1 -ResourceGroup <rg> -ApimName <apim> with a valid --lock-wait-seconds value.');
  }
}

class ApplyLock {
  constructor(container, doc, etag, now) {
    this.container = container;
    this.doc = doc;
    this.etag = etag ?? doc?._etag;
    this.now = now;
    this.lastRenewedAt = this.now().getTime();
    this.warnings = [];
  }

  async renewIfNeeded({ force = false, now = this.now } = {}) {
    if (!force && now().getTime() - this.lastRenewedAt < RENEW_AFTER_MS) return false;
    try {
      const response = await lockItem(this.container).replace(
        lockDocument({ runId: this.doc.holder, mode: this.doc.mode, at: now() }),
        { accessCondition: { type: 'IfMatch', condition: this.etag } },
      );
      this.doc = response.resource;
      this.etag = etagOf(response) ?? this.doc?._etag;
      this.lastRenewedAt = now().getTime();
      return true;
    } catch (error) {
      if (isStatus(error, 412) || isStatus(error, 404)) {
        throw lockError('lost the projection apply lock before the next write; no further writes were made. Remedy: rerun the same command after the current lock holder finishes, or after its stuck lock expires by itself.');
      }
      throw error;
    }
  }

  async release() {
    try {
      await lockItem(this.container).delete({ accessCondition: { type: 'IfMatch', condition: this.etag } });
      return true;
    } catch (error) {
      if (isStatus(error, 412) || isStatus(error, 404)) {
        this.warnings.push(`projection apply lock release did not remove the lock because it was already changed or gone (${statusOf(error)}).`);
        return false;
      }
      throw error;
    }
  }
}

function lockDocument({ runId, mode, at }) {
  const acquiredAt = at.toISOString();
  return {
    id: APPLY_LOCK_ID,
    oid: APPLY_LOCK_ID,
    type: APPLY_LOCK_RECORD_TYPE,
    holder: runId,
    mode,
    acquiredAt,
    leaseExpiresAt: new Date(at.getTime() + APPLY_LOCK_LEASE_SECONDS * 1000).toISOString(),
  };
}

async function readLock(container) {
  try {
    const response = await lockItem(container).read();
    return { resource: response.resource, etag: etagOf(response) ?? response.resource?._etag };
  } catch (error) {
    if (isStatus(error, 404)) return { resource: null, etag: undefined };
    throw error;
  }
}

function lockItem(container) {
  return container.item(APPLY_LOCK_ID, APPLY_LOCK_ID);
}

function isExpired(lock, at) {
  return Date.parse(lock?.leaseExpiresAt) <= at.getTime();
}

function timeoutMessage(lock) {
  return `projection apply lock is held by ${lock?.holder ?? '(unknown)'} in ${lock?.mode ?? '(unknown)'} mode until ${lock?.leaseExpiresAt ?? '(unknown leaseExpiresAt)'}; leaseExpiresAt=${lock?.leaseExpiresAt ?? '(unknown)'}. Remedy: rerun the same command after ${lock?.leaseExpiresAt ?? 'the lease expiry'}; a stuck lock expires by itself at ${lock?.leaseExpiresAt ?? 'the recorded lease expiry'}.`;
}

function lockError(message) {
  const error = new Error(message);
  error.stage = 'lock';
  return error;
}

function isStatus(error, code) {
  return statusOf(error) === code;
}

function statusOf(error) {
  return error?.code ?? error?.statusCode ?? error?.status;
}

function etagOf(response) {
  return response?.etag ?? response?.resource?._etag ?? response?.headers?.etag;
}
