// Pull hostnames out of a large binary without loading it whole.
// Chunks overlap by 256 bytes so a hostname straddling a boundary is not lost.
import fs from 'fs';

const target = process.argv[2];
const CHUNK = 16 * 1024 * 1024;
const OVERLAP = 256;

const fd = fs.openSync(target, 'r');
const size = fs.fstatSync(fd).size;
const buf = Buffer.alloc(CHUNK);
const hosts = new Map();

// Matches the host part of an absolute URL, plus bare FQDNs that look like
// service endpoints. Bare names are kept separate because they are noisier.
const urlRe = /https?:\/\/([a-zA-Z0-9.\-*]+\.[a-zA-Z]{2,63})/g;

let pos = 0;
let carry = '';
while (pos < size) {
  const n = fs.readSync(fd, buf, 0, Math.min(CHUNK, size - pos), pos);
  const text = carry + buf.slice(0, n).toString('latin1');
  let m;
  urlRe.lastIndex = 0;
  while ((m = urlRe.exec(text)) !== null) {
    const h = m[1].toLowerCase().replace(/\.+$/, '');
    hosts.set(h, (hosts.get(h) || 0) + 1);
  }
  carry = text.slice(-OVERLAP);
  pos += n;
}
fs.closeSync(fd);

const rows = [...hosts.entries()].sort((a, b) => b[1] - a[1]);
console.log(`distinct hostnames: ${rows.length}`);
for (const [h, c] of rows) {
  console.log(`${String(c).padStart(6)}  ${h}`);
}
