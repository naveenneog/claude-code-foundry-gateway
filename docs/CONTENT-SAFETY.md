# Azure AI Content Safety request screening

P102 adds optional request screening in API Management before a Claude Messages request reaches Microsoft Foundry. The default deployment remains unchanged: `deployContentSafety` is `false`, `content-safety-mode` is `off`, and the policy fragment emits no Content Safety calls.

## What is screened

The gateway screens only the Claude Messages `system` field and the newest `user` message. It builds two Azure AI Content Safety requests:

- Prompt Shields `text:shieldPrompt`: `userPrompt` from newest user text, and `documents` from newest user `tool_result` text.
- Harm analysis `text:analyze`: system text, newest user text and newest user `tool_result` text, using `Hate`, `Violence`, `SelfHarm` and `Sexual` with `FourSeverityLevels`.

The newest slice is capped at 10,000 characters and tool-result documents at five documents and 10,000 total characters. When the newest turn is over budget, the policy screens the newest part and logs `truncated=true`. Earlier conversation turns are not screened; the fabricated-history case is a documented limit, not a safety pass. The contract is in [ADR-0055](adr/0055-content-safety-screening.md), based on Microsoft Learn pages for [Analyze Text](https://learn.microsoft.com/en-us/rest/api/contentsafety/text-operations/analyze-text?view=rest-contentsafety-2024-09-01), [Shield Prompt](https://learn.microsoft.com/en-us/rest/api/contentsafety/text-operations/shield-prompt?view=rest-contentsafety-2024-09-01), [Prompt Shields](https://learn.microsoft.com/en-us/azure/ai-services/content-safety/concepts/jailbreak-detection) and [region availability](https://learn.microsoft.com/en-us/azure/ai-services/content-safety/region-availability), read 2026-10-06.

## Modes

| Mode | Behavior |
|---|---|
| `off` | No Prompt Shields or analyze call is made. The existing Foundry forwarding path is unchanged. |
| `audit` | Prompt Shields and analyze run and trace the decision, but the Claude request continues. Content Safety errors are logged. |
| `block` | Detected prompt attacks or severity at or above `content-safety-threshold` return Anthropic-style 403 JSON before Foundry. Content Safety errors or timeouts return 503 with `Retry-After: 5`. |

The default threshold is `2`, matching the first nonzero severity in `FourSeverityLevels`.

## Deployment

`infra/main.bicep` always creates the APIM policy fragment and named values so the policy shape is stable. The Azure AI Content Safety account is created only when `deployContentSafety=true`. The module `infra/content-safety.bicep` creates a Cognitive Services account with `kind: ContentSafety`, SKU `S0`, a custom subdomain, disabled local authentication, and a Cognitive Services User role assignment for the APIM managed identity. Microsoft Entra authentication for AI services requires a custom subdomain and Microsoft recommends disabling local authentication when using Entra ID ([Microsoft Learn, read 2026-10-06](https://learn.microsoft.com/en-us/azure/ai-services/authentication)).

The disposable live proof script is `scripts/Test-ClaudeLiveContentSafety.ps1`. It validates inputs before any Azure CLI call, refuses the default Azure CLI profile unless `-UseCurrentAzLogin` is passed, creates run-specific resources, records T1-T11 decisions and latency when HTTP checks run, and tears down only the resource group recorded as created by that run.

## Logging

The policy traces under source `claude-content-safety`. Metadata includes mode, decision, blocked reason, severity numbers, booleans for Prompt Shields results, threshold, truncation and elapsed milliseconds. It does not store prompt text, system text, tool text, model output, image bytes or matched snippets.

```kusto
traces
| where timestamp > ago(24h)
| where customDimensions.Source == "claude-content-safety" or customDimensions.source == "claude-content-safety"
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
