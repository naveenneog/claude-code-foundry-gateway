# Claude for Microsoft 365 Office add-ins

The Claude for Microsoft 365 add-in can use Azure AI Foundry through the
organization's existing Claude gateway. The gateway URL is supplied as the
add-in's `azure_base_url`; requests then use the existing `/v1/messages`
operation under the gateway path.

## Gateway requirement

The APIM policy allows the hosted task pane origin
`https://pivot.claude.ai`. It handles browser preflight before the existing
Entra validation, entitlement lookup, budget controls, content-safety policy
and managed-identity call to Foundry. The policy does not admit a wildcard
origin or a second client credential.

The policy contract is checked offline:

```powershell
pwsh -NoProfile -File .\tests\Test-OfficeGateway.ps1
```

Apply the policy through the existing repair path after reviewing the named
value read-back:

```powershell
pwsh -NoProfile -File .\scripts\Set-GatewayPolicy.ps1 `
  -ResourceGroup <gateway-resource-group> `
  -ApimName <apim-name> `
  -PolicyFile .\infra\policy.xml `
  -SubscriptionId <subscription-id>
```

The live browser probe is separate from policy deployment. It checks the
preflight, an unauthenticated error and refusal of a foreign origin:

```powershell
pwsh -NoProfile -File .\scripts\Test-ClaudeOfficeGateway.ps1 `
  -GatewayUrl https://<apim-name>.azure-api.net/claude
```

The probe must be run after the policy is deployed to a disposable or
owner-approved gateway. It does not acquire a user token and therefore does
not prove entitlement or a successful Foundry completion.

## Entra application and manifests

The add-in needs an NAA-capable Entra application with delegated Azure
Cognitive Services `user_impersonation` permission and tenant admin consent.
The manifest also needs the real Foundry resource name and the NAA client ID.
Those values are tenant-specific and are not committed to this repository.

The Office and Outlook manifests are separate. Outlook additionally needs the
Graph permissions required by the selected mailbox and calendar features.
Anthropic's current setup and permission requirements are documented at
[Claude for Microsoft 365 on third-party platforms](https://claude.com/docs/office-agents/third-party-platforms).

Install Anthropic's manifest generator:

```powershell
claude plugin marketplace add anthropics/financial-services
claude plugin install claude-for-msft-365-install@claude-for-financial-services
```

Start Claude and run:

```text
/claude-for-msft-365-install:setup
```

Select **Foundry direct** and generate the Office manifest. Generate the
separate Outlook manifest only when Outlook is in the pilot. The generated
configuration uses these tenant values:

| Setting | Value |
|---|---|
| `azure_resource_name` | Foundry account behind this gateway |
| `azure_base_url` | Gateway URL, including `/claude` |
| `entra_sso` | `1` |
| `graph_client_id` | NAA application client ID |
| `entra_scope` | `https://cognitiveservices.azure.com/.default` |
| `gateway_auth_source` | `entra` |

The plugin's setup wizard does not currently ask for `azure_base_url`.
Add it to both generated task-pane URLs, beside `azure_resource_name`, and
write query separators as `&amp;` in XML. No `azure_api_key` or
`gateway_token` is used on this path.

Validate each generated file before upload:

```powershell
npx --yes office-addin-manifest validate .\manifest.xml
npx --yes office-addin-manifest validate .\manifest-outlook.xml
```

The pilot order is:

1. Deploy and probe the gateway CORS policy.
2. Register or select the NAA application and grant consent.
3. Generate an Office manifest with the gateway URL, Foundry resource name and
   client ID.
4. Assign the manifest to a small Microsoft 365 pilot group.
5. Verify a permitted user reaches `/v1/messages`, a user outside the gateway
   entitlement receives the normal refusal, and the gateway logs the request
   under the user's object ID.

The existing trial manifests are generated artifacts with placeholders and
are not production manifests:

- `manifest-m365-office-trial.xml`
- `manifest-m365-outlook-trial.xml`

## References

- [Anthropic: third-party platforms](https://claude.com/docs/office-agents/third-party-platforms)
- [Microsoft Learn: APIM CORS policy](https://learn.microsoft.com/en-us/azure/api-management/cors-policy)
- [Microsoft Learn: nested app authentication](https://learn.microsoft.com/en-us/office/dev/add-ins/develop/enable-nested-app-authentication-in-your-add-in)
- [ADR-0061](adr/0061-office-add-in-gateway-cors.md)
