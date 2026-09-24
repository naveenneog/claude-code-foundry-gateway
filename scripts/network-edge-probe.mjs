import https from 'node:https';
import http2 from 'node:http2';
import fs from 'node:fs';
import crypto from 'node:crypto';
import { performance } from 'node:perf_hooks';
import { pathToFileURL } from 'node:url';

export function createEventMeter() {
  let pending = '';
  const events = [];
  return {
    events,
    push(chunk, elapsedMs) {
      pending += chunk.toString('utf8');
      let end;
      while ((end = pending.indexOf('\n')) >= 0) {
        const line = pending.slice(0, end).trimEnd();
        pending = pending.slice(end + 1);
        if (!line.startsWith('data:')) continue;
        let event;
        try { event = JSON.parse(line.slice(5).trim()); } catch { continue; }
        events.push({
          elapsedMs,
          type: event.type,
          text: event.type === 'content_block_delta' && typeof event.delta?.text === 'string' && event.delta.text.length > 0,
          outputTokens: event.usage?.output_tokens ?? event.message?.usage?.output_tokens ?? null,
          inputTokens: event.message?.usage?.input_tokens ?? null,
        });
      }
    },
  };
}

export async function probe(options) {
  const url = new URL(options.url);
  if (url.protocol !== 'https:') throw new Error('Inference probes require HTTPS.');
  if (!options.token || /[\r\n]/.test(options.token)) throw new Error('A bearer token is required.');
  const body = Buffer.from(JSON.stringify(options.body ?? {
    model: options.model,
    max_tokens: options.maxTokens ?? 32,
    stream: true,
    messages: [{ role: 'user', content: options.prompt ?? 'Reply with pong.' }],
  }));
  const headers = {
    ...options.headers,
    authorization: `Bearer ${options.token}`,
    'content-type': 'application/json',
    'anthropic-version': '2023-06-01',
    'content-length': String(body.length),
  };
  const start = performance.now();
  const meter = createEventMeter();
  const result = {
    startedUtc: new Date().toISOString(),
    status: null,
    httpVersion: null,
    tlsAuthorized: false,
    tlsProtocol: null,
    requestBytes: body.length,
    bearerBytes: Buffer.byteLength(headers.authorization),
    requestHeaderBytes: Object.entries(headers).reduce((n, [k, v]) => n + Buffer.byteLength(`${k}: ${v}\r\n`), 2),
    bodySha256: crypto.createHash('sha256').update(body).digest('hex'),
    headersMs: null,
    firstEventMs: null,
    firstTextMs: null,
    completedMs: null,
    maxEventGapMs: null,
    eventCount: 0,
    completed: false,
    responseBytes: 0,
    inputTokens: null,
    outputTokens: null,
    error: null,
  };
  const elapsed = () => Math.round((performance.now() - start) * 10) / 10;
  const tlsOptions = { rejectUnauthorized: true };
  if (options.caPath) tlsOptions.ca = fs.readFileSync(options.caPath);
  if (options.connectAddress) {
    tlsOptions.lookup = (_host, lookupOptions, callback) => {
      if (lookupOptions?.all) callback(null, [{ address: options.connectAddress, family: 4 }]);
      else callback(null, options.connectAddress, 4);
    };
  }
  let failureBody = '';
  const onData = chunk => {
    result.responseBytes += chunk.length;
    meter.push(chunk, elapsed());
    if (result.status !== 200 && failureBody.length < 4000) failureBody += chunk.toString('utf8');
  };
  try {
    await new Promise((resolve, reject) => {
      let client;
      let request;
      const deadline = setTimeout(() => {
        request?.destroy();
        client?.destroy();
        reject(new Error('Probe exceeded its total deadline.'));
      }, options.timeoutMs ?? 660000);
      const finish = (error) => {
        clearTimeout(deadline);
        client?.close();
        if (error) reject(error); else resolve();
      };
      if (options.http2) {
        client = http2.connect(url.origin, tlsOptions);
        client.on('error', finish);
        client.on('connect', () => {
          result.tlsAuthorized = client.socket.authorized;
          result.tlsProtocol = client.socket.getProtocol();
          result.httpVersion = client.alpnProtocol;
        });
        request = client.request({ ':method': 'POST', ':path': url.pathname + url.search, ...headers });
        request.on('response', responseHeaders => {
          result.status = responseHeaders[':status'];
          result.headersMs = elapsed();
        });
        request.on('data', onData);
        request.on('end', () => finish());
      } else {
        request = https.request(url, { ...tlsOptions, method: 'POST', headers }, response => {
          result.status = response.statusCode;
          result.httpVersion = response.httpVersion;
          result.headersMs = elapsed();
          result.tlsAuthorized = response.socket.authorized;
          result.tlsProtocol = response.socket.getProtocol();
          response.on('data', onData);
          response.on('error', finish);
          response.on('aborted', () => finish(new Error('Response stream aborted.')));
          response.on('end', () => finish());
        });
      }
      request.on('error', finish);
      request.end(body);
    });
  } catch (error) {
    result.error = error.code ?? error.message;
  }
  result.completedMs = elapsed();
  result.eventCount = meter.events.length;
  result.firstEventMs = meter.events[0]?.elapsedMs ?? null;
  result.firstTextMs = meter.events.find(e => e.text)?.elapsedMs ?? null;
  result.completed = meter.events.some(e => e.type === 'message_stop');
  result.maxEventGapMs = meter.events.length > 1
    ? Math.max(...meter.events.slice(1).map((e, i) => Math.round((e.elapsedMs - meter.events[i].elapsedMs) * 10) / 10))
    : null;
  result.inputTokens = meter.events.find(e => e.inputTokens !== null)?.inputTokens ?? null;
  result.outputTokens = meter.events.filter(e => e.outputTokens !== null).at(-1)?.outputTokens ?? null;
  if (failureBody) {
    try { result.errorType = JSON.parse(failureBody).error?.type ?? null; } catch { result.errorType = 'non-json-error'; }
  }
  return result;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  let input = '';
  for await (const chunk of process.stdin) input += chunk;
  try {
    const result = await probe(JSON.parse(input.replace(/^\uFEFF/, '')));
    process.stdout.write(JSON.stringify(result) + '\n');
    if (result.error) process.exitCode = 1;
  } catch (error) {
    process.stderr.write(`Probe failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
