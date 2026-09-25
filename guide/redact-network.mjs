// Pixel redaction for the initial subnet capture. Azure refreshed two cells
// after the first DOM pass; all later captures also use a MutationObserver.
// Like redact-entra.mjs, fail on unexpected dimensions rather than under-cover.
import sharp from 'sharp';
import fs from 'node:fs';
import path from 'node:path';

const source = process.argv[2];
const destination = process.argv[3];
if (!source || !destination) throw new Error('Pass the raw subnet screenshot and a different destination.');
if (path.resolve(source) === path.resolve(destination)) throw new Error('Keep the original in the ignored evidence directory.');
const image = sharp(source);
const size = await image.metadata();
if (size.width !== 1680 || size.height !== 1100) throw new Error('Unrecognized capture dimensions; review redaction coordinates.');
const rows = [
  { y: 325, prefix: '10.20.0.0/24', nsg: 'contoso-edge-nsg' },
  { y: 359, prefix: '10.20.1.0/24', nsg: 'contoso-apim-nsg' },
  { y: 392, prefix: '10.20.2.0/26' },
  { y: 425, prefix: '10.20.2.64/27' },
];
const svg = `<svg width="1680" height="1100">${rows.map(row => `
  <rect x="519" y="${row.y - 15}" width="140" height="27" fill="white"/>
  <text x="529" y="${row.y + 4}" font-family="Segoe UI" font-size="12" fill="#323130">${row.prefix}</text>
  ${row.nsg ? `<rect x="1284" y="${row.y - 15}" width="135" height="27" fill="white"/>
  <text x="1294" y="${row.y + 4}" font-family="Segoe UI" font-size="12" fill="#0078d4">${row.nsg}</text>` : ''}
`).join('')}</svg>`;
fs.mkdirSync(path.dirname(path.resolve(destination)), { recursive: true });
await image.composite([{ input: Buffer.from(svg) }]).toFile(destination);
console.log('Subnet capture redacted; review the resulting image before publishing.');
