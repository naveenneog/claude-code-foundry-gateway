import { once } from 'node:events';
import { existsSync } from 'node:fs';
import { open } from 'node:fs/promises';
import { StringDecoder } from 'node:string_decoder';

export async function waitForDrain(res) {
  if (res.destroyed || res.writableEnded) return;
  await once(res, 'drain').catch(() => {});
}

export async function writeNdjson(res, payload) {
  if (res.destroyed || res.writableEnded) return false;
  const ok = res.write(`${JSON.stringify(payload)}\n`);
  if (!ok) await waitForDrain(res);
  return !res.destroyed && !res.writableEnded;
}

export function createLineHandler(type, emitLine, lineCapBytes) {
  const decoder = new StringDecoder('utf8');
  let carry = '';
  let work = Promise.resolve();
  let discarding = false;
  const emitBounded = async (line, final = false) => {
    if (discarding) {
      if (final) discarding = false;
      return;
    }
    const bytes = Buffer.byteLength(line);
    if (bytes > lineCapBytes) {
      await emitLine(type, `${Buffer.from(line).subarray(0, lineCapBytes).toString('utf8')} [line truncated]`);
      discarding = !final;
    } else if (line) {
      await emitLine(type, line);
    }
  };
  return {
    chunk(chunk) {
      work = work.then(async () => {
        carry += decoder.write(chunk);
        const lines = carry.split(/\r?\n/);
        carry = lines.pop() || '';
        for (const line of lines) await emitBounded(line, true);
        if (Buffer.byteLength(carry) > lineCapBytes) {
          await emitBounded(carry, false);
          carry = '';
        }
      });
      return work;
    },
    async end() {
      await work;
      carry += decoder.end();
      if (carry) await emitBounded(carry, true);
      carry = '';
    },
  };
}

export async function readProgressFile(progressPath, state, processText, final = false) {
  if (!progressPath || !existsSync(progressPath)) return;
  const file = await open(progressPath, 'r');
  try {
    const stat = await file.stat();
    if (stat.size <= state.offset && !final) return;
    const length = stat.size - state.offset;
    if (length > 0) {
      const buffer = Buffer.alloc(length);
      const { bytesRead } = await file.read(buffer, 0, length, state.offset);
      state.offset += bytesRead;
      await processText(state.decoder.write(buffer.subarray(0, bytesRead)), final);
    } else if (final) {
      await processText('', true);
    }
  } finally {
    await file.close();
  }
}
