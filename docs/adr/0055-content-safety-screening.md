# ADR-0055: Azure AI Content Safety screens Claude requests at the gateway

- **Status:** Proposed
- **Date:** 2026-10-06
- **Packet:** P102
- **Builds on:** [ADR-0054](0054-update-flow-entitlement-migration.md) (the update flow plans existing-gateway migrations before writes), [ADR-0052](0052-cosmos-default-installer.md) (the installer deploys optional gateway components and preserves live APIM values)

## Context

The owner asked on 2026-10-06 for request screening in the APIM gateway:

> Another feature parity is adding the content safety resource in the APIM for requests policy test this after the Migration path is done or parallelly whicever is possible as we need to check for the Claude apis and content safety resource

Microsoft Foundry's Claude hosting comparison says Claude models in Foundry have Anthropic safety systems active for both Azure-hosted and Anthropic-hosted deployments, but it does not expose a Claude-specific configurable Azure content filter in that model deployment table ([Microsoft Learn, read 2026-10-06][foundry-claude-hosting]). The gateway therefore needs its own Azure AI Content Safety call before forwarding a Claude Messages request.

A live spike on 2026-10-06 in the owner's test subscription measured two APIM approaches:

- APIM's built-in `llm-content-safety` policy passed benign string and content-block prompts, blocked harmful user string and user text-block prompts, blocked a jailbreak prompt and a harmful streaming request, but missed harmful `system` string, harmful `system` blocks and harmful `tool_result`; it also blocked a benign prompt longer than 10,000 characters. The statuses were T1 200, T2 200, T3 403, T4 403, T5 200, T6 200, T7 200, T8 403, T9 200, T10 403 and T11 403.
- A custom policy that called `text:shieldPrompt` and `text:analyze` with APIM's managed identity blocked T3-T8 and T10, passed T1, T2, T9 and T11, and returned 200 for a benign request through the real `claude-haiku-4-5` Foundry deployment and 403 for a harmful request before Foundry. Added latency in the custom path was 711-2,220 ms for passed requests and 672-966 ms for blocked requests.
- Provisioning the Content Safety account with kind `ContentSafety`, S0, custom subdomain and disabled local auth took 40 s. APIM Basic v2 provisioning took 108 s through ARM REST. `az apim create` did not accept `BasicV2`; ARM REST did.

The repository's current deployment shape is a monolithic gateway template and policy: `infra/main.bicep` creates APIM, the Claude API, named values, the API policy and Application Insights diagnostics (`infra/main.bicep:298-477`), and `infra/policy.xml` authenticates the caller, resolves entitlement, meters, rewrites the request to Foundry and forwards it. The installer already has optional feature switches for the projection and its sync job (`Install-ClaudeGateway.ps1:61-66`, `Install-ClaudeGateway.ps1:890-920`, `Install-ClaudeGateway.ps1:1613-1633`), and P100's update flow records a planned, fingerprinted migration before writing an existing gateway ([ADR-0054](0054-update-flow-entitlement-migration.md)).

## Options considered

### 1. Use APIM `llm-content-safety` directly

The policy is documented for LLM requests and responses, supports the four harm categories, Prompt Shields, APIM-managed-identity backends and Basic v2, and returns 403 when Content Safety detects malicious content ([Microsoft Learn, read 2026-10-06][apim-llm-content-safety]). It always uses a 10,000-character request prompt window, returns 403 if a request or response exceeds Azure AI Content Safety's character limit, and for streaming responses it can stop forwarding future events without returning 403 ([Microsoft Learn, read 2026-10-06][apim-llm-content-safety]).

Not taken as the default for P102 because the spike showed partial Anthropic Messages coverage: `system` and `tool_result` content passed when harmful, and a benign long request returned 403.

### 2. Custom APIM policy calls Azure AI Content Safety for a fixed request slice

Azure AI Content Safety `text:analyze` accepts one `text` field, categories `Hate`, `SelfHarm`, `Sexual` and `Violence`, and `outputType`; the `text` field has a 10,000 Unicode code-point maximum and `FourSeverityLevels` returns severities 0, 2, 4 and 6 ([Microsoft Learn, read 2026-10-06][analyze-text]). `text:shieldPrompt` accepts `userPrompt` and `documents`, returns `attackDetected` for each, and is intended for direct prompt attacks and indirect document attacks ([Microsoft Learn, read 2026-10-06][shield-prompt-rest]). The service limits page states Prompt Shields has a maximum prompt length of 10,000 characters and up to five documents with a total of 10,000 characters ([Microsoft Learn, read 2026-10-06][content-safety-regions]). Prompt Shields documents are for third-party content and are scanned at the user input and tool response intervention points in Foundry guardrails ([Microsoft Learn, read 2026-10-06][prompt-shields]).

