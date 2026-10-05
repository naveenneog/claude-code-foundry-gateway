import { StringDecoder } from 'node:string_decoder';
import { once } from 'node:events';
import { validateProgressEvent } from './installer-contract.mjs';
import { createLineHandler, readProgressFile } from './run-transport.mjs';

const consoleOutputCapBytes = 4 * 1024 * 1024;
const consoleLineCapBytes = 64 * 1024;

export async function runInstallerStreaming(kind, args, options, onEvent, progressPath, helpers, runOptions = {}) {
  const { spawnInstallerArgs, spawnChild, redactText } = helpers;
  const command = spawnInstallerArgs(kind, args, options);
  const child = spawnChild(command.file, command.args, options);
  runOptions.onChild?.(child);
  let progressCarry = '';
  let progressReading = Promise.resolve();
  let emitQueue = Promise.resolve();
  let consoleBytes = 0;
  let capNoticed = false;
  const enqueue = (event) => {
    emitQueue = emitQueue.then(() => onEvent(event)).catch((error) => onEvent({ type: 'error', message: error.message }).catch(() => {}));
    return emitQueue;
  };
  const emitConsoleLine = async (type, line) => {
    if (!line) return;
    const redacted = await redactText(line);
    const bytes = Buffer.byteLength(redacted);
    if (consoleBytes + bytes > consoleOutputCapBytes) {
      if (!capNoticed) {
        capNoticed = true;
        await enqueue({ type: 'notice', message: `The ${consoleOutputCapBytes} byte output cap was reached; the installer continues and progress plus summary events are still shown.` });
      }
      return;
    }
    consoleBytes += bytes;
    await enqueue({ type, line: redacted });
  };
  const stdout = createLineHandler('stdout', emitConsoleLine, consoleLineCapBytes);
  const stderr = createLineHandler('stderr', emitConsoleLine, consoleLineCapBytes);
  child.stdout.on('data', (chunk) => { void stdout.chunk(chunk); });
  child.stderr.on('data', (chunk) => { void stderr.chunk(chunk); });
  const progressDecoder = new StringDecoder('utf8');
  let progressDiscarding = false;
  const processProgressText = async (text, final) => {
    progressCarry += text;
    const lines = progressCarry.split(/\r?\n/);
    progressCarry = lines.pop() || '';
    if (final && progressCarry) {
      lines.push(progressCarry);
      progressCarry = '';
    }
    for (const line of lines) {
      if (progressDiscarding) {
        progressDiscarding = false;
        continue;
      }
      if (!line) continue;
      if (Buffer.byteLength(line) > consoleLineCapBytes) {
        await enqueue({ type: 'error', message: `progress line exceeded the ${consoleLineCapBytes} byte cap` });
        continue;
      }
      try {
        const event = validateProgressEvent(JSON.parse(line));
        if (event.message) event.message = await redactText(event.message);
        if (event.resumeCommand) event.resumeCommand = await redactText(event.resumeCommand);
        await enqueue({ type: 'progress', ...event });
      } catch (error) {
        await enqueue({ type: 'error', message: await redactText(`progress parse failed: ${error.message}`) });
      }
    }
    if (Buffer.byteLength(progressCarry) > consoleLineCapBytes) {
      progressCarry = '';
      if (!progressDiscarding) await enqueue({ type: 'error', message: `progress line exceeded the ${consoleLineCapBytes} byte cap` });
      progressDiscarding = true;
    }
  };
  const progressState = { offset: 0, decoder: progressDecoder };
  const timer = setInterval(() => { progressReading = progressReading.then(() => readProgressFile(progressPath, progressState, processProgressText, false)).catch((error) => enqueue({ type: 'error', message: `progress read failed: ${error.message}` })); }, 100);
  let code;
  try {
    code = await new Promise((resolveCode, reject) => {
      child.on('error', reject);
      child.on('close', resolveCode);
    });
  } finally {
    clearInterval(timer);
  }
  await Promise.all([
    child.stdout.readableEnded ? Promise.resolve() : once(child.stdout, 'end').catch(() => {}),
    child.stderr.readableEnded ? Promise.resolve() : once(child.stderr, 'end').catch(() => {}),
  ]);
  await stdout.end();
  await stderr.end();
  await progressReading;
  await readProgressFile(progressPath, progressState, processProgressText, true);
  await processProgressText(progressDecoder.end(), true);
  await emitQueue;
  return code;
}
