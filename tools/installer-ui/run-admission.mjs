export function createRunAdmissions(limit = 20) {
  let records = [];

  function remember(record) {
    records = records.filter((item) => item.requestId !== record.requestId);
    records.push({ ...record, time: new Date().toISOString() });
    records = records.slice(-limit);
  }

  return {
    admit(requestId) {
      if (!requestId) return;
      remember({ requestId, state: 'admitting' });
    },
    started(requestId, runId) {
      if (!requestId) return;
      remember({ requestId, state: 'started', runId });
    },
    refused(requestId, error, reason) {
      if (!requestId) return;
      remember({ requestId, state: 'refused', error: error || 'run refused', reason: reason || undefined });
    },
    lookup(requestId) {
      const record = records.find((item) => item.requestId === requestId);
      if (!record) return null;
      const { requestId: _requestId, ...publicRecord } = record;
      return publicRecord;
    },
  };
}
