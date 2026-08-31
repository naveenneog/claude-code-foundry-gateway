# onboarding/

**This folder is empty until you deploy.** Nothing here ships in the
repository, because everything in it describes *your* specific deployment.

## What lands here

`Install-ClaudeGateway.ps1` (or `install-claude-gateway.sh`) writes
`claude-gateway.json` at the end of a successful deployment:

```jsonc
{
  "gatewayUrl":    "https://apim-yourgw.azure-api.net/claude",
  "tenantId":      "<your-tenant-id>",
  "apimName":      "apim-yourgw",
  "resourceGroup": "rg-claude-gateway",
  "standardGroup": "claude-code-standard",
  "premiumGroup":  "claude-code-premium",
  "tiers": {
    "standard": { "tokensPerMinute": 20000, "tokensPerDay": 500000 },
    "premium":  { "tokensPerMinute": 80000, "tokensPerDay": 5000000 }
  },
  "generated": "2026-08-31 12:04"
}
```

`New-OnboardingEmail.ps1` then adds one HTML, text and `.eml` file per developer
you onboard.

## What it is for

`claude-gateway.json` is the handover artifact. A developer runs:

```powershell
.\Setup-ClaudeWorkstation.ps1 -ConfigPath .\claude-gateway.json
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
| `New-OnboardingEmail.ps1` attaches it | one person at a time |
| Internal share or intranet page, with `-DistributionUrl` | a team; the email then carries a two-line command that fetches both |
| Bundle it with the setup script in your software portal | a managed rollout |

## If you are a developer and do not have this file

Ask your platform team — they generated it when they built the gateway. You can
also skip the file entirely:

```powershell
.\Setup-ClaudeWorkstation.ps1 -GatewayUrl https://<apim>.azure-api.net/claude -TenantId <tenant-id>
```

Both values are safe to share over chat.
