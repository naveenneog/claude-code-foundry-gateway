/**
 * Local inspector proxy.
 *
 * Sits between Claude Code and the Foundry Anthropic endpoint so we can see
 * exactly what Claude Code sends when ANTHROPIC_FOUNDRY_BASE_URL points at a
 * gateway: which path, which headers, and — decisively — whose Entra ID token
 * is on the request.
 *
 *   node inspect-proxy.mjs
 *   $env:ANTHROPIC_FOUNDRY_BASE_URL = "http://localhost:8787"
 *   claude -p "hello"
 *
 * Tokens are never printed; only non-sensitive JWT claims are decoded.
 */
import http from 'node:http';
import { discoverTargets, choose } from '../guide/lib/azure-targets.mjs';
import { az } from '../guide/lib/turnstile-live.mjs';

const args = process.argv.slice(2);
const option = (name) => { const index = args.indexOf(name); return index < 0 ? undefined : args[index + 1]; };
const PORT = Number(option('--port') ?? process.env.INSPECT_PORT ?? 8787);
if (!Number.isInteger(PORT) || PORT < 1 || PORT > 65535) throw new Error('Port must be 1–65535');
let UPSTREAM = option('--upstream') ?? process.env.INSPECT_UPSTREAM;
if (!UPSTREAM) {
  const targets = await discoverTargets({
    subscription: option('--subscription'), resourceGroup: option('--resource-group'),
    foundry: option('--foundry'), required: ['foundry'],
    nonInteractive: args.includes('--non-interactive') || !process.stdin.isTTY,
  });
  const resource = JSON.parse(az(['resource', 'show', '--ids', targets.foundry.id, '-o', 'json']));
  const endpoints = Object.entries(resource.properties.endpoints ?? {})
    .filter(([, value]) => typeof value === 'string' && value.startsWith('https://'))
    .map(([name, value]) => ({ name, id: value }));
  if (!endpoints.length && resource.properties.endpoint) endpoints.push({ name: 'Resource endpoint', id: resource.properties.endpoint });
  const endpoint = await choose('upstream endpoint', endpoints, option('--endpoint'), undefined,
    args.includes('--non-interactive') || !process.stdin.isTTY);
  UPSTREAM = new URL(option('--upstream-path') ?? '/anthropic', endpoint.id).href.replace(/\/$/, '');
}
const target = new URL(UPSTREAM);
if (target.protocol !== 'https:' || target.username || target.password || target.search || target.hash)
  throw new Error('Upstream must be an HTTPS service URL without credentials, query or fragment');
if (args.includes('--describe')) {
  console.log(JSON.stringify({ listen: `http://127.0.0.1:${PORT}`, upstream: UPSTREAM }));
  process.exit(0);
}

const decodeClaims = (jwt) => {
  try {
    const payload = JSON.parse(Buffer.from(jwt.split('.')[1], 'base64').toString('utf8'));
    return {
      aud: payload.aud,
      iss: payload.iss,
      oid: payload.oid,
      upn: payload.upn || payload.unique_name || payload.preferred_username,
      appid: payload.appid,
      tid: payload.tid,
      exp: new Date(payload.exp * 1000).toISOString(),
    };
  } catch {
    return { error: 'not a decodable JWT' };
  }
};

const server = http.createServer(async (req, res) => {
  console.log('\n' + '='.repeat(70));
  console.log(`${req.method} ${req.url}`);
  console.log('-'.repeat(70));

  for (const [k, v] of Object.entries(req.headers)) {
    if (k === 'authorization') {
      const token = String(v).replace(/^Bearer\s+/i, '');
      console.log(`authorization      : Bearer <${token.length} chars>`);
      console.log('  decoded claims   :', JSON.stringify(decodeClaims(token), null, 2).replace(/\n/g, '\n  '));
    } else if (k === 'x-api-key') {
      console.log(`x-api-key          : <${String(v).length} chars, redacted>`);
    } else {
      console.log(`${k.padEnd(19)}: ${v}`);
    }
  }

  const chunks = [];
  for await (const c of req) chunks.push(c);
  const body = Buffer.concat(chunks);

  if (body.length) {
    try {
      const j = JSON.parse(body.toString('utf8'));
      console.log('-'.repeat(70));
      console.log(`body: model=${j.model} max_tokens=${j.max_tokens} stream=${j.stream} messages=${j.messages?.length} tools=${j.tools?.length ?? 0}`);
    } catch {
      console.log(`body: ${body.length} bytes (not JSON)`);
    }
  }

  // Forward upstream unchanged so the session still works end to end.
  const headers = { ...req.headers };
  delete headers.host;
  delete headers['content-length'];

  const upstream = await fetch(UPSTREAM + req.url, {
    method: req.method,
    headers,
    body: body.length ? body : undefined,
  });

  console.log(`--> upstream ${upstream.status} ${upstream.headers.get('content-type')}`);

  res.writeHead(upstream.status, {
    'content-type': upstream.headers.get('content-type') || 'application/json',
  });

  if (upstream.body) {
    const reader = upstream.body.getReader();
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      res.write(Buffer.from(value));
    }
  }
  res.end();
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`inspector proxy listening on http://localhost:${PORT}`);
  console.log(`forwarding to ${UPSTREAM}`);
});
