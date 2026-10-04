import { randomBytes } from 'node:crypto';
import { contentSecurityPolicy } from './http-helpers.mjs';
import { writeNdjson } from './run-transport.mjs';

// The tail holds a whole run in practice: console output is capped at 4 MiB per run, and progress events
// are a few hundred bytes each. Older events leave the tail only past these bounds.
export const defaultTailEvents = 50_000;
export const defaultTailBytes = 8 * 1024 * 1024;

export function createRunRecord(steps, limits = {}) {
  return {
    id: randomBytes(16).toString('hex'),
    steps,
    state: 'running',
    currentStepId: '',
    exitCode: null,
    failedStepId: '',
    resumeCommand: '',
    startTime: new Date().toISOString(),
    nextSeq: 1,
    tail: [],
    tailSizes: [],
    tailHead: 0,
    tailBytes: 0,
    tailEventLimit: limits.tailEvents || defaultTailEvents,
    tailByteLimit: limits.tailBytes || defaultTailBytes,
    subscribers: new Set(),
    child: null,
    tempDir: '',
    progressPath: '',
    stoppedMessage: '',
    tempDirRemoved: false,
  };
}

export function publicRun(run) {
  if (!run) return undefined;
  const { id, steps, state, currentStepId, exitCode, failedStepId, resumeCommand, startTime, nextSeq, stoppedMessage, tempDirRemoved } = run;
  return { id, steps, state, currentStepId, exitCode, failedStepId, resumeCommand, startTime, nextSeq, stoppedMessage, tempDirRemoved };
}

function firstTailSeq(run) {
  return run.tailHead < run.tail.length ? run.tail[run.tailHead].seq : run.nextSeq;
}

function tailEvent(run, seq) {
  const index = run.tailHead + (seq - firstTailSeq(run));
  return index >= run.tailHead && index < run.tail.length ? run.tail[index] : undefined;
}

// Publishing never waits for a client: each subscriber writes from the tail at its own pace, so a slow or
// vanished browser cannot hold back the installer's output or the end of the run.
export function publishEvent(run, event) {
  const item = { seq: run.nextSeq++, ...event };
  const size = Buffer.byteLength(JSON.stringify(item)) + 1;
  run.tail.push(item);
  run.tailSizes.push(size);
  run.tailBytes += size;
  while (run.tail.length - run.tailHead > 1 && (run.tail.length - run.tailHead > run.tailEventLimit || run.tailBytes > run.tailByteLimit)) {
    run.tailBytes -= run.tailSizes[run.tailHead];
    run.tailHead += 1;
  }
  if (run.tailHead > 1024 && run.tailHead * 2 > run.tail.length) {
    run.tail.splice(0, run.tailHead);
    run.tailSizes.splice(0, run.tailHead);
    run.tailHead = 0;
  }
  if (item.type === 'progress' && item.event === 'started') run.currentStepId = item.stepId || run.currentStepId;
  if (item.type === 'progress' && item.event === 'failed') {
    run.failedStepId = item.stepId || '';
    run.resumeCommand = item.resumeCommand || (run.failedStepId ? `Install-ClaudeGateway.ps1 -Steps ${run.failedStepId}` : '');
  }
  for (const subscriber of run.subscribers) void subscriber.flush();
  return item;
}

// Streams the run's events after `after` as NDJSON: from the tail, then live, and ends after the summary.
// A client whose position fell out of the tail gets one notice with the number of events it missed.
export function attachSubscriber(run, res, after) {
  if (!Number.isInteger(after) || after < 0 || after > run.nextSeq - 1) {
    const error = new Error('after must be a non-negative integer no greater than the last event of the run');
    error.status = 400;
    throw error;
  }
  res.writeHead(200, {
    'content-type': 'application/x-ndjson; charset=utf-8',
    'cache-control': 'no-store',
    'content-security-policy': contentSecurityPolicy(),
    'x-content-type-options': 'nosniff',
  });
  let closed = false;
  const subscriber = {
    cursor: after,
    writing: false,
    async flush() {
      if (this.writing) return;
      this.writing = true;
      try {
        for (;;) {
          if (closed) return;
          const firstSeq = firstTailSeq(run);
          if (this.cursor < firstSeq - 1) {
            const skipped = firstSeq - this.cursor - 1;
            this.cursor = firstSeq - 1;
            if (!await writeNdjson(res, { seq: this.cursor, type: 'notice', skippedEvents: skipped, message: `${skipped} earlier run events fell out of the bounded tail before this client read them.` })) return;
          }
          const next = tailEvent(run, this.cursor + 1);
          if (!next) return;
          if (!await writeNdjson(res, next)) return;
          this.cursor = next.seq;
          if (next.type === 'summary') {
            closed = true;
            res.end();
            return;
          }
        }
      } finally {
        this.writing = false;
        if (!closed && run.nextSeq - 1 > this.cursor) void this.flush();
      }
    },
  };
  if (run.state === 'running' || run.state === 'stopping') run.subscribers.add(subscriber);
  res.on('close', () => { closed = true; run.subscribers.delete(subscriber); });
  void subscriber.flush();
}
