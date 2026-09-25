// Post-capture pixel redaction closes a portal React re-render race: a label
// can refresh between the DOM audit and screenshot. Never publish the input.
import fs from 'node:fs';
import path from 'node:path';
import sharp from 'sharp';

const source = path.join('.aum-local', 'portal', 'aum-01-overview-unredacted.png');
const destination = path.join('docs', 'guide', 'aum-01-overview.png');
if (!fs.existsSync(source)) throw new Error('Missing private source capture; do not fabricate a portal image.');
const overlay = Buffer.from(`<svg width="1600" height="1060" xmlns="http://www.w3.org/2000/svg">
  <rect x="464" y="215" width="442" height="24" fill="white"/>
  <rect x="464" y="298" width="442" height="56" fill="white"/>
  <g font-family="Segoe UI, sans-serif" font-size="13">
    <text x="465" y="231" fill="#0078d4">rg-aum-contoso</text>
    <text x="465" y="315" fill="#0078d4">Contoso subscription</text>
    <text x="465" y="343" fill="#292827">00000000-0000-0000-0000-000000000000</text>
  </g>
</svg>`);
await sharp(source).composite([{ input: overlay }]).png().toFile(destination);
console.log(`Redacted captured resource identities: ${destination}`);
