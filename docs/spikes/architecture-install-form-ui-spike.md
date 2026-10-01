---
title: "Form-based installer: every answer first, selected steps, launched from Azure Cloud Shell"
category: "Architecture & Design"
status: "🟡 In Progress"
priority: "High"
timebox: "1 day of research, 2026-10-01"
created: 2026-10-01
updated: 2026-10-01
owner: "naveenneog"
tags: ["technical-spike", "architecture", "research", "installer", "cloud-shell"]
---

# Form-based installer: every answer first, selected steps, launched from Azure Cloud Shell

## Summary

**Spike objective.** Choose the install experience that collects every prerequisite value and selection in one form, validates the whole set before any write, runs the selected steps, and re-runs one failed step. Azure Cloud Shell is the preferred launch point (owner, 2026-10-01).

**Why this matters.** In the 2026-10-01 customer session, `Install-ClaudeGateway.ps1` asked its questions one at a time and stopped at each error. Each stop needed a new run through the same questions. Field errors this week included a Graph 404 right after group creation, a reused APIM without a managed identity, and an upper-case business-unit id refused at `Install-ClaudeGateway.ps1:1652`.

**Timebox.** One day of research on 2026-10-01. No implementation.

**Decision deadline.** Before the first implementation packet for the form starts.

## Research questions

**Primary question.** Which architecture collects all inputs up front, validates them before any change, runs selected steps and re-runs a failed step, and can be launched from Azure Cloud Shell?

**Secondary questions:**

- What contract connects a form to the PowerShell and bash installers (answers file, step ids, preflight)?
- Can the form read Azure to prefill and check values (subscriptions, Foundry accounts and deployments, existing APIM, Entra groups)?
- How is a two-level hierarchy of business units and teams entered and checked?
- Which hosting options exist, and what consent, identity and security review does each need?
- What works inside Cloud Shell, and which Cloud Shell limits affect a long install?

## Investigation plan

### Research tasks

- [x] Inventory the installer inputs, the guided-flow answer contract and the existing terminal UI (this repository).
- [x] Azure portal-native forms: createUiDefinition, template-spec form view, Graph Bicep extension, deploymentScripts.
- [x] Local web UI: server choices, localhost threats and controls, `az` as a child process, output streaming.
- [x] Cloud Shell: launch, Web preview, terminal UI libraries, file hand-off, limits, prior art.
- [x] Hosted options: static form, browser single-page app with delegated tokens, hosted backend, hosted form with a local agent.
- [ ] Live check of Cloud Shell Web preview access, port handling and idle timeout (needs an owner-attended Cloud Shell session).
- [ ] Owner decision on the recommendation.

### Success criteria

**This spike is complete when:**

- [x] Each option has documented capabilities, limits, consent and identity needs, with sources.
- [x] A comparison and a recommendation exist.
- [ ] The owner has chosen an option, and the follow-up packets are filed.

## Technical context

**Related components (this repository, main at `0fed315`):**

