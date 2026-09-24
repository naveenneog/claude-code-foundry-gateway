/**
 * HTTP entry point. Deliberately thin: it turns a request into an object id,
 * asks Cosmos for one document, and hands it to toEntitlement. Every decision
 * that could be wrong lives in entitlement.mjs, where it is tested without
 * Azure.
 *
 * Authentication is not done here. The Function App is configured with Entra
 * authentication in infra/resolver.bicep, so an unauthenticated request never
 * reaches this code. Doing it in both places would mean two answers to the
 * question of who may call, and eventually they would differ.
 */
import { app } from '@azure/functions';
import { CosmosClient } from '@azure/cosmos';
import { DefaultAzureCredential } from '@azure/identity';
import { toEntitlement, isObjectId } from './entitlement.mjs';
import { createLookup } from './lookup.mjs';

const endpoint = process.env.COSMOS_ENDPOINT;
const databaseName = process.env.COSMOS_DATABASE ?? 'claude';
const containerName = process.env.COSMOS_CONTAINER ?? 'entitlement';
const tenantId = process.env.PROJECTION_TENANT_ID ?? '';

// Built once per process rather than per request. The credential caches tokens
// and the client holds connections; rebuilding both per invocation is what
// turns a 1 RU read into a slow one.
let container;
function getContainer() {
  if (!container) {
    // Key authentication is disabled on the account by projection.bicep, so
    // this is the only way in. It is also why the Function needs a role
    // assignment rather than a connection string.
    const client = new CosmosClient({ endpoint, aadCredentials: new DefaultAzureCredential(),
      connectionPolicy: { requestTimeout: 2500, retryOptions: { maxRetryAttemptCount: 0, maxWaitTimeInSeconds: 0 } } });
    container = client.database(databaseName).container(containerName);
  }
  return container;
}

const lookup = createLookup(async (oid, abortSignal) => {
  const { resource } = await getContainer().item(oid, oid).read({ abortSignal });
  return resource ?? null;
});

app.http('entitlement', {
  methods: ['GET'],
  authLevel: 'anonymous',
  route: 'entitlement/{oid}',
  handler: async (request, context) => {
    const oid = request.params.oid;

    if (!isObjectId(oid)) {
      return json(400, { error: 'not an object id' });
    }
    if (!endpoint) {
      // Misconfiguration, not a caller error. 500 is right and the message
      // names the setting, because the person reading it is an operator.
      context.error('COSMOS_ENDPOINT is not set');
      return json(500, { error: 'resolver is not configured: COSMOS_ENDPOINT is unset' });
    }

    let doc = null;
    try {
      // Point read by id and partition key - the cheapest operation Cosmos
      // offers, and measured flat at 1 RU from one record to 100,000.
      doc = await lookup(oid);
    } catch (err) {
      if (err?.code === 404) {
        doc = null;
      } else {
        // Anything else is the resolver failing, not the developer. The gateway
        // turns a non-200 into its own 503 and says so; what matters here is
        // that it is logged with the identity so it can be traced.
        context.error(`lookup failed for ${oid}: ${err?.message ?? err}`);
        return json(503, { error: 'entitlement lookup failed' });
      }
    }

    const result = toEntitlement(doc, { tenantId });
    if (!result.ok) {
      return json(result.status, { error: result.reason });
    }
    return json(200, result.record);
  },
});

function json(status, body) {
  return {
    status,
    headers: { 'Content-Type': 'application/json' },
    jsonBody: body,
  };
}
