// Find where a binary constructs a URL, with enough context to tell a real
// endpoint from a documentation link.
//
// A hostname list cannot distinguish "the app calls this" from "the app
// mentions this in a comment". This prints the surrounding characters so the
// difference is visible.
//
//   node scripts/find-endpoint-context.mjs <file> <needle> [chars]

import fs from 'fs';

const [, , target, needle, charsArg] = process.argv;
const pad = parseInt(charsArg || '90', 10);

const CHUNK = 16 * 1024 * 1024;
const OVERLAP = 4096;
const fd = fs.openSync(target, 'r');
const size = fs.fstatSync(fd).size;
const buf = Buffer.alloc(CHUNK);

let pos = 0;
let carry = '';
let carryBase = 0;
const seen = new Set();
let hits = 0;

while (pos < size && hits < 40) {
  const n = fs.readSync(fd, buf, 0, Math.min(CHUNK, size - pos), pos);
  const text = carry + buf.slice(0, n).toString('latin1');
  let idx = 0;
  while ((idx = text.indexOf(needle, idx)) !== -1) {
    const from = Math.max(0, idx - pad);
    const to = Math.min(text.length, idx + needle.length + pad);
    const snippet = text.slice(from, to).replace(/[\x00-\x1f]+/g, ' ').replace(/\s+/g, ' ').trim();
    if (!seen.has(snippet)) {
      seen.add(snippet);
      hits++;
      console.log(`--- @${carryBase + from}\n${snippet}\n`);
      if (hits >= 40) break;
    }
    idx += needle.length;
  }
  carryBase += text.length - OVERLAP;
  carry = text.slice(-OVERLAP);
  pos += n;
}
fs.closeSync(fd);
if (hits === 0) console.log(`(no occurrence of ${JSON.stringify(needle)})`);