| Component | Fact | Source |
|---|---|---|
| `Install-ClaudeGateway.ps1` | 50 parameters and about 37 interactive prompts. These prompts have no parameter: revocation window, team budget behaviour, developers with no team, developer estimate, business-unit id and group | `Install-ClaudeGateway.ps1:31-118`, `:708`, `:997`, `:1021`, `:1039`, `:1647`, `:1657` |
| `-Yes` unattended run | Refuses when a required value is missing, before its summary | `docs/SETUP.md:620-632` |
| `install-claude-gateway.sh` | 15 flag-backed answers | `install-claude-gateway.sh:310-324` |
| Guided flow | `-AnswersPath` JSON keyed by question, `-PlanOnly` prints every installer input and the exact installer arguments with a SHA-256 fingerprint, `-ApprovedPlanFingerprint` applies unattended, and `-Change address\|foundation\|models\|sku` re-runs one part | `docs/GUIDED-FLOW.md:126-200`, `Start-ClaudeGateway.ps1:6-17` |
| Flow questions | 17 keys declared in code with `Type`, `Options` and `When` conditions. A `When` condition is a PowerShell scriptblock, so it cannot be read as data | `scripts/flow/Address.ps1`, `Foundation.ps1` and other flow modules |
| Installer checkpoint (P91, not merged) | Stable step ids, a resume after the last verified step, live checks before a skip | `docs/adr/0046-installer-checkpoint-and-resume.md` on branch `p91-installer-checkpoint` |
| Business units | Ids use lower-case letters, digits and hyphens. The hierarchy is two levels (unit and team). Group names cannot contain a comma or a colon. A menu console already wraps the commands | `scripts/Set-ClaudeBusinessUnit.ps1`, `scripts/ClaudeBusinessUnit.ps1:255-285`, `docs/adr/0008-*`, `scripts/Manage-ClaudeBusinessUnits.ps1` |
| AUM terminal UI | Python Textual, with a Cloud Shell launcher that installs Python 3.12 under `$HOME`; no live Cloud Shell run is claimed | `cli/finops/pyproject.toml`, `docs/AUM.md:75-140`, `docs/adr/0041-*` |

**Dependencies.** The installer checkpoint (P91) supplies the step ids and the resume. The Azure CLI guide (P89/P90) supplies per-part commands.

**Constraints:**

- No secrets in an answers file. The PFX password is passed as a parameter, never as an answer (`scripts/flow/Address.ps1`).
- Customer security reviews.
- The Cloud Shell idle timeout.
- No new tenant-wide consent unless the owner chooses it.

## Research findings

### Option A. Static form that produces an answers file and a command

A single HTML file, opened from disk or hosted as a static page. It has no access to Azure. It validates formats in the browser (GUID shape, lower-case ids, two-level hierarchy, required fields), then offers `answers.json` for download, plus the exact command for PowerShell and for bash.

