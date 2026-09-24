/**
 * Single flight is per Node process, not a distributed cache or a lock in APIM.
 * Timed-out transports keep their slot until they settle: abort is best-effort,
 * and releasing early would let an unavailable store accumulate unbounded work.
 */
export function createLookup(read, { deadlineMs = 3500, maxInFlight = 100 } = {}) {
  const pending = new Map();
  return async (oid) => {
    if (pending.has(oid)) return pending.get(oid);
    if (pending.size >= maxInFlight) throw new Error('entitlement lookup busy');
    const abort = new AbortController();
    let timer;
    const work = Promise.resolve().then(() => read(oid, abort.signal));
    const deadline = new Promise((resolve, reject) => {
      timer = setTimeout(() => {
        abort.abort();
        reject(new Error('entitlement lookup deadline exceeded'));
      }, deadlineMs);
    });
    const shared = Promise.race([work, deadline]);
    pending.set(oid, shared);
    const complete = () => { clearTimeout(timer); pending.delete(oid); };
    work.then(complete, complete);
    return shared;
  };
}
