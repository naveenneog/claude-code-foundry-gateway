# Azure AI Content Safety request screening

P102 adds optional request screening in API Management before a Claude Messages request reaches Microsoft Foundry. The default deployment remains unchanged: `deployContentSafety` is `false`, `content-safety-mode` is `off`, and the policy fragment emits no Content Safety calls.

## Limits

- Screened text: the Claude Messages `system` field, `tools[].description`, and the newest turn: newest user text blocks, plain-text `document` blocks, `search_result` text, plain text, plain-text documents or `search_result` text inside the newest user's `tool_result` blocks, and a trailing assistant prefill after that newest user message.
- Prompt Shields `userPrompt`: caller-written newest user text and assistant prefill text. Prompt Shields `documents`: the newest turn's documents, tool results and search results, then the tool descriptions, because Microsoft describes Prompt Shields document attacks as third-party content and tool-response intervention content ([Microsoft Learn, read 2026-10-07](https://learn.microsoft.com/en-us/azure/ai-services/content-safety/concepts/jailbreak-detection)).
- Harm analysis `text:analyze`: all screened text, using `Hate`, `Violence`, `SelfHarm` and `Sexual` with `FourSeverityLevels`. The REST reference caps one analyze request at 10,000 Unicode characters and defines four-level severities as 0, 2, 4 and 6 ([Microsoft Learn, read 2026-10-07](https://learn.microsoft.com/en-us/rest/api/contentsafety/text-operations/analyze-text?view=rest-contentsafety-2024-09-01)).
- Newest turn first: the newest turn has the first claim on the 10,000-character analyze budget and on the 10,000-character document budget. It gets all it needs when the system prompt and tool descriptions are short, and at least 6,000 characters when they are long; the system prompt and tool descriptions share what is left. So a newest turn of up to 6,000 characters is screened in full whatever the size of the system prompt and tool descriptions.
- Sampling: within each budget, parts shorter than an equal share are kept whole and the rest of the budget is split among the longer parts. A part longer than its share keeps its head and tail, joined by a `content safety sampled` marker, and the trace records `truncated=true`.
- Prompt Shields document budget: the service limit is a 10,000-character prompt, up to five documents and 10,000 total document characters ([Microsoft Learn, read 2026-10-07](https://learn.microsoft.com/en-us/azure/ai-services/content-safety/region-availability)). The newest turn's sources fill up to four documents, or five without tools; more sources are grouped into those documents. All tool descriptions share one document.
- Not screened as text: earlier conversation turns, image/PDF/URL documents, base64 document sources and any document source that is not already plain text. These are documented limits, not safety passes.
- Prompt Shields does not receive the system prompt. Attack text that is only in `system` is checked by harm analysis, which has no attack category; a request whose only screened text is `system`, for example with an image-only user turn, makes no Prompt Shields call.
- Truncation mode: the named value `content-safety-truncate-mode` defaults to `newest` in `infra/main.bicep`. With `block`, a request whose newest-turn text would be sampled is `unscreenable`: block mode returns 400 and audit mode forwards with trace metadata. The system prompt and tool descriptions are sampled in both truncation modes. Unknown truncation-mode values are treated as `block`.
- Turning screening off leaves no screening record: with `content-safety-mode` set to `off`, the fragment writes no trace. A change to a named value is the activity log operation `Microsoft.ApiManagement/service/namedValues/write` ([Microsoft Learn, read 2026-10-07](https://learn.microsoft.com/en-us/azure/role-based-access-control/permissions/integration)), and an activity log alert reports a new event that matches its conditions ([Microsoft Learn, read 2026-10-07](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-types)). P102 does not deploy such an alert.

## Modes

| Mode | Behavior |
|---|---|
| `off` | No Prompt Shields or analyze call is made. The existing Foundry forwarding path is unchanged. |
| `audit` | Prompt Shields and analyze run and trace the decision, but the Claude request continues. Content Safety errors are logged. If the body cannot be read as a Claude Messages request, no Content Safety call is made and the trace decision is `unscreenable`. |
| `block` | Detected prompt attacks or severity at or above `content-safety-threshold` return Anthropic-style 403 JSON before Foundry. Content Safety errors or timeouts return 503 with `Retry-After: 5`. If the body cannot be read as a Claude Messages request, the gateway returns Anthropic-style 400 `invalid_request_error` JSON and traces decision `unscreenable`. |

The default threshold is `2`, matching the first nonzero severity in `FourSeverityLevels`.

## Change a setting

The fragment reads five API Management named values, which are name/value pairs that policies reference ([Microsoft Learn, read 2026-10-07](https://learn.microsoft.com/en-us/azure/api-management/api-management-howto-properties)). Changing a value changes neither the API policy nor the fragment.

| Named value | Accepted values | Default |
|---|---|---|
| `content-safety-mode` | `off`, `audit` or `block`. The fragment trims and lowercases the value, and any other value enforces as `block`. | `off`. `-DeployContentSafety` writes `-ContentSafetyMode`, whose default is `block`. |
| `content-safety-threshold` | `0`-`6`. The fragment clamps other whole numbers to 0-6 and reads any other text as `2`. | `2` |
| `content-safety-timeout-seconds` | `1`-`30`, the range `infra/main.bicep` accepts. | `10` |
| `content-safety-truncate-mode` | `newest` or `block`. Any other value acts as `block`. | `newest` |
| `content-safety-endpoint` | The endpoint of the Content Safety account that the gateway's managed identity calls. | The deployed account's endpoint. The update flow creates it as `https://content-safety-off.invalid`, which is not called while the mode is `off`. |

Read and change a value with the Azure CLI, using the gateway's resource group and API Management name:

```text
az apim nv show   -g <resource-group> --service-name <apim-name> --named-value-id content-safety-mode --query value -o tsv
az apim nv update -g <resource-group> --service-name <apim-name> --named-value-id content-safety-mode --value audit -o none
az apim nv update -g <resource-group> --service-name <apim-name> --named-value-id content-safety-threshold --value 4 -o none
az apim nv update -g <resource-group> --service-name <apim-name> --named-value-id content-safety-truncate-mode --value block -o none
```

`audit` and `block` call the account named by `content-safety-endpoint`. On a gateway whose endpoint is still `https://content-safety-off.invalid`, no account answers, so block mode returns 503 for every screened request. Running `Install-ClaudeGateway.ps1` with `-DeployContentSafety` creates the account, the APIM role assignment and the endpoint value.

### Installer re-runs

`Install-ClaudeGateway.ps1` reads the five values before it deploys `infra/main.bicep` and passes them back to the template:

| Re-run | Mode | Endpoint, threshold and timeout | Truncate mode |
|---|---|---|---|
| Without `-DeployContentSafety` or `-ContentSafetyMode` | Kept, lowercased | Kept | Kept. The template writes `newest`, then the installer writes the previous value back. |
| With `-ContentSafetyMode <mode>` only | `<mode>` | Kept | Kept |
| With `-DeployContentSafety` | `-ContentSafetyMode`, default `block` | The created account's endpoint, threshold `2`, timeout `10` | `newest` |

A kept value has to be one the template accepts: mode `off`, `audit` or `block`, threshold 0-6 and timeout 1-30. Another value, for example threshold `8`, which the fragment itself clamps to 6, stops the re-run before the template deploys.

## Cost

Content Safety bills Standard text records of up to 1,000 characters each; a longer input counts one record for each 1,000 characters ([Azure pricing, read 2026-10-07](https://azure.microsoft.com/en-us/pricing/details/content-safety/)). A request with no screened text makes no call. A request whose only call is `analyze` with under 1,000 characters uses 1 record, two calls with under 1,000 characters each use 2 records, and full `analyze`, prompt and document budgets use 30-34 records. At the list price of USD 0.375 per 1,000 records read on 2026-10-06, that is USD 0 to 12.75 per 1,000 requests. Tool descriptions count toward the `analyze` and document budgets. [ADR-0055](adr/0055-content-safety-screening.md#amendment-2026-10-07-p102-council-round-2-prompt-shields-calls-and-text-records) has the per-row estimate and its assumptions.

## Deployment

`infra/main.bicep` always creates the APIM policy fragment and named values so the policy shape is stable. The Azure AI Content Safety account is created only when `deployContentSafety=true`. The module `infra/content-safety.bicep` creates a Cognitive Services account with `kind: ContentSafety`, SKU `S0`, a custom subdomain, disabled local authentication, and a Cognitive Services User role assignment for the APIM managed identity. Microsoft Entra authentication for AI services requires a custom subdomain and Microsoft recommends disabling local authentication when using Entra ID ([Microsoft Learn, read 2026-10-06](https://learn.microsoft.com/en-us/azure/ai-services/authentication)).

The disposable live proof script is `scripts/Test-ClaudeLiveContentSafety.ps1`. It validates inputs before any Azure CLI call, refuses the default Azure CLI profile unless `-UseCurrentAzLogin` is passed, writes a receipt before the first create and after each owned resource is created, creates run-specific tier groups, adds the signed-in user to the standard group, installs a Basic v2 named-value gateway with `-DeployContentSafety -ContentSafetyMode block`, reads the first `models-standard` model unless `-Model` is supplied, waits for an authenticated benign request to return 200, records T1-T11 plus the AC20 and AC21 cases, checks Content Safety trace metadata, and tears down only resources recorded as created by that run. `-Teardown` runs the proof and then tears down in `finally`; `-TeardownOnly -ReceiptPath <file>` is the crash-recovery cleanup path. `-UpgradeFrom <older-checkout>` installs with the older checkout, runs this checkout's update flow with `-KeepNamedValues`, and proves mode `off` preserves a benign 200 and lets the harmful sample pass. After APIM and Content Safety purges, teardown waits briefly and checks whether a deployIfNotExists policy recreated the resource group; if the group reappears empty, the script deletes it again and records `CognitiveServices_Diagnostics_Enable` as the remediation source in the receipt.

Owner-run command for the reference proof:

```powershell
$env:AZURE_CONFIG_DIR = 'C:\path\to\isolated\azure-profile'
./scripts/Test-ClaudeLiveContentSafety.ps1 `
  -UseCurrentAzLogin `
  -SubscriptionId <subscription-id> `
  -Location eastus2 `
  -NamePrefix p102live<unique> `
  -RunId p102live<unique> `
  -FoundryAccount <foundry-account> `
  -FoundryResourceGroup <foundry-resource-group> `
  -PublisherEmail ops@example.com `
  -Teardown
```

Crash-recovery teardown can be re-run from the receipt:

```powershell
./scripts/Test-ClaudeLiveContentSafety.ps1 -UseCurrentAzLogin -TeardownOnly -ReceiptPath .\p102-content-safety-live-receipt.json
```

## Logging

The policy writes one trace per screened or unscreenable request, with the message `content safety request screening` and the custom property `screening` set to `claude-content-safety`; a trace's `source` attribute is not stored as a custom property. Metadata includes mode, decision, blocked reason, severity numbers, booleans for Prompt Shields results, threshold, truncation and elapsed milliseconds. It does not store prompt text, system text, tool text, model output, image bytes or matched snippets. With `content-safety-mode` set to `off`, the policy does not screen and writes no trace.

```kusto
traces
| where timestamp > ago(24h)
| where message == "content safety request screening"
| where customDimensions.screening == "claude-content-safety"
| project timestamp,
          operation_Id,
          mode=tostring(customDimensions.mode),
          decision=tostring(customDimensions.decision),
          blockedBy=tostring(customDimensions.blockedBy),
          hate=toint(customDimensions.hateSeverity),
          violence=toint(customDimensions.violenceSeverity),
          selfHarm=toint(customDimensions.selfHarmSeverity),
          sexual=toint(customDimensions.sexualSeverity),
          truncated=tobool(customDimensions.truncated),
          elapsedMs=toint(customDimensions.contentSafetyElapsedMs)
| order by timestamp desc
```




Upgrade-mode command for a pre-P102 checkout:

```powershell
$env:AZURE_CONFIG_DIR = 'C:\path\to\isolated\azure-profile'
$run = 'p102up' + (Get-Date -Format yyyyMMddHHmm)
./scripts/Test-ClaudeLiveContentSafety.ps1 `
  -UseCurrentAzLogin `
  -SubscriptionId <subscription-id> `
  -Location eastus2 `
  -NamePrefix $run `
  -RunId $run `
  -FoundryAccount <foundry-account> `
  -FoundryResourceGroup <foundry-resource-group> `
  -PublisherEmail ops@example.com `
  -UpgradeFrom C:\path\to\p100-checkout `
  -Teardown
```
