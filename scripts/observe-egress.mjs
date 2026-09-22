// A proxy that records every host a client tries to reach, and forwards it.
//
// The list of hostnames inside a binary is not the list a firewall has to
// allow. A binary carries documentation links, certificate authority URLs,
// example.com, and endpoints for clouds it is not talking to. Allowing all of
// them is over-permissive and allowing the wrong subset breaks the client with
// an error that never names the host it could not reach.
//
// So this sits in front of the client and writes down what was actually
// attempted. Run the client through it, use it normally, and read the log.
//
//   node scripts/observe-egress.mjs --port 8888 --out egress.json
//   $env:HTTPS_PROXY = 'http://127.0.0.1:8888'
//   claude -p "hello"
//
// It tunnels rather than intercepts: CONNECT is forwarded to the real host and
// the bytes are piped untouched. No certificate is generated and no TLS is
// terminated, so nothing here can read request bodies - only the host, which
// is the only thing a firewall rule needs.

import http from 'http';
import net from 'net';
import fs from 'fs';

const args = process.argv.slice(2);
const argOf = (n, d) => {
  const i = args.indexOf(n);
  return i >= 0 && args[i + 1] ? args[i + 1] : d;
};
const port = parseInt(argOf('--port', '8888'), 10);
const outPath = argOf('--out', 'egress.json');

const seen = new Map();

const SELF_NAMES = new Set(['127.0.0.1', 'localhost', '::1', '0.0.0.0', '[::1]']);
function isSelf(hostname, hport) {
  return SELF_NAMES.has(String(hostname).toLowerCase()) && Number(hport) === port;
}

function note(host, port, how, ok, err) {
  const key = `${host}:${port}`;
  const e = seen.get(key) || { host, port: Number(port), how, attempts: 0, ok: 0, failed: 0, errors: [] };
  e.attempts++;
  if (ok) e.ok++;
  else {
    e.failed++;
    if (err && !e.errors.includes(err)) e.errors.push(err);
  }
  seen.set(key, e);
  const mark = ok ? 'ok  ' : 'FAIL';
  process.stderr.write(`  ${mark} ${how.padEnd(7)} ${key}${err ? '  ' + err : ''}\n`);
}

const server = http.createServer((req, res) => {
  // Plain HTTP through a proxy carries the absolute URL in the request line.
  let host = req.headers.host || '';
  let hostname = host.split(':')[0];
  let hport = host.includes(':') ? host.split(':')[1] : '80';

  // Refuse to forward to ourselves. A browser or a health check that opens the
  // proxy address directly arrives as an ordinary request whose Host header is
  // the proxy, and forwarding it produces a loop that recurses until the port
  // runs out of sockets - measured at 15,945 self-connections before the first
  // real request was even visible in the log.
  if (isSelf(hostname, hport)) {
    res.writeHead(200, { 'content-type': 'text/plain' });
    res.end('egress observer: set HTTPS_PROXY to this address; do not browse it directly\n');
    return;
  }

  note(hostname, hport, 'http', true);
  const proxyReq = http.request(
    { host: hostname, port: hport, path: req.url, method: req.method, headers: req.headers },
    (pr) => {
      res.writeHead(pr.statusCode, pr.headers);
      pr.pipe(res);
    }
  );
  proxyReq.on('error', (e) => {
    note(hostname, hport, 'http', false, e.code);
    res.writeHead(502);
    res.end();
  });
  req.pipe(proxyReq);
});

server.on('connect', (req, clientSocket, head) => {
  const [hostname, hport = '443'] = req.url.split(':');
  if (isSelf(hostname, hport)) {
    clientSocket.end('HTTP/1.1 403 Forbidden\r\n\r\n');
    return;
  }
  const upstream = net.connect(Number(hport), hostname, () => {
    note(hostname, hport, 'connect', true);
    clientSocket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
    upstream.write(head);
    upstream.pipe(clientSocket);
    clientSocket.pipe(upstream);
  });
  upstream.on('error', (e) => {
    note(hostname, hport, 'connect', false, e.code);
    clientSocket.end();
  });
  clientSocket.on('error', () => upstream.destroy());
});

function flush() {
  const rows = [...seen.values()].sort((a, b) => b.attempts - a.attempts);
  fs.writeFileSync(outPath, JSON.stringify({ capturedUtc: new Date().toISOString(), hosts: rows }, null, 2));
  process.stderr.write(`\n${rows.length} distinct host:port recorded -> ${outPath}\n`);
}

process.on('SIGINT', () => { flush(); process.exit(0); });
process.on('SIGTERM', () => { flush(); process.exit(0); });

// Written continuously rather than only on exit. On Windows the observer is
// usually stopped by killing it, which runs no handler, and a capture that
// only exists in memory is lost exactly when it is wanted.
setInterval(flush, 2000).unref();

server.listen(port, '127.0.0.1', () => {
  process.stderr.write(`observing egress on 127.0.0.1:${port}\n`);
});
