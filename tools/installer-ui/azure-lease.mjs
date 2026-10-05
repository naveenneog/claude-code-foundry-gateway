export function createAzureLease() {
  let holder = null;
  const queue = [];

  const busy = (operation) => {
    const error = new Error('Azure CLI work is already active.');
    error.status = 409;
    error.reason = 'azure-busy';
    error.operation = operation;
    return error;
  };

  const timeout = (operation, timeoutMs) => {
    const error = new Error(`${operation} timed out after ${timeoutMs} ms`);
    error.status = 504;
    return error;
  };

  const release = (lease) => {
    if (holder !== lease) return;
    holder = null;
    while (queue.length && !holder) {
      const next = queue.shift();
      if (next.done) continue;
      next.done = true;
      clearTimeout(next.timer);
      holder = next.lease;
      next.resolve(next.lease);
    }
  };

  return {
    currentOperation() {
      return holder?.operation || '';
    },
    async acquire(operation, kind, timeoutMs = 0) {
      const startedAt = Date.now();
      const lease = {
        operation,
        kind,
        timeoutMs,
        remainingTimeout() {
          if (!timeoutMs) return 0;
          return Math.max(1, timeoutMs - (Date.now() - startedAt));
        },
        release() {
          release(lease);
        },
      };
      if (!holder) {
        holder = lease;
        return lease;
      }
      if (holder.kind === 'run') throw busy('run');
      if (kind === 'run') throw busy(holder.operation);
      return new Promise((resolve, reject) => {
        const entry = { lease, resolve, done: false };
        entry.timer = setTimeout(() => {
          if (entry.done) return;
          entry.done = true;
          const index = queue.indexOf(entry);
          if (index >= 0) queue.splice(index, 1);
          reject(timeout(operation, timeoutMs));
        }, timeoutMs);
        entry.timer.unref?.();
        queue.push(entry);
      });
    },
  };
}
