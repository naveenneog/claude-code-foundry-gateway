# Azure AI Content Safety request screening

P102 adds optional request screening in API Management before a Claude Messages request reaches Microsoft Foundry. The default deployment remains unchanged: `deployContentSafety` is `false`, `content-safety-mode` is `off`, and the policy fragment emits no Content Safety calls.

## Limits

- Screened text: the Claude Messages `system` field, newest user text blocks, plain-text `document` blocks in the newest user message, a trailing assistant prefill after that newest user message, `tools[].description`, and plain text or plain-text document blocks inside that newest user's `tool_result` blocks.
- Prompt Shields `userPrompt`: caller-written newest user text and assistant prefill text. Prompt Shields `documents`: tool descriptions, tool results and document text, because Microsoft describes Prompt Shields document attacks as third-party content and tool-response intervention content ([Microsoft Learn, read 2026-10-07](https://learn.microsoft.com/en-us/azure/ai-services/content-safety/concepts/jailbreak-detection)).
- Harm analysis `text:analyze`: all screened text, using `Hate`, `Violence`, `SelfHarm` and `Sexual` with `FourSeverityLevels`. The REST reference caps one analyze request at 10,000 Unicode characters and defines four-level severities as 0, 2, 4 and 6 ([Microsoft Learn, read 2026-10-07](https://learn.microsoft.com/en-us/rest/api/contentsafety/text-operations/analyze-text?view=rest-contentsafety-2024-09-01)).
- Sampling: `content-safety-truncate-mode=newest` samples every oversized item from its head and tail, joined by a `content safety sampled` marker. This keeps a harmful prefix visible when it is followed by more than 10,000 padding characters. The analyze request gives each screened part a fair share of the 10,000-character budget.
- Prompt Shields document budget: the service limit is a 10,000-character prompt, up to five documents and 10,000 total document characters ([Microsoft Learn, read 2026-10-07](https://learn.microsoft.com/en-us/azure/ai-services/content-safety/region-availability)). The policy gives each document a fair share. More than five source documents are grouped into five sampled document strings so each source contributes text.
- Not screened as text: earlier conversation turns, image/PDF/URL documents, base64 document sources and any document source that is not already plain text. These are documented limits, not safety passes.
- Truncation mode: the named value `content-safety-truncate-mode` defaults to `newest` in `infra/main.bicep`. Operators change the APIM named value to `block` to turn any oversized screened item or grouped document set into `unscreenable`; block mode returns 400 and audit mode forwards with trace metadata. Unknown truncation-mode values are treated as `block`.

## Modes

| Mode | Behavior |
|---|---|
| `off` | No Prompt Shields or analyze call is made. The existing Foundry forwarding path is unchanged. |
| `audit` | Prompt Shields and analyze run and trace the decision, but the Claude request continues. Content Safety errors are logged. If the body cannot be read as a Claude Messages request, no Content Safety call is made and the trace decision is `unscreenable`. |
| `block` | Detected prompt attacks or severity at or above `content-safety-threshold` return Anthropic-style 403 JSON before Foundry. Content Safety errors or timeouts return 503 with `Retry-After: 5`. If the body cannot be read as a Claude Messages request, the gateway returns Anthropic-style 400 `invalid_request_error` JSON and traces decision `unscreenable`. |

The default threshold is `2`, matching the first nonzero severity in `FourSeverityLevels`.

## Deployment

`infra/main.bicep` always creates the APIM policy fragment and named values so the policy shape is stable. The Azure AI Content Safety account is created only when `deployContentSafety=true`. The module `infra/content-safety.bicep` creates a Cognitive Services account with `kind: ContentSafety`, SKU `S0`, a custom subdomain, disabled local authentication, and a Cognitive Services User role assignment for the APIM managed identity. Microsoft Entra authentication for AI services requires a custom subdomain and Microsoft recommends disabling local authentication when using Entra ID ([Microsoft Learn, read 2026-10-06](https://learn.microsoft.com/en-us/azure/ai-services/authentication)).

The disposable live proof script is `scripts/Test-ClaudeLiveContentSafety.ps1`. It validates inputs before any Azure CLI call, refuses the default Azure CLI profile unless `-UseCurrentAzLogin` is passed, writes a receipt before the first create and after each owned resource is created, creates run-specific tier groups, adds the signed-in user to the standard group, installs a Basic v2 named-value gateway with `-DeployContentSafety -ContentSafetyMode block`, reads the first `models-standard` model unless `-Model` is supplied, waits for an authenticated benign request to return 200, records T1-T11 plus the AC20 and AC21 cases, checks Content Safety trace metadata, and tears down only resources recorded as created by that run. `-Teardown` runs the proof and then tears down in `finally`; `-TeardownOnly -ReceiptPath <file>` is the crash-recovery cleanup path. `-UpgradeFrom <older-checkout>` installs with the older checkout, runs this checkout's update flow with `-KeepNamedValues`, and proves mode `off` preserves a benign 200 and lets the harmful sample pass. After APIM and Content Safety purges, teardown waits briefly and checks whether a deployIfNotExists policy recreated the resource group; if the group reappears empty, the script deletes it again and records `CognitiveServices_Diagnostics_Enable` as the remediation source in the receipt.

Owner-run command for the reference proof:

```powershell
$env:AZURE_CONFIG_DIR = 'C:\path\to\isolated\azure-profile'
./scripts/Test-ClaudeLiveContentSafety.ps1 `
  -UseCurrentAzLogin `
  -SubscriptionId e839ff0f-532b-4828-a2b3-8c9a1b719d85 `
  -Location eastus2 `
  -NamePrefix p102live<unique> `
  -RunId p102live<unique> `
  -FoundryAccount ai-contosohub530569751908 `
  -FoundryResourceGroup rg-contosohub `
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
  -SubscriptionId e839ff0f-532b-4828-a2b3-8c9a1b719d85 `
  -Location eastus2 `
  -NamePrefix $run `
  -RunId $run `
  -FoundryAccount ai-contosohub530569751908 `
  -FoundryResourceGroup rg-contosohub `
  -PublisherEmail ops@example.com `
  -UpgradeFrom C:\path\to\p100-checkout `
  -Teardown
```
