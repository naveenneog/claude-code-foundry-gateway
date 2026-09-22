// A proxy that cuts the connection once a response starts flowing.
//
// Used to prove that Test-ClaudeNetwork.ps1 reports a reset as a reset rather
// than as an allowlist failure. A detector for a condition nobody has
// reproduced is a guess, and this condition - an inspecting proxy that cannot
// forward server-sent events and drops the connection instead of failing the
// request - is the one that sends people to re-check a firewall list that was
// never wrong.
//
//   node scripts/hostile-proxy.mjs --port 8877 --after 2048

import http from 'http';
import net from 'net';

const args = process.argv.slice(2);
const argOf = (n, d) => {
  const i = args.indexOf(n);
  return i >= 0 && args[i + 1] ? args[i + 1] : d;
};
const port = parseInt(argOf('--port', '8877'), 10);
const cutAfter = parseInt(argOf('--after', '2048'), 10);

const server = http.createServer((req, res) => {
  res.writeHead(200, { 'content-type': 'text/plain' });
  res.end('hostile proxy\n');
});

server.on('connect', (req, clientSocket, head) => {
  const [hostname, hport = '443'] = req.url.split(':');
  const upstream = net.connect(Number(hport), hostname, () => {
    clientSocket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
    upstream.write(head);

    let forwarded = 0;
    upstream.on('data', (chunk) => {
      forwarded += chunk.length;
      if (forwarded > cutAfter) {
        // Reset rather than close. A FIN would look like a clean end of
        // response; RST is what the client reports as ECONNRESET.
        process.stderr.write(`  cutting ${hostname} after ${forwarded} bytes\n`);
        clientSocket.resetAndDestroy ? clientSocket.resetAndDestroy() : clientSocket.destroy();
        upstream.destroy();
        return;
      }
      clientSocket.write(chunk);
    });
    clientSocket.on('data', (c) => upstream.write(c));
  });
  upstream.on('error', () => clientSocket.destroy());
  clientSocket.on('error', () => upstream.destroy());
});

server.listen(port, '127.0.0.1', () => {
  process.stderr.write(`hostile proxy on 127.0.0.1:${port}, cutting after ${cutAfter} bytes\n`);
});
