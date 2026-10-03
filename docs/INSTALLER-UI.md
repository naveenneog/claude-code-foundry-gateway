# Installer UI

The installer UI is a local form over the same answers schema, preflight, step list and progress
stream that the installers expose. It is an operator-side tool; it does not add an Azure service.

## Start command

```powershell
node .\tools\installer-ui\server.mjs
```

The command prints a URL of the form `http://127.0.0.1:<port>/?token=<token>`. The token is random,
at least 32 bytes before encoding, and is required on every request. The default bind address is
`127.0.0.1`. A different bind address is explicit and prints a risk line. Cloud Shell Web preview
loopback reachability is unverified (U90).

In Azure Cloud Shell, start the command from the checkout, then use **Web preview > Open and browse**
for the printed port. Microsoft Learn documents Web preview port opening and browsing
(`use-the-shell-window`, ms.date 2026-08-07). Cloud Shell sessions time out after 20 minutes without
interactive activity (`faq-troubleshooting`, ms.date 2026-02-09), so the UI states that fact before
long waits.

## Static fallback

`tools/installer-ui/index.html` opens from disk. It carries the same schema as
`schemas/claude-gateway.answers.schema.json`; `tests/installer-ui.test.mjs` compares the two copies.
Static mode validates formats, creates `answers.json` and shows the PowerShell and bash commands.
It does not read Azure and does not run the installer. The Cloud Shell path is **Manage files >
Upload** for `answers.json`, then one pasted command.

## Security model

The server uses Node's built-in `http` module and no npm packages. It sends no CORS headers, refuses
`OPTIONS`, serves fixed routes only and sends a Content-Security-Policy without inline script. The
Host allowlist accepts loopback names with the selected port. The Cloud Shell preview Host header and
cookie path behaviour are unverified (U91).

Node does not spawn `az`. Azure reads go through repository PowerShell scripts:
`scripts/Get-ClaudeInstallerUiIdentity.ps1`, `scripts/Get-ClaudeInstallerUiPrefill.ps1` and
`scripts/Get-ClaudeInstallerUiPlan.ps1`. Installer calls use `pwsh -NoProfile -NonInteractive` with
argument arrays. One installer run is active at a time. A second receives `409`.

Each run writes its answers and progress file to a per-run temporary directory and removes that
directory after the request. Every console line and progress line is redacted with the installer
redaction rules before it leaves the server.

## Sections

| Section | Source and behaviour |
|---|---|
| Account | Shows user, tenant id, subscription name and subscription id from the Azure CLI account through repository PowerShell. A button shows `az login --use-device-code` when sign-in is needed. |
| Foundation | Renders subscription, Foundry, region, SKU and name fields from the schema. Select fields start as `not set (the installer default)`. |
| Access | Renders groups, tier limits and model deployment fields from the schema. |
| Optional parts | Renders company address, Desktop sign-in, projection and monitoring answers from the schema. Projection answers are schema answers only; no projection switch is exposed. |
| Business units | Accepts the schema's business-unit tree. Ids are lower-case letters, digits and hyphens, max 64; ids are unique; group names exclude `'`, `,` and `:`; `Allowance` requires percent 1-100; teams name one parent unit. |
| Review | Runs installer preflight and shows check, result, message and remedy. Failing checks mark fields through `x-checkId`. The plan route calls `Start-ClaudeGateway.ps1 -Action Setup -PlanOnly -AnswersPath`. |
| Run | Lists installer step ids, streams selected-step output as it arrives, shows a failed step with a rerun action and resume command, and keeps a full run as a separate confirmed action. |

## Screenshots

![Installer UI overview](guide/installer-ui-overview.png)

![Installer UI preflight table](guide/installer-ui-preflight.png)

![Installer UI failed step and resume command](guide/installer-ui-run.png)