Taken. The gateway can shape Claude Messages JSON before the Content Safety call, cover `system`, newest user text and newest user `tool_result`, and keep the number of calls fixed.

### 3. Screen the whole conversation up to a fixed budget

Not taken as the default. Claude Code sends the whole conversation and the newest input is at the end. Screening the beginning of the body repeats old context and can miss the newest turn.

### 4. Screen newest-first up to a fixed budget

Partly taken. The default fixed slice is narrower than "everything newest-first": it screens the system prompt plus the newest user turn only. This keeps the contract testable and makes the documented bypass explicit.

## Decision

### What text is screened

P102 will evaluate a custom APIM policy fragment named `content-safety-screening`, included from `infra/policy.xml`. The fragment runs only for `POST /v1/messages`; token counting is left unchanged.

For each request in `content-safety-mode = block` or `audit`:

1. Parse the Claude Messages body with `preserveContent: true`.
2. Find the newest message whose `role` is `user`.
3. Build the Prompt Shields request:
   - `userPrompt`: newest user text, from string content and text blocks, truncated to the newest 10,000 characters.
   - `documents`: newest user `tool_result` text, string or text blocks, grouped into up to five document strings with a total of 10,000 characters. This uses Prompt Shields documents for indirect content and tool responses, matching Microsoft's Prompt Shields description.
4. Build the harm-analysis request:
   - `text`: system prompt text plus newest user text plus newest user `tool_result` text, truncated to the newest 10,000 characters.
   - `categories`: `Hate`, `Violence`, `SelfHarm`, `Sexual`.
   - `outputType`: `FourSeverityLevels`.
5. Image-only requests use an empty text slice and pass unless Prompt Shields or analyze returns a violation for the available text.

When the newest turn exceeds the budgets, the default is to screen the newest part and log `truncated=true`, not to refuse. This preserves Claude Code's long-context workflow. The known limit is explicit: a client can fabricate harmful earlier assistant or user turns outside the screened newest user turn and those earlier turns are not screened by P102. A live fabricated-history test documents this as a limit rather than a pass.

### Failure mode and switch

The gateway gets a nonsecret APIM named value `content-safety-mode` with values:

- `block`: call Content Safety, return 403 for detected content and 503 for Content Safety errors or timeouts.
- `audit`: call Content Safety and log the decision, but never block or fail the Claude request because of Content Safety.
- `off`: skip the Content Safety calls.

The default when the feature is deployed is `block`. Deployments that do not opt into P102 keep `off` and do not create the Content Safety account. The custom policy uses APIM `send-request` with a fixed timeout; `send-request` waits only up to its timeout and can use managed identity authentication ([Microsoft Learn, read 2026-10-06][send-request]).

### Severity threshold and categories

The default threshold named value is `content-safety-threshold = 2` with `FourSeverityLevels`. With `FourSeverityLevels`, Content Safety returns 0, 2, 4 and 6 ([Microsoft Learn, read 2026-10-06][analyze-text]). A category result at or above the threshold blocks in `block` mode. Operators change the threshold by updating the named value; no policy redeploy is needed.

### Latency and cost

The custom spike added 711-2,220 ms to passed requests and 672-966 ms to blocked requests. P102 treats this as the first latency budget and requires the live test to report p50 and max for the same T1-T11 set plus Claude Code-shaped cases.

The Azure Retail Prices API query on 2026-10-06 was:

```text
https://prices.azure.com/api/retail/prices?$filter=serviceName eq 'Foundry Tools' and productName eq 'Content Safety' and skuName eq 'Standard' and meterName eq 'Standard Text Records'
```

