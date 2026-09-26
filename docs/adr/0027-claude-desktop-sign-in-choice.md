# ADR-0027: Claude Desktop sign-in is an administrator choice

## Status

Accepted for P60.

## Context

Claude Desktop on third-party inference can authenticate to a gateway with a
credential helper or with its own OIDC sign-in. This repository shipped only the
helper path: Desktop ran `get-foundry-token` and reused the developer's Azure
CLI sign-in. The owner's requirement is that the administrator can choose the
Desktop sign-in mode once, record it in `claude-gateway.json`, and have both
developer setup scripts and fleet payloads write the matching Desktop keys.

The Anthropic configuration reference retrieved 2026-09-26 says
`inferenceCredentialKind` may be `static`, `helper-script`, `interactive`,
`vendor-profile`, `workforce` or `external-idp`. For a gateway, the current
spelling is `external-idp` with `inferenceIdpOidc` and `inferenceIdpAuthFlow`;
the older `inferenceGatewayOidc` names remain readable. The gateway guide,
retrieved the same day, says Entra browser sign-in needs a public-client app
with the mobile/desktop redirect URI `http://127.0.0.1/callback`, and broker
sign-in needs `ms-appx-web://Microsoft.AAD.BrokerPlugin/{client-id}` and
`msauth.com.anthropic.claudefordesktop://auth`. In `id_token` mode the gateway
validates `aud` as the Desktop app's client id. In `access_token` mode the
scopes name the gateway API and the gateway validates that API audience.

## Decision

The installer records a `desktopSignIn` object in `claude-gateway.json`.

`helper-script` remains the default and is unchanged. Desktop writes:

- `inferenceCredentialKind: helper-script`
- `inferenceCredentialHelper`
- `inferenceCredentialHelperTimeoutSec`
- `inferenceCredentialHelperTtlSec`
- `inferenceCredentialHelperSilentRefreshEnabled`

The gateway continues to accept only the existing Azure CLI/helper audiences:
`https://cognitiveservices.azure.com` and `https://ai.azure.com`.

For Desktop-owned sign-in, the recorded shape is:

```json
{
  "desktopSignIn": {
    "kind": "external-idp",
    "flow": "browser",
    "bearerTokenType": "id_token",
    "issuer": "https://login.microsoftonline.com/<tenant-id>/v2.0",
    "clientId": "<desktop-public-client-id>"
  }
}
```

`flow` may be `browser` or `broker`. `bearerTokenType` may be `id_token` or
`access_token`. `access_token` also requires `scopes` and `audience`; `resource`
is optional and is written only when supplied.

API Management receives a named value, `external-idp-extra-audience`. It is empty by
default. When Desktop external-idp is chosen, the installer sets it to the
Desktop app client id for `id_token`, or to the explicit gateway API audience
for `access_token`. The policy has two validation branches: empty keeps the old
audiences only; non-empty adds exactly that one audience. The tenant remains
pinned to `tenant-id` in both branches, so a token from another tenant or a
token for an unrecorded audience is refused.

The setup scripts and `New-ClaudeCodePolicy.ps1` share one renderer,
`scripts/ClaudeDesktopSignIn.ps1`. Invalid records fail before writing a
profile, instead of producing a Desktop configuration that opens and then fails
with a 401.

`scripts/New-ClaudeDesktopEntraApp.ps1` creates or discovers the public-client
registration and adds the browser redirect; with `-Broker` it adds both broker
redirects. It supports `-WhatIf` and never grants tenant-wide consent.

## Consequences

The helper path keeps the same operational properties: no Desktop app
registration, no new tenant consent, and no new gateway audience. It remains
the safest default in tenants where ordinary users cannot grant consent.

Browser external-idp removes the Azure CLI dependency for Desktop but adds an
Entra public-client app registration and consent review. With the default
`id_token` token type, the gateway must accept `aud = clientId`. If a tenant
blocks user consent for the public client or the requested scopes, users see an
Entra consent failure such as `AADSTS65001` or "Need admin approval" until an
authorized administrator grants consent.

Broker external-idp is for Conditional Access policies that require the
Microsoft Entra broker, such as managed-device or token-protection controls.
It requires the broker redirect URIs and is not a Linux sign-in flow.

`access_token` mode is supported only when the administrator supplies the
gateway API scope and audience. It is useful for gateways modeled as an OAuth
resource server, but it is not the default because it normally requires an API
app registration and delegated-permission consent in addition to the Desktop
public client.

## References

- Anthropic, "Configuration reference", retrieved 2026-09-26:
  <https://claude.com/docs/third-party/claude-desktop/configuration>
- Anthropic, "Deploy Claude Desktop on 3P with an LLM gateway", retrieved
  2026-09-26:
  <https://claude.com/docs/third-party/claude-desktop/gateway>
- Anthropic, "Deploy with MDM", retrieved 2026-09-26:
  <https://claude.com/docs/third-party/claude-desktop/mdm>
- Microsoft Learn, "Azure API Management policy reference -
  validate-azure-ad-token", retrieved 2026-09-26:
  <https://learn.microsoft.com/en-us/azure/api-management/validate-azure-ad-token-policy>
