import { StringDecoder } from 'node:string_decoder';

export async function collectChildOutput(child, runOptions, defaultReadName, helpers) {
  const { killProcessTree, redactText } = helpers;
  const stdoutDecoder = new StringDecoder('utf8');
  const stderrDecoder = new StringDecoder('utf8');
  const capBytes = Number(runOptions.outputCapBytes || 1024 * 1024);
  let totalBytes = 0;
  let stdout = '';
  let stderr = '';
  let exceeded = false;
  let killRequested = false;
  const append = (target, decoder, chunk) => {
    totalBytes += chunk.length;
    if (totalBytes > capBytes) {
      exceeded = true;
      if (!killRequested) {
        killRequested = true;
        void killProcessTree(child);
      }
      return target;
    }
    return target + decoder.write(chunk);
  };
  child.stdout.on('data', (chunk) => { stdout = append(stdout, stdoutDecoder, chunk); });
  child.stderr.on('data', (chunk) => { stderr = append(stderr, stderrDecoder, chunk); });
  const timeoutMs = Number(runOptions.timeoutMs || 0);
  let timer;
  let timedOut = false;
  const code = await new Promise((resolveCode, reject) => {
    if (timeoutMs > 0) {
      timer = setTimeout(() => {
        timedOut = true;
        void killProcessTree(child);
      }, timeoutMs);
      timer.unref?.();
    }
    child.on('error', reject);
    child.on('close', resolveCode);
  });
  if (timer) clearTimeout(timer);
  stdout += stdoutDecoder.end();
  stderr += stderrDecoder.end();
  if (timedOut) {
    // A read under the Azure lease gets the time left of its budget; the message names the budget, which is what the operator configured.
    const error = new Error(`${runOptions.readName || defaultReadName} timed out after ${runOptions.budgetMs || timeoutMs} ms`);
    error.status = 504;
    throw error;
  }
  if (exceeded) {
    const error = new Error(`${runOptions.readName || defaultReadName} output exceeded the ${capBytes} byte cap`);
    error.status = 502;
    throw error;
  }
  return {
    code,
    stdout: runOptions.redactStdout === false ? stdout : await redactText(stdout),
    stderr: await redactText(stderr),
  };
}