It returned USD 0.375 per 1,000 Standard Text Records in `eastus2` and the same public-cloud price for the listed commercial regions. The first estimate assumed one text record per Content Safety text API call and one `shieldPrompt` call and one `analyze` call per screened Claude request. The [council round 2 amendment](#amendment-2026-10-07-p102-council-round-2-prompt-shields-calls-and-text-records) replaces both assumptions with the published text-record size and the conditional Prompt Shields call. The first estimate was:

```text
monthly_content_safety_usd = N requests * 2 records/request * 0.375 / 1000
                           = N * 0.00075
```

Examples: 10,000 screened requests cost USD 7.50; 100,000 cost USD 75.00; 1,000,000 cost USD 750.00, before commitment tiers, customer price sheets and taxes.

### Deployment shape

Implementation will add:

- `infra/content-safety.bicep`, creating a `Microsoft.CognitiveServices/accounts` resource with `kind: 'ContentSafety'`, SKU `S0`, `customSubDomainName`, `disableLocalAuth: true` and `publicNetworkAccess` selected by parameter. The Cognitive Services account schema documents `kind`, `sku`, `customSubDomainName`, `disableLocalAuth` and `publicNetworkAccess` ([Microsoft Learn, read 2026-10-06][cognitive-account-bicep]). Microsoft Entra authentication requires a custom subdomain and Microsoft recommends disabling local authentication when using Entra ID ([Microsoft Learn, read 2026-10-06][cognitive-auth]).
- A role assignment that grants the APIM system-assigned managed identity Cognitive Services User on the Content Safety account. APIM's `llm-content-safety` prerequisites state the same managed-identity shape, backend URL form and `https://cognitiveservices.azure.com` resource ID ([Microsoft Learn, read 2026-10-06][apim-llm-content-safety]).
- APIM named values: `content-safety-mode`, `content-safety-endpoint`, `content-safety-threshold`, `content-safety-timeout-seconds` and `content-safety-truncate-mode`.
- An APIM policy fragment resource and `<include-fragment fragment-id="content-safety-screening" />` in `infra/policy.xml`. APIM `include-fragment` inserts a previously created reusable XML policy snippet at the selected policy location ([Microsoft Learn, read 2026-10-06][include-fragment]).
- Installer support for new gateways, following the existing optional projection and sync-job switches (`Install-ClaudeGateway.ps1:61-66`, `Install-ClaudeGateway.ps1:890-920`, `Install-ClaudeGateway.ps1:1613-1633`).
- Update-flow support for existing gateways, following P100's planned migration pattern ([ADR-0054](0054-update-flow-entitlement-migration.md)).

Azure AI Content Safety direct use supports Content harms and Prompt Shields in the documented commercial regions. The implementation must check the requested deployment region against the current availability table before writing. The table lists Content harms and Prompt Shields for `eastus2`, among other regions ([Microsoft Learn, read 2026-10-06][content-safety-regions]).

### Streaming

P102 screens the request before forwarding it to Foundry. A streamed Claude response is unaffected after the request passes. Response screening is out of scope because Claude Code expects a stable Anthropic streaming shape, output moderation would require response buffering or stream interruption, and APIM's built-in streaming response behavior can stop forwarding future events without returning 403 ([Microsoft Learn, read 2026-10-06][apim-llm-content-safety]).

### Error shape

Blocked and fail-closed responses use Anthropic-style JSON:

```json
{"type":"error","error":{"type":"content_safety","message":"Content Safety blocked the request"}}
```

The message names only the control outcome: blocked by severity threshold, blocked by Prompt Shields, or Content Safety unavailable. It does not include prompt text, matched snippets, category text or system instructions.

### Logging and evidence

The policy logs with APIM `trace` using source `claude-content-safety`. The APIM trace policy can emit custom trace telemetry to Application Insights and metadata properties, and it is not affected by Application Insights sampling ([Microsoft Learn, read 2026-10-06][trace-policy]). The existing template already configures an Application Insights logger and API diagnostic (`infra/main.bicep:298-440`).

Logged metadata:

- `mode`, `decision`, `blockedBy`, `threshold`, `truncated`.
- Per-category severities as numbers, not text.
- `promptShieldUserAttackDetected` and `promptShieldDocumentAttackDetected` booleans.
- `contentSafetyStatusCode`, `contentSafetyElapsedMs` and `contentSafetyErrorClass` when present.
- No prompt, system text, tool text, model output, image bytes or matched snippet.

KQL for live evidence (a trace's `source` attribute is not stored as a custom property, so the query filters on the
message and the `screening` metadata entry, as `scripts/Test-ClaudeLiveContentSafety.ps1` does):

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

'

### Amendment, 2026-10-07: existing gateways receive the fragment through the update flow

The first live P102 run failed while ARM created the APIM policy fragment before its named values. APIM validates `{{named-value}}` references when a fragment is created, so `infra/main.bicep` now orders the Content Safety named values before `contentSafetyFragment`, and the API policy after the fragment.

Gateways installed before P102 do not have the `content-safety-screening` fragment or its named values. The update-flow policy migration treats included fragments as part of the policy: it discovers `<include-fragment fragment-id="..." />` in `infra/policy.xml`, loads `infra/<fragment-id>.xml`, creates missing named values with safe off-mode defaults, creates missing fragments, and only then writes the API policy. `content-safety-mode` defaults to `off`; `content-safety-endpoint` is a placeholder host that is not called while mode is off. The standalone `Set-GatewayPolicy.ps1` follows the same order before writing policy XML.
'

### Amendment, 2026-10-07: executable fragment tests after live-run-2 stub failure

Live run 2 of P102 deployed the fragment but every request returned 503 because the first fragment implementation was a stub: it parsed the request body, then set system, newest-user and tool-result slices to empty strings; its decision logic never read Prompt Shields or analyze severities. The offline tests had exercised a PowerShell model instead of the XML fragment and therefore did not prove the deployed artifact.

P102 now treats `infra/content-safety-screening.xml` as the tested artifact. The policy test harness executes the fragment-derived flow for slicing, request bodies, decision, trace metadata and block/audit/off outcomes, and keeps the PowerShell model only as a parity oracle. A negative test restores the empty-slice stub and must fail. This is required evidence before any later live run can claim the gateway is screening requests.

### Amendment 2026-10-07 (P102 council round 1)

The Security council found that raw mode values, malformed 2xx Content Safety responses, tail-only truncation and fragment update drift left enforceable gaps.

P102 now normalizes `content-safety-mode` once with trim and invariant lowercase. `off` skips screening and tracing, `audit` forwards after screening, and any other value enforces like `block`. The threshold named value is parsed with `int.TryParse`, clamped to 0-6, and defaults to 2 when parsing fails.

Content Safety 2xx responses are treated as malformed unless `text:analyze` returns a `categoriesAnalysis` array, Prompt Shields returns `userPromptAnalysis`, and `documentsAnalysis` has the same count as the documents sent. The council round 2 amendment limits the `userPromptAnalysis` requirement to a request that sent a non-empty `userPrompt`. Malformed responses fail closed with 503 in block mode and forward with error trace metadata in audit mode.

The screened slice now includes plain-text document blocks in the newest user message, assistant prefill after that message, tool descriptions, and plain-text document blocks inside tool results. Caller-written text is sent to Prompt Shields `userPrompt`; tool descriptions, tool results and document text are sent as Prompt Shields `documents`; all screened text is sent to harm analysis. Non-text image, PDF, URL and base64 document sources remain documented limits.

The default truncation mode samples the head and tail of each oversized item rather than the tail only. Analyze text uses a fair share of its 10,000-character budget across screened parts; the council round 2 amendment gives the newest turn the first claim on that budget. Prompt Shields documents use a fair share of the documented five-document and 10,000-character document budget, grouping sources when more than five documents are present so every source contributes text. Microsoft documents the analyze text 10,000-character request limit and `FourSeverityLevels` values in the Analyze Text REST reference, and the Prompt Shields prompt, document count and document character limits in the Azure AI Content Safety service limits page ([Analyze Text, read 2026-10-07][analyze-text]; [region availability and service limits, read 2026-10-07][content-safety-regions]).

The `content-safety-truncate-mode` named value is part of the contract. `newest` is the deployment default and means head/tail sampling. `block` means any oversized screened item or over-limit document set is `unscreenable` (narrowed to newest-turn text by the council round 2 amendment); block mode returns the existing Anthropic-style 400 response, and audit mode forwards with an `unscreenable` trace. Unknown truncation-mode values are treated as `block`.

The update flow now treats policy fragment content as part of the deployed policy. Discovery reads fragment raw XML through ARM, canonicalizes live and template XML without preserving whitespace, and plans a fragment PUT when hashes differ (the council round 2 read-back amendment replaces the raw XML read). The plan fingerprint includes the fragment hashes, so an approved plan is tied to the fragment bytes it reviewed.

### Amendment 2026-10-07 (P102 council round 2): Prompt Shields calls and text records

A live probe on 2026-10-07 (`text:shieldPrompt`, api-version `2024-09-01`) returned `documentsAnalysis` and no `userPromptAnalysis` for an empty `userPrompt` with one document, and 400 `InvalidRequestBody` for an empty `userPrompt` with no documents ([P102 status](../status/P102.md#lead-audit-fixes-and-live-runs-13-21-2026-10-07)). The fragment therefore calls Prompt Shields only when the screened slice has a non-empty `userPrompt` or at least one document, and requires `userPromptAnalysis` only when it sent a non-empty `userPrompt`. `documentsAnalysis` still needs one entry per document sent, and `text:analyze` still needs `categoriesAnalysis`.

A screened request makes no Content Safety call when its screened text is empty, one `analyze` call when it has screened text but no `userPrompt` and no document (for example a system prompt with an image-only user turn), and one `shieldPrompt` call and one `analyze` call otherwise.

The Azure pricing page defines a Standard text record as up to 1,000 characters, measured in Unicode code points, and counts a longer text input as one record for each 1,000 characters: 7,500 characters are 8 records ([Azure pricing, read 2026-10-07][content-safety-pricing]). This replaces the one-record-per-call assumption (U147). `analyze` sends at most 10,000 characters, so it uses 1-10 records. Prompt Shields sends a `userPrompt` of at most 10,000 characters and at most five documents of 10,000 characters in total. The pricing page does not say whether the prompt and each document count as separate inputs (U164); counted separately, one Prompt Shields call uses at most 24 records.

| Screened request | Records | List price per 1,000 requests |
|---|---|---|
| No screened text, so no call | 0 | USD 0 |
| `analyze` only, under 1,000 characters | 1 | USD 0.38 |
| Under 1,000 characters to each of the two calls | 2 | USD 0.75 |
| Full `analyze` budget, `userPrompt` under 1,000 characters, no documents | 11 | USD 4.13 |
| Full `analyze` and document budgets, `userPrompt` under 1,000 characters | 21-25 | USD 7.88-9.38 |
| Full `analyze`, `userPrompt` and document budgets | 30-34 | USD 11.25-12.75 |

Tool descriptions are Prompt Shields documents and part of the `analyze` text, so a request with long tool descriptions is in the third or fourth row. The trace does not record characters per call, so the share of requests in each row is not measured (U164).

### Amendment 2026-10-07 (P102 council round 2): the newest turn first

The round 2 Security seat reproduced a harmful span about 300 characters into a 650-character user turn that reached Foundry in block mode. The request had the shape of a Claude Code request, two system blocks and 18 tool descriptions, and the equal share per part (10,000 characters over 21 parts) kept only the head and tail of each part. A harmful newest user text that reaches Foundry in block mode is one of this ADR's "How we'd know this was wrong" signals, so the slicing changes:

- The newest turn (user text, prefill, documents, tool results and search results) has the first claim on the `analyze` budget and on the Prompt Shields document budget: all it needs when the system prompt and tool descriptions are short, and at least 6,000 of the 10,000 characters when they are long. The system prompt and tool descriptions share the rest. Prompt Shields `userPrompt` keeps its own 10,000 characters.
- Within each budget, parts shorter than an equal share are kept whole and the rest goes to the longer parts, so budget that short tool descriptions leave unused is not lost.
- The newest turn's sources fill up to four Prompt Shields documents (five without tools), and all tool descriptions share one document.
- `content-safety-truncate-mode = block` refuses a request only when newest-turn text would be sampled. Refusing on the system prompt and tool descriptions made every request with many tools `unscreenable`; they are sampled in both truncation modes.
- `search_result` blocks, top level or inside a `tool_result`, are third-party text and are screened like tool results. Before this amendment they were skipped.

Two limits stay and are documented in [Content Safety](../CONTENT-SAFETY.md#limits): Prompt Shields does not receive the system prompt, so attack text that is only in `system` meets harm analysis alone; and `content-safety-mode = off` writes no trace, so turning screening off leaves no screening record. An activity log alert on `Microsoft.ApiManagement/service/namedValues/write` can report the change; P102 does not deploy one.

Council round 3 Security found newest-turn text the slice did not read. The newest turn is now the run of `user` messages that ends the conversation, because the Messages API combines consecutive `user` or `assistant` turns into one ([Claude API reference, read 2026-10-07][claude-messages]), plus every `assistant` message after it. A `document` block contributes its `title` and `context`, which are passed to the model ([Claude citations, read 2026-10-07][claude-citations]), and a content-block source; a `search_result` contributes its title. Each document or search result stays one part. The system prompt and tool descriptions remain sampled in both truncation modes, so harmful text in the part of a long system prompt that sampling leaves out reaches Foundry; this is a documented limit.

### Amendment 2026-10-07 (P102 council round 2): reading the fragment back

Upgrade live run 23 stopped at the update's check: the fragment read back with `format=rawxml` did not parse as XML. Microsoft documents `rawxml` as "a non XML encoded policy document" and `xml` as "an XML document" ([Policy Fragment - Get, read 2026-10-07][policy-fragment-get]). A probe on a disposable API Management instance on 2026-10-07 wrote `infra/content-safety-screening.xml` with `format=rawxml`, as the template, migration 0002 and `Set-GatewayPolicy.ps1` do, and read it back: `rawxml` did not parse, and `xml` parsed but returned the stored text encoded once more, so `&lt;` came back as `&amp;lt;`. Discovery now reads `format=xml` and decodes the stored text once more before hashing; line endings inside values are made uniform on both sides. The probe's read-back and its template are test fixtures, and their hashes match. Upgrade runs 19 and 21 had reported no fragment change after the update because the code before this round counted a fragment it could not read as current.
## Consequences

- Content Safety is enforced at the gateway before Foundry sees blocked content in `block` mode.
- The built-in APIM policy remains a reference point, but P102 implements a custom shape because the spike found Anthropic Messages gaps.
- A screened request adds up to two Content Safety calls in `block` and `audit` modes, billed by characters: USD 0 to 12.75 per 1,000 requests at list price ([council round 2 amendment](#amendment-2026-10-07-p102-council-round-2-prompt-shields-calls-and-text-records)). The first measured added latency is 711-2,220 ms for passed requests.
- Long Claude Code conversations remain usable, but only the system prompt, tool descriptions, the newest user turn and an assistant prefill after it are screened. Fabricated earlier turns are a documented limit.
- Operators can turn the feature to `audit` or `off` by named value. Changing categories beyond the four standard categories is out of scope for P102.
- A new component and data flow enter the architecture: APIM calls Azure AI Content Safety with its managed identity before calling Foundry. The implementation stage must update the architecture diagram source under `docs/architecture/`, render it, inspect the image and update `docs/ARCHITECTURE.md`.

## How we'd know this was wrong

- A live T1-T11 run no longer matches the spike's custom-policy decisions, without a cited service change.
- A Claude Code-shaped long conversation is refused because older conversation context exceeds 10,000 characters.
- A harmful newest user text, document, search result or `tool_result` that fits the newest-turn budget reaches Foundry in `block` mode. The system prompt and tool descriptions are sampled ([council round 2 amendment](#amendment-2026-10-07-p102-council-round-2-the-newest-turn-first)).
- The KQL evidence contains prompt text or snippets.
- Cost Management shows text-record quantities outside the per-request range in the council round 2 amendment.

[analyze-text]: https://learn.microsoft.com/en-us/rest/api/contentsafety/text-operations/analyze-text?view=rest-contentsafety-2024-09-01
[apim-llm-content-safety]: https://learn.microsoft.com/en-us/azure/api-management/llm-content-safety-policy
[claude-citations]: https://platform.claude.com/docs/en/build-with-claude/citations
[claude-messages]: https://platform.claude.com/docs/claude/reference/messages_post
[cognitive-account-bicep]: https://learn.microsoft.com/en-us/azure/templates/microsoft.cognitiveservices/accounts
[cognitive-auth]: https://learn.microsoft.com/en-us/azure/ai-services/authentication
[content-safety-pricing]: https://azure.microsoft.com/en-us/pricing/details/content-safety/
[content-safety-regions]: https://learn.microsoft.com/en-us/azure/ai-services/content-safety/region-availability
[foundry-claude-hosting]: https://learn.microsoft.com/en-us/azure/foundry/foundry-models/concepts/claude-models-hosting-comparison
[include-fragment]: https://learn.microsoft.com/en-us/azure/api-management/include-fragment-policy
[policy-fragment-get]: https://learn.microsoft.com/en-us/rest/api/apimanagement/policy-fragment/get?view=rest-apimanagement-2024-05-01
[prompt-shields]: https://learn.microsoft.com/en-us/azure/ai-services/content-safety/concepts/jailbreak-detection
[send-request]: https://learn.microsoft.com/en-us/azure/api-management/send-request-policy
[shield-prompt-rest]: https://learn.microsoft.com/en-us/rest/api/contentsafety/text-operations/shield-prompt?view=rest-contentsafety-2024-09-01
[trace-policy]: https://learn.microsoft.com/en-us/azure/api-management/trace-policy

