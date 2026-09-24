// Runs inside the private verifier. It imports a short-lived test CA/server
// chain into Key Vault over Private Link and returns only public trust material.
import fs from 'node:fs';
import path from 'node:path';
import { randomUUID, X509Certificate } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { setTimeout as sleep } from 'node:timers/promises';

const config = JSON.parse(fs.readFileSync(process.argv[2], 'utf8').replace(/^\uFEFF/, ''));
const vault = new URL(config.vaultUrl);
if (vault.protocol !== 'https:' || !vault.hostname.endsWith('.vault.azure.net')) throw new Error('Expected an Azure Key Vault HTTPS URL.');
if (!/^[a-zA-Z0-9-]+$/.test(config.certificateName) || !/^[a-zA-Z0-9.-]+$/.test(config.hostName)) throw new Error('Invalid certificate name or DNS name.');
const metadata = new URL('http://169.254.169.254/metadata/identity/oauth2/token');
metadata.searchParams.set('api-version', '2019-08-01');
metadata.searchParams.set('resource', 'https://vault.azure.net');
const tokenResponse = await fetch(metadata, { headers: { Metadata: 'true' }, signal: AbortSignal.timeout(10000) });
if (!tokenResponse.ok) throw new Error(`Managed identity token: HTTP ${tokenResponse.status}`);
const token = (await tokenResponse.json()).access_token;
const headers = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };
const endpoint = `${vault.origin}/certificates/${config.certificateName}`;
const api = '?api-version=2025-07-01';
let certificate;
let trust;
const deadline = Date.now() + 300000;
while (Date.now() < deadline) {
  const response = await fetch(endpoint + api, { headers, signal: AbortSignal.timeout(20000) });
  if (response.ok) {
    certificate = await response.json();
    if (certificate.tags?.networkIssuer === 'evaluation-ca') {
      trust = Object.keys(certificate.tags).filter(k => /^networkRoot\d+$/.test(k))
        .sort((a,b) => Number(a.slice(11))-Number(b.slice(11))).map(k => certificate.tags[k]).join('');
      if (trust && new X509Certificate(Buffer.from(trust,'base64')).ca) break;
    }
  }
  if (response.status === 403) { await sleep(10000); continue; }
  if (!response.ok && response.status !== 404) throw new Error(`Certificate metadata: HTTP ${response.status}`);
  // Key Vault's self-signed end-entity certificate is not a CA. Some native
  // clients reject it in a CA bundle. Issue a proper chain inside the VNet.
  const directory = path.join('/work','certificate-'+randomUUID());
  fs.mkdirSync(directory,{mode:0o700});
  try {
    const file = name => path.join(directory,name);
    const run = args => execFileSync('openssl',args,{stdio:'pipe'});
    run(['req','-x509','-newkey','rsa:2048','-sha256','-days','2','-nodes',
      '-keyout',file('root.key'),'-out',file('root.pem'),'-subj','/CN=Claude gateway evaluation CA',
      '-addext','basicConstraints=critical,CA:TRUE,pathlen:0','-addext','keyUsage=critical,keyCertSign,cRLSign']);
    run(['req','-new','-newkey','rsa:2048','-nodes','-keyout',file('leaf.key'),'-out',file('leaf.csr'),'-subj',`/CN=${config.hostName}`]);
    fs.writeFileSync(file('leaf.ext'),`basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:${config.hostName}\n`,{mode:0o600});
    run(['x509','-req','-in',file('leaf.csr'),'-CA',file('root.pem'),'-CAkey',file('root.key'),'-CAcreateserial',
      '-out',file('leaf.pem'),'-days','2','-sha256','-extfile',file('leaf.ext')]);
    run(['pkcs12','-export','-out',file('leaf.pfx'),'-inkey',file('leaf.key'),'-in',file('leaf.pem'),'-certfile',file('root.pem'),'-passout','pass:']);
    trust = new X509Certificate(fs.readFileSync(file('root.pem'))).raw.toString('base64');
    const tags = {networkIssuer:'evaluation-ca'};
    // Public CA material, not a credential. Tags preserve it for idempotent
    // re-runs without exporting a PFX or retaining the root's private key.
    trust.match(/.{1,240}/g).forEach((chunk,index) => tags[`networkRoot${index}`]=chunk);
    const imported = await fetch(endpoint+'/import'+api,{
      method:'POST',headers,signal:AbortSignal.timeout(30000),
      body:JSON.stringify({value:fs.readFileSync(file('leaf.pfx')).toString('base64'),pwd:'',
        policy:{issuer:{name:'Unknown'},key_props:{exportable:true,kty:'RSA'},secret_props:{contentType:'application/x-pkcs12'}},
        attributes:{enabled:true},tags}),
    });
    if (!imported.ok) throw new Error(`Certificate import: HTTP ${imported.status}`);
    certificate=await imported.json();
    break;
  } finally { fs.rmSync(directory,{recursive:true,force:true}); }
}
if (!certificate) throw new Error('Certificate did not become readable within five minutes. Check the runner role and private DNS.');
if (!certificate.attributes?.enabled || certificate.policy?.x509_props?.subject !== `CN=${config.hostName}`) throw new Error('Existing certificate does not match the selected listener.');
console.log(JSON.stringify({
  sid: certificate.sid,
  cer: certificate.cer,
  trust,
  attributes: certificate.attributes,
  policy: {
    keyProperties: { exportable: certificate.policy.key_props.exportable },
    secretProperties: { contentType: certificate.policy.secret_props.contentType },
  },
}));
