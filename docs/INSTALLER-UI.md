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
Before listening, the server checks the configured PowerShell command, `pwsh` by default, and live
mode requires PowerShell 7 or newer. Without it, `/api/session` reports static mode, live routes
return `503` and the page shows the same static fallback path as `file://`.

In Azure Cloud Shell, start the command from the checkout, then use **Web preview > Open and browse**
for the printed port. Microsoft Learn documents Web preview port opening and browsing
(`use-the-shell-window`, ms.date 2026-08-07). Cloud Shell sessions time out after 20 minutes without
interactive activity (`faq-troubleshooting`, ms.date 2026-02-09), so the UI states that fact before
long waits.

## Static fallback

`tools/installer-ui/index.html` opens from disk. It uses a classic deferred script so Chromium can run
it from `file://`, and it carries the same schema as `schemas/claude-gateway.answers.schema.json`;
`tests/installer-ui.test.mjs` compares the two copies and opens the file page in a real browser.
The local server serves the same `index.html` bytes for `/` and `/index.html`, so static and live
mode share one page source.
Static mode validates formats, creates `answers.json` and shows readable PowerShell command blocks.
Bash command blocks appear only when the current answers and selected steps are all handled by the
bash installer: each answer's schema `x-appliedBy` names `install-claude-gateway.sh`, and each step is
one of the bash installer's steps, `CKPT_ORDER` in `scripts/install-checkpoint.sh`, which
`tools/installer-ui/ui-model.js` lists and a test keeps equal. It does not read Azure and does not run
the installer. The Cloud Shell path is **Manage files > Upload** for `answers.json`, then one pasted
command.
The browser validator uses the same answer names, schema subset and cross-field rules as the
PowerShell validator for `Install-ClaudeGateway.ps1`. It marks invalid fields and withholds download,
preflight, run and command text while a problem remains. Action buttons show a busy label while a
request is in flight, restore their controls afterward and place failures next to the action as an
alert with a recovery sentence.

## Security model

The server uses Node's built-in `http` module and no npm packages. It sends no CORS headers, refuses
`OPTIONS`, serves fixed routes only and sends a Content-Security-Policy without inline script. The
Host allowlist accepts loopback names with the selected port. The Cloud Shell preview Host header and
cookie path behaviour are unverified (U91).

Node does not spawn `az`. Azure reads go through repository PowerShell scripts:
`scripts/Get-ClaudeInstallerUiIdentity.ps1` and `scripts/Get-ClaudeInstallerUiPrefill.ps1`.
Installer calls use `pwsh -NoProfile -NonInteractive` with
argument arrays. One installer run is active at a time. A second receives `409`. The streaming run endpoint is the
only run endpoint; `POST /api/run` returns `404`.

Each run writes its answers and progress file to a per-run temporary directory and keeps that
directory until the child exits, even if the browser disconnects. The server records the active or
last run, exposes `GET /api/run/status`, and reattaches through `GET /api/run/attach?after=<seq>`
from a bounded event tail: the latest 8 MiB or 50,000 events of the run
(`tools/installer-ui/run-record.mjs`). Each browser stream reads the tail at its own pace, so a paused
or disconnected browser does not hold back the installer or the end of the run; a stream whose
position leaves the tail receives one notice with the number of events it missed. Every console line
and progress line is redacted with the installer redaction rules before it leaves the server. Console
output above 4 MiB for a run is replaced by one notice while progress and the final summary continue,
and a console line longer than 64 KiB is cut with ` [line truncated]`. The browser keeps 2,000 output
lines and shows one line with the number of earlier lines removed.

The run output is exposed as a labelled log region. The Stop run button is enabled only while a run is active. It confirms the running step name and
then stops the process tree. On Windows the server uses `taskkill.exe /PID <pid> /T /F`; on POSIX
installer runs start in their own process group so the group can be signalled. The stop response and
stream say that the install checkpoint resumes when the same steps run again.

## Sections

| Section | Source and behaviour |
|---|---|
| Account | Shows user, tenant id, subscription name and subscription id from the Azure CLI account through repository PowerShell. A button shows `az login --use-device-code` when sign-in is needed. |
| First install | Renders the subscription, Foundry account, gateway resource group, region, publisher, tier, initial groups, quotas and model deployment fields that `Install-ClaudeGateway.ps1` applies. Select fields start as `not set (the installer default)`. Server mode can read subscriptions, Foundry accounts and deployment names through `POST /api/prefill`; static mode hides those read actions. |
| Optional parts | Renders company-address, existing-APIM reuse, Desktop sign-in, projection toggle, entitlement-store and business-unit answers that `Install-ClaudeGateway.ps1` applies. Fields with declarative conditions are hidden until their condition holds and hidden fields are not written to `answers.json`. The PFX password is not an answer; with `-Yes -NonInteractive` and `AddressCertificateSource = Pfx`, `Install-ClaudeGateway.ps1` does not prompt and passes no certificate password unless it is supplied on the command line (`Install-ClaudeGateway.ps1:1164-1166`, `:1179`). |
| Advanced | Renders projection renewal, resolver app, organisation quota, developer estimate, revocation window, model-organisation metadata, team-budget behaviour, unassigned-developer behaviour and the optional pending Claude deployment object that `Install-ClaudeGateway.ps1` applies. |
| Business units | Provides a two-level editor: add a unit, add a team under a unit, remove either, then serialize units before teams. Fields are id, Entra group, monthly USD budget, mode and percent only for `Allowance`. Ids are lower-case letters, digits and hyphens, max 64; ids are unique; group names exclude `'`, `,` and `:`; `Allowance` requires percent 1-100; teams name one parent unit. The JSON view round-trips through the same validation. |
| Review | Runs installer preflight and shows check, result, message, remedy and field links when a problem names or maps to an answer path. A passing preflight returns a 64-character SHA-256 fingerprint over canonical answers, engine and step scope. Failing checks mark fields through `x-checkId`. Non-JSON preflight output returns a visible error with the exit code and a short redacted, path-scrubbed output tail. |
| Run | Lists installer step ids, streams selected-step output as it arrives, shows a failed step with a rerun action and resume command, reattaches to an active run after reload and keeps a full run as a separate confirmed action. A run starts only when its fingerprint matches a stored passing preflight for the same answers and a covering scope. Displayed commands use `./` relative paths; a 2026-10-04 PowerShell 7 run accepted `-File ./Install-ClaudeGateway.ps1 -AnswersPath ./scratch-p93-e2/answers.json -Preflight -Json` and returned versioned JSON with exit 1 because the isolated profile was signed out. |

## Installer interface checks

The server validates the versioned P92 interfaces before rendering or using them:
`-ListSteps -Json`, `-Preflight -Json` and progress NDJSON events must have `schemaVersion: 1` and
the required fields documented by the installer contract. Incompatible step lists and preflight
results return `502` with the interface name. Incompatible progress events become stream error
events and do not change the failed-step rerun state.

## Screenshots

![Installer UI overview](guide/installer-ui-overview.png)

![Installer UI preflight table](guide/installer-ui-preflight.png)

![Installer UI failed step and resume command](guide/installer-ui-run.png)
