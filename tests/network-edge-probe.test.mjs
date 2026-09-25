import test from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import { createEventMeter, probe } from '../scripts/network-edge-probe.mjs';
import { redactNetworkText } from '../guide/lib/redact-network.mjs';

test('SSE records first event independently of first text and completion', () => {
  const meter = createEventMeter();
  meter.push(Buffer.from('event: message_start\ndata: {"type":"message_start","message":{"usage":{"input_tokens":27}}}\n\n'), 10);
  meter.push(Buffer.from('data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"not text"}}\n\n'), 20);
  meter.push(Buffer.from('data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"pong"}}\n\n'), 35);
  meter.push(Buffer.from('data: {"type":"message_delta","usage":{"output_tokens":2}}\n\ndata: {"type":"message_stop"}\n\n'), 50);
  assert.equal(meter.events[0].elapsedMs, 10);
  assert.equal(meter.events.find(e => e.text).elapsedMs, 35);
  assert.equal(meter.events.at(-1).type, 'message_stop');
  assert.equal(meter.events[0].inputTokens, 27);
  assert.equal(meter.events.at(-2).outputTokens, 2);
  assert.ok(meter.events.every(e => !('thinking' in e) && !('content' in e)));
});

test('SSE lines can cross chunks and use CRLF; heartbeat and malformed data do not count', () => {
  const meter = createEventMeter();
  meter.push(Buffer.from(': ping\r\ndata: broken\r\ndata: {"type":"content_'), 5);
  assert.equal(meter.events.length, 0);
  meter.push(Buffer.from('block_delta","delta":{"text":"ok"}}\r\n\r\n'), 20);
  assert.equal(meter.events.length, 1);
  assert.equal(meter.events[0].elapsedMs, 20);
  assert.equal(meter.events[0].text, true);
});

test('an empty delta is not first text', () => {
  const meter = createEventMeter();
  meter.push(Buffer.from('data: {"type":"content_block_delta","delta":{"text":""}}\n'), 10);
  assert.equal(meter.events[0].text, false);
});

test('probe refuses plaintext and CRLF credentials before opening a socket', async () => {
  await assert.rejects(probe({ url: 'http://contoso.invalid', token: 'example' }), /HTTPS/);
  await assert.rejects(probe({ url: 'https://contoso.invalid', token: 'example\r\ninjected' }), /bearer token/);
});

test('portal redaction includes truncated names, full emails and GUIDs', () => {
  const text = redactNetworkText('sample-live-name sample-l... sample-l\u2026 user@example.org 11111111-2222-3333-4444-555555555555', [['sample-live-name', 'contoso-edge']]);
  assert.ok(!text.includes('sample'));
  assert.ok(!text.includes('user@example.org'));
  assert.ok(!text.includes('11111111'));
  assert.ok(text.includes('contoso-edge...'));
});

test('TCP acceptance without a TLS handshake fails quickly, not as a healthy edge', async () => {
  const sockets = new Set();
  const server = net.createServer(socket => {
    sockets.add(socket);
    socket.on('error', () => {});
    socket.on('close', () => sockets.delete(socket));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  try {
    for (const http2 of [false, true]) {
      const result = await probe({
        url: `https://127.0.0.1:${server.address().port}/v1/messages`,
        token: 'example', model: 'contoso-model', tlsTimeoutMs: 100,
        timeoutMs: 1000, http2,
      });
      assert.equal(result.error, 'TLS_HANDSHAKE_TIMEOUT');
      assert.equal(result.tlsAuthorized, false);
      assert.equal(result.status, null);
      assert.equal(result.completed, false);
    }
  } finally {
    for (const socket of sockets) socket.destroy();
    await new Promise(resolve => server.close(resolve));
  }
});
