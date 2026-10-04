# Installer UI

The installer UI is a local form over the answers schema, preflight result, step list and progress
stream exposed by the installers. It adds no Azure service or hosted control plane
(`docs/architecture/18-installer-ui.json:1-17`; `tools/installer-ui/server.mjs:1-16`).

## Start command

The portable start command is:

```powershell
node ./tools/installer-ui/server.mjs
```

The server prints an HTTP URL with a random bootstrap token and binds to `127.0.0.1` by default
(`tools/installer-ui/server.mjs:620-659`). The browser receives a tokenless cookie session after the
first top-level request, and `GET /api/session` returns the CSRF token and `live` or `static` mode
(`tools/installer-ui/server.mjs:328-366`; `tools/installer-ui/http-helpers.mjs:21-58`).

Live mode requires PowerShell 7 or newer from the configured `pwsh` command. If the command is absent
or reports an older major version, the server stays in static mode, `/api/session` reports the reason
and live child-spawning routes return `503` (`tools/installer-ui/server.mjs:151-168`,
`tools/installer-ui/server.mjs:363-410`). Opening `tools/installer-ui/index.html` from `file://` uses
the same static-mode page source (`tools/installer-ui/index.html:1-15`; `tools/installer-ui/server.mjs:392-394`).

Microsoft Learn states that Azure Cloud Shell's Web preview menu can open a port and browse it in a
new tab, and the same article describes **Manage files > Upload** for file uploads
([Cloud Shell window](https://learn.microsoft.com/en-us/azure/cloud-shell/use-the-shell-window),
fetched 2026-10-05; ms.date 2026-08-07). It does not state whether Web preview reaches a process
bound to loopback, which Host header it forwards, whether it adds a URL prefix or how a cookie with
`Path=/` behaves. Those facts remain unverified until the owner-attended Web preview check (U90, U91).
The server has `--allow-host <host[:port]>` for that check, and refused Host requests log the Host and
`X-Forwarded-*` shape to the terminal only (`tools/installer-ui/server.mjs:630-642`,
`tools/installer-ui/server.mjs:345-354`). Microsoft Learn states that Cloud Shell sessions time out
after 20 minutes without interactive activity
([Cloud Shell FAQ](https://learn.microsoft.com/en-us/azure/cloud-shell/faq-troubleshooting), fetched
2026-10-05; ms.date 2026-02-09); whether a Web preview tab counts as activity is unverified (U92).

## Static fallback

Static mode validates the same schema subset and cross-field rules as the page uses in live mode,
writes `answers.json`, and shows one PowerShell command. Bash command blocks appear only when the
current answers and selected steps are all handled by the bash installer
(`tools/installer-ui/ui-model.js:94-115`; `tools/installer-ui/installer-ui.js:106-139`). Static mode
does not read Azure and does not start the installer (`tools/installer-ui/installer-ui.js:320-356`).
The Cloud Shell handoff displayed by the page is download, **Manage files > Upload**, then the
generated command (`tools/installer-ui/installer-ui.js:320-343`).

## Security model

The server uses Node's built-in `http` module and no npm package (`tools/installer-ui/server.mjs:1`).
It serves fixed routes only, refuses `OPTIONS`, sends no CORS header and sends a Content-Security-Policy
without inline script (`tools/installer-ui/server.mjs:389-476`; `tools/installer-ui/http-helpers.mjs:17-20`).
The Host allowlist accepts loopback names for the selected port and any explicit `--allow-host` value
(`tools/installer-ui/http-helpers.mjs:99-119`; `tools/installer-ui/server.mjs:630-642`).

The bootstrap token is accepted once on the top-level page request, then the session cookie and
`x-csrf-token` header protect JSON `POST` routes (`tools/installer-ui/server.mjs:328-366`,
`tools/installer-ui/http-helpers.mjs:21-58`). JSON POST routes require `Content-Type:
application/json`; child-spawning POST routes also check Origin and Fetch Metadata, and child-spawning
GET routes refuse cross-site Fetch Metadata (`tools/installer-ui/server.mjs:369-388`,
`tools/installer-ui/http-helpers.mjs:68-97`). Prefill accepts only the three known read kinds and text
parameters before starting PowerShell (`tools/installer-ui/server.mjs:24-76`). When Azure CLI resolves
to a Windows `.cmd` or `.bat` shim, the prefill seam refuses parentheses in the Foundry resource group
before any `az` call (`scripts/Get-ClaudeInstallerUiPrefill.ps1:28-32`).

Node never spawns `az`. Azure identity and prefill reads go through
`scripts/Get-ClaudeInstallerUiIdentity.ps1` and `scripts/Get-ClaudeInstallerUiPrefill.ps1`, and installer
work goes through `Install-ClaudeGateway.ps1` with argument arrays and `shell: false`
(`tools/installer-ui/server.mjs:71-88`, `tools/installer-ui/server.mjs:116-123`,
`tools/installer-ui/server.mjs:493-526`). Output from children is redacted and local paths are scrubbed
before it reaches HTTP responses (`tools/installer-ui/server-model.mjs:11-25`,
`tools/installer-ui/server.mjs:86-147`). The UI does not collect the PFX password because the schema
marks `AddressCertificatePassword` as a secret and answers-file consumers refuse secrets
(`schemas/claude-gateway.answers.schema.json:31-35`; `docs/status/P93.md#lead-verification-of-260fd0e-2026-10-04`).

## Run lifecycle and limits

Preflight produces a canonical SHA-256 fingerprint over schema version, engine, answers digest and
requested step scope. A run starts only when that fingerprint matches a stored passing preflight for
the same answers and a covering scope; failing preflight or an exit-code failure clears the stored pass
(`tools/installer-ui/preflight-record.mjs:1-61`; `tools/installer-ui/server.mjs:486-526`).

One installer run can be active. A disconnected browser does not kill the child. `GET
/api/run/status` reports the active or last run without the tail, and `GET /api/run/attach?after=<seq>`
streams prior and live events from the bounded tail (`tools/installer-ui/run-record.mjs:1-149`;
`tools/installer-ui/server.mjs:553-570`). `POST /api/run/stop` stops the process tree and reports that
the checkpoint resumes when the same steps run again (`tools/installer-ui/server.mjs:574-589`). Windows
uses `taskkill.exe /PID <pid> /T /F`; POSIX children run in a detached process group so the group can
be signalled (`tools/installer-ui/server.mjs:56-66`, `tools/installer-ui/server.mjs:71-82`).

The run tail keeps the latest 8 MiB or 50,000 events, and each client reads at its own pace
(`tools/installer-ui/run-record.mjs:7-13`, `tools/installer-ui/run-record.mjs:90-149`). Console output
above 4 MiB per run is replaced by one notice, a console line above 64 KiB is truncated with
` [line truncated]`, and the browser keeps 2,000 visible output lines
(`tools/installer-ui/server.mjs:34-35`, `tools/installer-ui/server.mjs:173-220`,
`tools/installer-ui/installer-ui.js:360-402`). Read-only child routes use per-route timeouts: step list
60 seconds, identity 120 seconds, prefill 120 seconds, preflight 600 seconds, with the test override
`readOnlyTimeoutMs` (`tools/installer-ui/server.mjs:271-284`). Idle shutdown is armed only when no
tracked read-only job or run is active (`tools/installer-ui/server.mjs:286-326`).

## Sections

| Section | Source and behaviour |
|---|---|
| Account | Shows user, tenant id, subscription name and subscription id from the Azure CLI account through repository PowerShell (`scripts/Get-ClaudeInstallerUiIdentity.ps1:1-45`; `tools/installer-ui/installer-ui.js:453-456`). |
| First install | Renders subscription, Foundry account, resource group, region, publisher, tier, initial groups, quotas and model deployment answers applied by `Install-ClaudeGateway.ps1` (`tools/installer-ui/ui-model.js:7-32`; `tools/installer-ui/installer-ui.js:97-171`). |
| Optional parts | Renders company-address, existing-APIM reuse, Desktop sign-in, projection, entitlement-store and business-unit answers. Conditional fields stay hidden until their conditions hold, and hidden fields are omitted from answers (`tools/installer-ui/ui-model.js:32-58`; `tools/installer-ui/ui-model.js:136-283`). |
| Advanced | Renders projection renewal, resolver app, organisation quota, developer estimate, revocation window, model-organisation metadata, team-budget behaviour, unassigned-developer behaviour and pending deployment answers (`tools/installer-ui/ui-model.js:59-78`; `tools/installer-ui/installer-ui.js:171-189`). |
| Business units | Provides a two-level editor. Add unit and Add team focus the new row's first field. Remove focuses the row that takes the removed row's place, else the previous row, else Add unit (`tools/installer-ui/installer-ui-business-units.js:52-120`). |
| Review | Runs installer preflight and shows check, result, message, remedy and field links. A problem path is used first; when no path exists, the schema's `x-checkId` mapping is used. Unpathed schema and cross-field rows do not link to current browser validation errors (`tools/installer-ui/installer-ui-problems.js:1-96`). |
| Run | Lists installer step ids, streams selected-step output, records a failed step with rerun and resume command, reattaches after reload and keeps full run behind a separate confirmation (`tools/installer-ui/installer-ui.js:274-360`; `tools/installer-ui/installer-ui.js:539-690`). |

## Installer interface checks

The server validates the P92 step list, preflight result and progress event interfaces before using
them. Each must use `schemaVersion: 1`, required fields and accepted vocabularies; malformed step
lists and preflight results return `502`, and malformed progress events become stream error events
(`tools/installer-ui/installer-contract.mjs:1-97`; `tools/installer-ui/server.mjs:250-270`,
`tools/installer-ui/server.mjs:493-510`, `tools/installer-ui/server.mjs:199-211`).

## Screenshots

![Installer UI overview](guide/installer-ui-overview.png)

![Installer UI preflight table](guide/installer-ui-preflight.png)

![Installer UI failed step and resume command](guide/installer-ui-run.png)
