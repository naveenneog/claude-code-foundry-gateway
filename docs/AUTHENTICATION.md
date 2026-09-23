# Authentication types, measured

The gateway accepts one kind of credential: a Microsoft Entra ID access token
whose audience is `https://cognitiveservices.azure.com` or `https://ai.azure.com`.
How a caller obtains that token differs by who the caller is, and the
differences matter for token lifetime, for Conditional Access, and for how
access is taken away.

Everything marked **measured** was run on 2026-09-23 against an API Management
Premium v2 gateway reading entitlement from the projection, with the resolver
and the Foundry account both private
([Deploy the projection privately](SECURE-PROJECTION.md)). To test a credential
without spending model capacity, the request asked for a model its tier may not
call. The gateway then authenticates the caller and resolves entitlement before
it refuses, so a `403 model_not_allowed` means *authenticated and entitled*.

## The matrix

| Caller | How it gets the token | At the gateway | Token lifetime | Status |
|---|---|---|---|---|
| Developer, Azure CLI sign-in | `az login`; Claude Code reads it through `DefaultAzureCredential` | Served. Claude Code CLI 2.1.272 answered `pong` in 9 seconds | 86 minutes | measured |
| Developer, the other audience | `az account get-access-token --resource https://ai.azure.com` | Served. Both audiences are accepted | 67 minutes | measured |
| Managed identity (a container inside the VNet) | `ManagedIdentityCredential` | 150 of 150 requests authorised, entitled through the projection alone | not recorded | measured |
| Service principal with a client secret | Client credentials | `403 permission_error` until entitled; entitled 39 seconds after its projection record was written | **1,445 minutes, about 24 hours** | measured |
| Any caller, wrong audience | For example `https://management.azure.com` | `401` | | measured |
| Any caller, garbled or missing token | | `401` | | measured |
| Developer, device code sign-in | `az login --use-device-code` | Not run here: it needs a person to enter the code | | not measured |
| Workload identity federation | For example GitHub Actions OIDC | Not run here | | not measured |

## What takes access away

**The gateway's entitlement check, not token expiry.** A service principal's
token lived for about 24 hours, so deleting its secret leaves a working token in
circulation for up to a day. What stops it is removing the identity from the
entitlement source. On the projection that took effect within the cache
windows: a refused answer is cached for at most 60 seconds, and an entitled one
for `entitlement-cache-seconds`. The same holds for people: removing a developer
from the Entra group does nothing until the sync publishes it and the cached
answer expires.

## Things that surprised us

| Symptom | Cause | What to do |
|---|---|---|
| `az ad app credential reset` fails with `Credential lifetime exceeds the max value allowed as per assigned policy` | A tenant app-management policy caps client-secret lifetime. A 1-year secret was refused, a 7-day one accepted | Use a short secret, a certificate or a federated credential; ask the tenant administrator what the cap is |
| A new secret is refused for the first seconds | Propagation. A token was issued 20 seconds after the secret was created | Retry for up to a minute before treating it as wrong |
| A signed-in developer gets `401 A Microsoft Entra ID token is required. Run 'az login'.` | The token has the wrong audience. The message is the same as for no token at all | Check the client requests `https://cognitiveservices.azure.com`; `az account get-access-token --resource https://cognitiveservices.azure.com` shows what it would get |

## Conditional Access

Device code sign-in happens on a second device, so a policy that requires a
compliant or joined device, or that blocks the device code flow, stops it. That
matters most for Claude Desktop, whose own Entra sign-in uses device code: under
such a policy, use the credential helper the setup installs, which gets its
token from the Azure CLI on the managed machine instead. Service principals and
managed identities are not subject to user Conditional Access policies.
Microsoft's guidance is that organisations "get as close as possible to a
unilateral block on device code flow"
([Block authentication flows with Conditional Access](https://learn.microsoft.com/entra/identity/conditional-access/policy-block-authentication-flows)).