- **Hand-off into Cloud Shell.** Cloud Shell **Manage files > Upload** puts a file in `/home/<user>`, and the editor opens it with `code <file>` ([use the shell window](https://learn.microsoft.com/azure/cloud-shell/use-the-shell-window), ms.date 2026-08-07).
- **Limits.** The page cannot list subscriptions or Foundry accounts, cannot check permissions, and cannot run anything.
- **Effort.** Lowest. No identity, consent or hosting requirement when opened from disk.

### Option B. Local web UI started by the operator, inside Cloud Shell or on a workstation

A small web server started from the repository checkout. It serves the form, runs `az` with the session's existing sign-in to fill dropdowns and check prerequisites, runs selected installer steps as child processes, streams their output, and re-runs a failed step.

- **Cloud Shell launch.**
  - The **Web preview** menu opens a port on the Cloud Shell container. **Open and browse** shows it in a new browser tab ([use the shell window](https://learn.microsoft.com/azure/cloud-shell/use-the-shell-window), ms.date 2026-08-07).
  - Learn does not state the port range, the preview URL format, or who else can reach a previewed port.
  - Azure/CloudShell GitHub issues #368, #343 and #481 report proxy 404s, content-type rewriting and sign-in loops.
- **Server.**
  - Node.js is preinstalled in Cloud Shell ([features](https://learn.microsoft.com/azure/cloud-shell/features)), and Node's built-in `http` module needs no package and no administrator rights on loopback.
  - The .NET documentation marks `HttpListener` "not recommended for new development" ([HttpListener](https://learn.microsoft.com/dotnet/api/system.net.httplistener)).
  - Python's `http.server` documentation says it is not recommended for production.
- **Threats and controls.**
  - A web page in the same browser can send requests to `127.0.0.1` (cross-site request forgery) or rebind its own host name to `127.0.0.1` ([WICG Private Network Access](https://github.com/WICG/private-network-access/blob/main/explainer.md), [OWASP CSRF cheat sheet](https://cheatsheetseries.owasp.org/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.html)).
  - Jupyter Server binds to `127.0.0.1`, prints a one-time token in the URL and requires it on every request ([Jupyter Server security](https://jupyter-server.readthedocs.io/en/latest/operators/security.html)).
- **`az` from the server.**
  - `az login` opens the default browser. `--use-device-code` is the documented fallback without a display ([sign in interactively](https://learn.microsoft.com/cli/azure/authenticate-azure-cli-interactively)).
  - Concurrent `az` processes can conflict on the token cache (Azure/azure-cli #23642), so calls run one at a time.
- **Streaming and re-runs.** Server-sent events carry one-way logs ([MDN](https://developer.mozilla.org/docs/Web/API/Server-sent_events/Using_server-sent_events)). A re-run is another invocation with selected step ids.
- **Effort.** Medium. No identity or consent beyond the operator's own `az` sign-in.

### Option C. Terminal wizard inside Cloud Shell

A full-screen or menu wizard in the Cloud Shell terminal.

- `dialog`, `whiptail` and `newt` are absent from the Cloud Shell image, and the account has no `sudo` (Azure/CloudShell `linux/base.Dockerfile`; [FAQ](https://learn.microsoft.com/azure/cloud-shell/faq-troubleshooting), ms.date 2026-02-09).
- PowerShell 7.4, Python 3, Node.js and git are preinstalled ([features](https://learn.microsoft.com/azure/cloud-shell/features)). `Out-ConsoleGridView` (`Microsoft.PowerShell.ConsoleGuiTools`) and Python Textual install under `$HOME`. Without mounted storage they are reinstalled in each session.
- **Prior art.** The Azure Landing Zones accelerator runs `Install-Module -Name ALZ` and then the interactive `Deploy-Accelerator` in Cloud Shell ([ALZ-PowerShell-Module](https://github.com/Azure/ALZ-PowerShell-Module)).
- This repository's AUM terminal UI already uses Textual, through a Cloud Shell launcher (`docs/AUM.md:75-140`).
- **Effort.** Medium. A wizard gives prompts and lists, not a browser form with checkboxes.

### Option D. Azure portal form for a template deployment

A template spec with a form view (`uiFormDefinition.json`), or "Deploy to Azure" with `createUiDefinition.json` ([template spec forms](https://learn.microsoft.com/azure/azure-resource-manager/templates/template-specs-create-portal-forms), ms.date 2026-05-29; [form view elements](https://learn.microsoft.com/azure/azure-resource-manager/templates/form-view-elements), ms.date 2026-06-08).

- **What fits:**
  - text boxes, checkboxes, drop-downs, editable grids and resource selectors;
  - `ArmApiControl` runs GET or POST against Azure Resource Manager only ([ArmApiControl](https://learn.microsoft.com/azure/azure-resource-manager/managed-applications/microsoft-solutions-armapicontrol)), so the form can list Foundry accounts and check names.
- **What does not fit:**
  - **Graph.** No form element calls Microsoft Graph.
  - **Entra groups.** The Graph Bicep extension (GA 2025-07-29) creates security groups with the deploying user's delegated rights ([permissions](https://learn.microsoft.com/graph/templates/bicep/concept-permissions-and-privileges), ms.date 2025-07-28).
  - **Membership sync into APIM named values.** This needs `deploymentScripts` with a user-assigned identity holding Graph application permissions, plus a storage account and a container instance ([deployment scripts](https://learn.microsoft.com/azure/azure-resource-manager/templates/deployment-script-template), ms.date 2026-08-18).
  - **The handover JSON** has no place in a template deployment.
  - **The hierarchy.** An editable grid is flat, so units and teams need a parent column.
- **Re-runs.** The portal cannot re-run one failed module, and roll-back uses complete mode ([rollback on error](https://learn.microsoft.com/azure/azure-resource-manager/templates/rollback-on-error), ms.date 2026-06-26).
- **Cloud Shell.** No form element opens Cloud Shell with a command.
- **Effort.** High for full parity. It fits the Azure-resource steps only.

### Option E. Hosted single-page app with the operator's delegated tokens

A static page that signs the operator in with MSAL.js and calls Azure Resource Manager and Microsoft Graph from the browser.

- **Registration.** A "Single-page application" redirect type with authorization code and PKCE ([SPA configuration](https://learn.microsoft.com/entra/identity-platform/scenario-spa-app-configuration), ms.date 2025-05-12).
- **CORS.**
  - Microsoft Graph supports browser calls ([SPA migration guide](https://learn.microsoft.com/entra/identity-platform/migrate-spa-implicit-to-auth-code)).
  - An unauthenticated preflight to `management.azure.com` on 2026-10-01 returned `Access-Control-Allow-Origin: *`. No Learn page states that support.
- **Permissions.**
  - Creating groups needs delegated Graph `Group.ReadWrite.All`, and reading membership needs `GroupMember.Read.All`. Both require admin consent ([Graph permissions reference](https://learn.microsoft.com/graph/permissions-reference), ms.date 2026-09-14).
  - Either each customer registers its own single-tenant app, or a vendor multi-tenant app is consented through the [admin-consent endpoint](https://learn.microsoft.com/entra/identity-platform/v2-admin-consent).
- **Effort.** The installer logic (Bicep deployment, role assignment, named values, membership sync, business units) is written again in JavaScript. The installers and the page would then have two code paths that can drift.

### Option F. Hosted web app with a backend

App Service, Container Apps or Functions performs the install.

- **On-behalf-of (OBO) flow.** The app acts with the signed-in user's rights ([OBO flow](https://learn.microsoft.com/entra/identity-platform/v2-oauth2-on-behalf-of-flow), ms.date 2025-01-04). Easy Auth has no built-in OBO exchange, so MSAL code is still needed ([App Service authentication](https://learn.microsoft.com/azure/app-service/overview-authentication-authorization)).
- **Managed identity.**
  - The app's identity needs Owner, or Contributor plus User Access Administrator ([built-in roles](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles), ms.date 2026-09-10).
  - It also needs Graph application `Group.ReadWrite.All`, which is tenant-wide and requires admin consent ([permissions overview](https://learn.microsoft.com/graph/permissions-overview), ms.date 2025-12-26).
  - Just-in-time elevation is Microsoft's documented control for such standing grants ([PIM](https://learn.microsoft.com/entra/id-governance/privileged-identity-management/pim-configure)).
- **Effort.** The highest effort and the highest security-review burden, plus a hosting cost.

### Option G. Hosted form that drives an agent on the operator's machine

A hosted page sends requests to `http://localhost`, where a local agent runs `az`.

- Chrome enforces Local Network Access, a permission prompt, by default since Chrome 142 (2025-10-28) ([Chrome blog](https://developer.chrome.com/blog/local-network-access)).
- Firefox is implementing a similar model. Safari's behaviour is unverified.
- The experience depends on browser version and enterprise browser policy.

### Cloud Shell facts that apply to every option

| Fact | Source |
|---|---|
| Entry points are portal.azure.com and shell.azure.com. No documented way exists to pass a command, script URL or file into a session at launch | [overview](https://learn.microsoft.com/azure/cloud-shell/overview), ms.date 2026-08-07 |
| Sessions end after 20 minutes without interactive activity, and long non-interactive work ends without warning | [FAQ](https://learn.microsoft.com/azure/cloud-shell/faq-troubleshooting), ms.date 2026-02-09 |
| Without storage (ephemeral), files are deleted when the session ends. With storage, `clouddrive` persists and `$HOME` is kept as an image in the file share | [features](https://learn.microsoft.com/azure/cloud-shell/features); [persisting storage](https://learn.microsoft.com/azure/cloud-shell/persisting-shell-storage) |
| The tenant limit is 20 concurrent users | [FAQ](https://learn.microsoft.com/azure/cloud-shell/faq-troubleshooting) |
| Cloud Shell in a virtual network reaches private resources and needs an Azure Relay | [VNet overview](https://learn.microsoft.com/azure/cloud-shell/vnet/overview), ms.date 2024-10-23 |
| No single admin switch disables Cloud Shell. Blocking `*.console.azure.com` or denying Cloud Shell storage by policy limits it | [FAQ](https://learn.microsoft.com/azure/cloud-shell/faq-troubleshooting); [persisting storage](https://learn.microsoft.com/azure/cloud-shell/persisting-shell-storage) |

### Comparison

| Option | Collect all first | Reads Azure to prefill and check | Runs steps and re-runs one | Cloud Shell launch | New identity or consent | Effort |
|---|---|---|---|---|---|---|
| A. Static form | yes | no | no; produces the command | file upload and a pasted command | none | low |
| B. Local web UI | yes | yes, with the operator's `az` | yes | `node …` then Web preview | none | medium |
| C. Terminal wizard | yes | yes | yes | native | none | medium |
| D. Portal form | yes | Azure Resource Manager only | Azure-resource steps only, with no single-module re-run | no | a script identity with Graph application permissions | high |
| E. Hosted SPA | yes | yes, with delegated tokens | yes, after the logic is rewritten in JavaScript | no | an app registration, with admin consent for Graph `Group.ReadWrite.All` | high |
| F. Hosted backend | yes | yes | yes, after the logic is rewritten | no | OBO, or a standing Owner-level identity plus Graph application permissions | highest |
| G. Hosted form + local agent | yes | yes, through the agent | yes | no | none, but a browser Local Network Access prompt | medium; depends on the browser |

### Prototype and testing notes

There is no prototype in this spike. The Microsoft Learn pages cited above were fetched on 2026-10-01, and the repository facts were read at `0fed315`.

## Decision

### Recommendation (proposed, awaiting the owner's decision)

**Option B, launched in Azure Cloud Shell, on top of one shared answers contract, with Option A as the fallback that always works.** It is built in three phases.

**Phase 0. The answers contract.** Every user interface needs it, and on its own it removes the one-error-per-run pattern.

1. **One answers schema for every installer input.**
   - It is generated from the installer parameters and the guided-flow question declarations.
   - `When` conditions become data instead of scriptblocks.
   - The prompt-only answers gain parameters: revocation window, team budget behaviour, developers with no team, developer estimate, and business units with their teams.
2. **One preflight that checks the whole answers file before any write**, and reports every problem in a single list. It extends the guided flow's `-PlanOnly`, which already prints every installer input, the exact installer arguments and the API Management price (`docs/GUIDED-FLOW.md:126-140`). Checks:
   - tenant and subscription;
   - operator roles (`Test-ClaudePrerequisites -Mode Admin`);
   - the Foundry account and its deployments;
   - the API Management name, or an existing instance's identity;
   - Entra group names;
   - business-unit ids and depth.
3. **Step selection on both installers**, with `-Steps <ids>` using the installer-checkpoint step ids, and resume from the checkpoint (P91).

**Phase 1. A local web UI (Option B).**

- **Launch.** It starts in Cloud Shell from the repository checkout with Node's built-in `http` module (no packages), then opens through **Web preview > Open and browse**. The same command starts it on a workstation.
- **Form sections:**
  - prerequisites, with live checks through the session's `az`;
  - foundation: subscription, Foundry account and deployments, region, SKU, names;
  - access: groups, tiers, limits, models;
  - optional parts: company address, Desktop sign-in, projection, monitoring;
  - a two-level tree of business units and teams;
  - a review: the preflight report and the plan fingerprint;
  - a run panel: selected steps with live output, and a re-run of a failed step.
- **The installers do the work.** The UI runs the existing installers and scripts, and re-implements none of them. `Manage-ClaudeBusinessUnits.ps1` already follows this rule (`scripts/Manage-ClaudeBusinessUnits.ps1:1-20`).
- **Portable output.** The UI always offers `answers.json` and the exact PowerShell and bash commands, so the same plan runs without the UI on Windows, macOS, Linux or Cloud Shell.
- **Static fallback.** The same page opens from disk without a server (Option A). It validates formats and produces `answers.json` and the commands. The file goes to Cloud Shell through **Manage files > Upload**, followed by one pasted command. This mode covers a tenant where Web preview is blocked or fails.

**Phase 2 (optional). A PowerShell terminal wizard (Option C)** that reads the same schema, for operators who prefer the terminal. This is the Azure Landing Zones accelerator pattern.

**Not recommended now:**

- **D (portal form) for the whole install.** No form element reaches Microsoft Graph, membership sync needs a script identity with Graph application permissions, the handover file has no place in a template deployment, and the portal cannot re-run one failed module.
- **E (hosted SPA).** Tenant-wide admin consent for Graph `Group.ReadWrite.All`, and the installer logic written a second time in JavaScript.
- **F (hosted backend).** A standing high-privilege identity, the highest review burden, and the logic written a second time.
- **G (hosted form plus local agent).** Chrome's Local Network Access prompt since Chrome 142, unverified Safari behaviour, and browser-policy dependence.

### Rationale

- **Cloud Shell first.** Option B runs inside Cloud Shell with the session's existing sign-in, and Web preview is documented as of 2026-08-07.
- **No new identity, app registration or consent.** Options B, A and C act only with the operator's own `az` sign-in, so a customer security review covers no new tenant-wide permission.
- **One code path.** The UI runs the same installers that are tested today, so the UI and the scripts cannot drift.
- **Errors surface before changes.** The Phase 0 preflight reports every invalid or missing value at once. That removes the one-question, one-error loop seen in the 2026-10-01 session.
- **Re-runs are a step selection.** The installer-checkpoint step ids and the live checks before a skip make "re-run step X" a scoped invocation.

### Implementation notes

- **Web preview access isolation is not documented.** The server still binds to loopback, requires a one-time token printed in the terminal (entered on the first page, then held in an `HttpOnly`, `SameSite=Strict` cookie), checks the Host header, sends no CORS headers, and shuts down when idle.
- **Unverified: Web preview's connection path.** Whether Web preview reaches a process bound to `127.0.0.1` or needs another bind address is not documented. The live Cloud Shell check settles it before Phase 1.
- **The idle timeout.** Activity in the Web preview tab may not count as interactive Cloud Shell activity (unverified). The UI shows the 20-minute fact before long waits. The installer checkpoint and the ARM deployment continue after a session ends.
- **Ephemeral sessions** lose the checkout. The UI's `answers.json` download keeps the plan.
- **`az` calls run one at a time** (Azure/azure-cli #23642).
- **Secrets stay out of `answers.json`.** A PFX password is requested at run time, or replaced by a Key Vault certificate reference.
- **Business-unit tree checks** match `Set-ClaudeBusinessUnit.ps1`: ids `^[a-z0-9-]+$`, unique ids, at most two levels (ADR-0008), group names without a comma or a colon, positive budgets, and `Allowance` mode with a percentage from 1 to 100. The tree produces the unit commands first and the team commands (`-Parent`) second.
- **Optional later:** Option D can be offered for the Azure-resource steps only, as a "Deploy to Azure" path for the gateway infrastructure.

### Follow-up actions

- [ ] Owner decision on the recommendation.
- [ ] A live, owner-attended Cloud Shell check: Web preview bind address, access isolation, port range, and whether preview-tab activity resets the idle timeout.
- [ ] Merge the installer checkpoint (P91), which supplies step ids and resume.
- [ ] Packet: answers schema, preflight and `-Steps` (Phase 0).
- [ ] Packet: local web UI with the static fallback (Phase 1).
- [ ] Optional packet: PowerShell terminal wizard (Phase 2).
- [ ] Architecture documents updated when a packet adds the UI.

## Status history

| Date | Status | Notes |
|---|---|---|
| 2026-10-01 | 🔴 Not Started | Spike created and scoped from the customer session |
| 2026-10-01 | 🟡 In Progress | Repository inventory and four research threads complete; recommendation proposed; owner decision and live Cloud Shell check pending |
