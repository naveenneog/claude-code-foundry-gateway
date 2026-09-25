# onboarding/

Only this README ships. The configuration and handover artifacts are generated
for your deployment and are not committed to the public repository.

**Prerequisites:** a deployed gateway, confirmed tier membership and publication,
and its gateway/tenant values from [Setup](../docs/SETUP.md). Platform operators
own those Azure/Entra steps; developers only consume the bundle.

## What lands here

`Install-ClaudeGateway.ps1` (or `install-claude-gateway.sh`) writes
`claude-gateway.json` at the end of a successful deployment:

```jsonc
{
  "mode":          "gateway",
  "gatewayUrl":    "https://apim-contoso-claude.azure-api.net/claude",
  "tenantId":      "<your-tenant-id>",
  "apimName":      "apim-contoso-claude",
  "resourceGroup": "rg-contoso-claude",
  "standardGroup": "claude-code-standard",
  "premiumGroup":  "claude-code-premium",
  "authMode":      "interactive",
  "tiers": {
    "standard": { "tokensPerMinute": 20000, "tokensPerDay": 500000 },
    "premium":  { "tokensPerMinute": 80000, "tokensPerDay": 5000000 }
  },
  "organisation": { "tokensPerMonth": 100000000, "shared": true, "softCap": true },
  "generated": "2026-08-31 12:04"
}
```

This is an example of the PowerShell wizard's shape, not values to deploy.
`authMode` is read by the onboarding wrapper; legacy files without `mode` are
inferred. Current low-level workstation setup has model defaults independent of
this file: supply/verify your actual deployment names as described in
[Developer setup](../DEVELOPER.md#one-command).

`New-OnboardingEmail.ps1` then adds one HTML, text and `.eml` file per developer
you onboard.

## What it is for

`claude-gateway.json` is the handover artifact. Distribute it beside the complete
`scripts` folder, not a lone setup file: Desktop needs the credential helpers.
From the directory containing both, a developer runs:

```powershell
.\scripts\Setup-ClaudeWorkstation.ps1 -ConfigPath .\claude-gateway.json
```

and the script reads the gateway URL, tenant and tier limits from it, so they
type none of them.

## It contains no secret

Gateway URL, tenant id, group names, tier limits. All of it is information the
developer needs, and none of it grants access — **access is Entra group
membership**, applied server-side at the gateway. Someone holding this file
without being in the group gets `403`.

So it is safe to email, put on an internal share, or commit to a private
repository. It is gitignored here only because it is environment-specific and
would go stale, not because it is sensitive.

## Getting it to developers

| How | When |
|-----|------|
| `New-OnboardingEmail.ps1` generates the message | one person at a time; attach the config and bundle yourself or include an approved internal download link |
| Internal share or intranet page, with `-DistributionUrl` | a team; the email then carries a two-line command that fetches both |
| Bundle it with the setup script in your software portal | a managed rollout |

The generated `.eml` and Graph-send payload contain the message, **not a MIME
attachment of the config or helper bundle**. Review before sending.
**Manual:** in your mail client, attach the approved config, link the complete
scripts bundle and [DEVELOPER.md](../DEVELOPER.md). There is no Azure portal
button for local bundle distribution.

## Verify the handover

Have a pilot developer use the exact distributed bundle, restart each client,
make a short request and confirm the gateway connection. A successful installer
does not prove a separately distributed Desktop helper is present or will still
be present at its next token refresh.

## If you are a developer and do not have this file

Ask your platform team — they generated it when they built the gateway. You can
also skip the file entirely:

```powershell
.\scripts\Setup-ClaudeWorkstation.ps1 -GatewayUrl https://<apim>.azure-api.net/claude -TenantId <tenant-id>
```

Both values are safe to share over chat.
