// Loaded with `node --import` before a sync entry point in the projection renewal simulation.
// Serves Microsoft Graph and Azure Resource Manager from the JSON fixture FAKE_FETCH_FIXTURE, and
// moves the clock to FAKE_NOW. Any other host is an error, so nothing leaves the machine.
import { appendFileSync, readFileSync } from 'node:fs';

const fixture = JSON.parse(readFileSync(process.env.FAKE_FETCH_FIXTURE, 'utf8'));

function reply(status, body) {
  return {
    ok: status >= 200 && status < 300,
    status,
    headers: { get: () => null },
    json: async () => body,
    text: async () => JSON.stringify(body),
  };
}

function graph(url) {
  const graphFixture = fixture.graph ?? {};
  if (url.pathname === '/v1.0/groups') {
    const filter = url.searchParams.get('$filter') ?? '';
    const match = /^displayName eq '(.*)'$/.exec(filter);
    const name = match ? match[1].replace(/''/g, "'") : '';
    const ids = graphFixture.groupsByName?.[name] ?? [];
    return reply(200, { value: ids.map((id) => ({ id, displayName: name })) });
  }
  const members = /^\/v1\.0\/groups\/([^/]+)\/transitiveMembers\/microsoft\.graph\.(user|servicePrincipal)$/.exec(url.pathname);
  if (members) {
    const [, id, cast] = members;
    if ((graphFixture.missing ?? []).includes(id)) {
      return reply(404, { error: { code: 'Request_ResourceNotFound', message: `Resource '${id}' does not exist or one of its queried reference-property objects are not present.` } });
    }
    if ((graphFixture.deny ?? []).includes(id)) {
      return reply(403, { error: { code: 'Authorization_RequestDenied', message: 'Insufficient privileges to complete the operation.' } });
    }
    const value = (graphFixture.members?.[id] ?? [])
      .filter((m) => (m.cast ?? 'user') === cast)
      .map((m) => ({ id: m.oid, userPrincipalName: m.upn, displayName: m.upn }));
    return reply(200, { value });
  }
  return reply(404, { error: { code: 'Request_ResourceNotFound', message: `stand-in Graph has no ${url.pathname}` } });
}

function arm(url) {
  const armFixture = fixture.arm ?? {};
  const match = /\/providers\/Microsoft\.ApiManagement\/service\/[^/]+\/namedValues\/([^/]+)$/.exec(url.pathname);
  if (!match) return reply(404, { error: { code: 'ResourceNotFound', message: `stand-in ARM has no ${url.pathname}` } });
  if (armFixture.status && armFixture.status !== 200) {
    return reply(armFixture.status, { error: { code: 'AuthorizationFailed', message: 'stand-in ARM refused the read' } });
  }
  const value = armFixture.namedValues?.[match[1]];
  if (value === undefined || value === null) return reply(404, { error: { code: 'ResourceNotFound', message: 'NamedValue not found.' } });
  return reply(200, { name: match[1], properties: { displayName: match[1], secret: Boolean(value.secret), ...(value.secret ? {} : { value: value.value }) } });
}

globalThis.fetch = async (input) => {
  const url = new URL(String(input));
  if (process.env.FAKE_FETCH_LOG) appendFileSync(process.env.FAKE_FETCH_LOG, `${url.host}${url.pathname}${decodeURIComponent(url.search)}\n`);
  if (url.host === 'graph.microsoft.com') return graph(url);
  if (url.host === 'management.azure.com') return arm(url);
  throw new Error(`stand-in fetch refuses ${url.host}`);
};

if (process.env.FAKE_NOW) {
  const RealDate = Date;
  const offset = RealDate.parse(process.env.FAKE_NOW) - RealDate.now();
  class FakeDate extends RealDate {
    constructor(...args) {
      if (args.length === 0) super(RealDate.now() + offset);
      else super(...args);
    }

    static now() {
      return RealDate.now() + offset;
    }
  }
  globalThis.Date = FakeDate;
}
