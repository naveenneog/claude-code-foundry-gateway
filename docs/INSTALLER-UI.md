# Installer UI

The installer UI is a local form over the same answers schema, preflight result, step list and
progress stream that the installers expose. It adds no Azure service or hosted control plane
(`docs/architecture/18-installer-ui.json:1-17`; `tools/installer-ui/server.mjs:1-15`).

## Start command

The portable start command is:

```powershell
node ./tools/installer-ui/server.mjs
```

The command prints a URL of the form `http://127.0.0.1:<port>/?token=<token>`. The token is random
and at least 32 bytes before encoding, and the default bind address is `127.0.0.1`
(`tools/installer-ui/server.mjs:277-279`; `tools/installer-ui/server.mjs:608-627`). A non-loopback
bind requires `--allow-host <host[:port]>` and prints a risk line (`tools/installer-ui/server.mjs:608-627`).
The first top-level page request consumes the URL token and sets an `HttpOnly; SameSite=Strict`
cookie; `GET /api/session` returns the CSRF token and `live` or `static` mode
(`tools/installer-ui/server.mjs:394-415`; `tools/installer-ui/http-helpers.mjs:13-29`).

Live mode requires PowerShell 7 or newer from the configured `pwsh` command. If the command is absent
or reports an older major version, the server stays in static mode, `/api/session` reports the reason
and live child-spawning routes return `503` (`tools/installer-ui/server.mjs:125-142`;
`tools/installer-ui/server.mjs:337-343`; `tools/installer-ui/server.mjs:584-594`).

Microsoft Learn states that Azure Cloud Shell's Web preview menu can open a port and browse it in a
new tab, and the same article describes **Manage files > Upload** for file uploads
([Cloud Shell window](https://learn.microsoft.com/en-us/azure/cloud-shell/use-the-shell-window),
fetched 2026-10-05; ms.date 2026-08-07). It does not state whether Web preview reaches a process
bound to loopback, which Host header it forwards, whether it adds a URL prefix or how a cookie with
`Path=/` behaves. Those facts remain unverified until the owner-attended Web preview check (U100,
U101). The server has `--allow-host <host[:port]>` for that check, and refused Host requests log the
Host and `X-Forwarded-*` shape to the terminal only (`tools/installer-ui/server.mjs:388-391`;
`tools/installer-ui/server.mjs:608-627`). Microsoft Learn states that Cloud Shell sessions time out
after 20 minutes without interactive activity
([Cloud Shell FAQ](https://learn.microsoft.com/en-us/azure/cloud-shell/faq-troubleshooting), fetched
2026-10-05; ms.date 2026-02-09); whether a Web preview tab counts as activity is unverified (U102).

## Static fallback

`tools/installer-ui/index.html` opens from disk. It carries a copy of
`schemas/claude-gateway.answers.schema.json` in `#schema-json` and uses classic deferred scripts so
Chromium can run it from `file://` (`tools/installer-ui/index.html:8-14`). The static schema copy is
compared with the canonical schema in a browser-oriented test (`tests/installer-ui.test.mjs:214-222`).
The local server serves the same `index.html` bytes for `/` and `/index.html`, so static and live
mode share one page source (`tools/installer-ui/server.mjs:420-421`;
`tests/installer-ui-structure.test.mjs:55-65`).

Static mode validates answers, writes `answers.json` and shows generated command blocks. Bash command
blocks appear only when every current answer has an `x-appliedBy` entry for
`install-claude-gateway.sh` and every selected step is one of the bash installer's `CKPT_ORDER` steps;
the model owns that list and a test keeps it equal to `scripts/install-checkpoint.sh`
(`tools/installer-ui/ui-model.js:561-604`; `tests/installer-ui-g2.test.mjs:344-352`). Static mode
does not read Azure and does not start the installer. The page hides live action and prefill controls
in static mode (`tools/installer-ui/installer-ui.js:675-679`). The Cloud Shell handoff displayed by
the page is download, **Manage files > Upload**, then the generated command
(`tools/installer-ui/installer-ui.js:319-338`).

The browser validator uses the same answer names, schema subset and cross-field rules as the
PowerShell validator for `Install-ClaudeGateway.ps1`; the P92 corpus parity test compares check ids
and paths (`tools/installer-ui/ui-model.js:439-544`; `tests/installer-ui-g3.test.mjs:271-284`). It
marks invalid fields and withholds download, preflight, run and command text while a problem remains
(`tools/installer-ui/installer-ui.js:263-318`; `tools/installer-ui/installer-ui.js:654-659`).
Action buttons show a busy label while a request is in flight, restore their controls afterward and
place failures next to the action as an alert with a recovery sentence
(`tools/installer-ui/installer-ui-actions.js:33-83`). When a focused busy button is disabled, the page
moves keyboard focus to the action status line and then back to the button; during a run one Tab
reaches Stop run (`tools/installer-ui/installer-ui-actions.js:42-83`;
`docs/status/P93.md:1604-1611`). The page has no keyboard shortcuts of its own
(`docs/status/P93.md:1604-1611`).

## Security model

The server uses Node's built-in `http` module and no npm package (`tools/installer-ui/server.mjs:1`).
It serves fixed routes only, refuses `OPTIONS`, sends no CORS header and sends a Content-Security-Policy
without inline script (`tools/installer-ui/server.mjs:393-435`; `tools/installer-ui/http-helpers.mjs:31-53`).
The Host allowlist accepts loopback names for the selected port and any explicit `--allow-host` value
(`tools/installer-ui/http-helpers.mjs:60-73`; `tools/installer-ui/server.mjs:608-627`).

The bootstrap cookie and `x-csrf-token` header protect JSON `POST` routes. JSON POST routes require
`Content-Type: application/json`; child-spawning POST routes also check Origin and Fetch Metadata,
and child-spawning GET routes refuse cross-site Fetch Metadata (`tools/installer-ui/server.mjs:415-418`;
`tools/installer-ui/server.mjs:320-330`; `tools/installer-ui/http-helpers.mjs:79-96`). Prefill accepts
only the three known read kinds and text parameters before starting PowerShell
(`tools/installer-ui/server-model.mjs:9-16`; `tools/installer-ui/server-model.mjs:62-75`;
`tools/installer-ui/server.mjs:446-464`). When Azure CLI resolves to a Windows `.cmd` or `.bat` shim,
the prefill seam refuses parentheses in the Foundry resource group before any `az` call
(`scripts/Get-ClaudeInstallerUiPrefill.ps1:28-32`).

Node never spawns `az`. Azure identity and prefill reads go through
`scripts/Get-ClaudeInstallerUiIdentity.ps1` and `scripts/Get-ClaudeInstallerUiPrefill.ps1`; installer
work goes through `Install-ClaudeGateway.ps1` with argument arrays and `shell: false`
(`tools/installer-ui/server.mjs:47-82`; `tools/installer-ui/server.mjs:446-464`;
`tools/installer-ui/server.mjs:472-491`; `tests/installer-ui-structure.test.mjs:67-87`). Output from
children is redacted with the installer's rule table and local paths are scrubbed before HTTP details
or stream events leave the server (`tools/installer-ui/server-model.mjs:17-48`;
`tools/installer-ui/server.mjs:149-167`; `tools/installer-ui/server.mjs:481-487`).

The UI does not collect the PFX password because the schema marks `AddressCertificatePassword` as a
secret and the page renders non-secret installer answers only
(`schemas/claude-gateway.answers.schema.json:31-35`; `tools/installer-ui/ui-model.js:94-104`;
`tools/installer-ui/ui-model.js:170-177`). With `-Yes -NonInteractive` and
`AddressCertificateSource = Pfx`, `Install-ClaudeGateway.ps1` does not prompt and passes no
certificate password unless it is supplied on the command line
(`Install-ClaudeGateway.ps1:1164-1166`; `Install-ClaudeGateway.ps1:1178-1179`).

## Run lifecycle and limits

Preflight produces a canonical SHA-256 fingerprint over schema version, engine, answers and requested
step scope. A run starts only when that fingerprint matches a stored passing preflight for the same
answers and a covering scope; failing preflight or an exit-code failure clears the stored pass
(`tools/installer-ui/preflight-record.mjs:2-46`; `tools/installer-ui/server.mjs:472-509`).

One installer run can be active. A second run receives `409`, and `POST /api/run` is not a route, so
it returns `404` through the fixed-route fallback (`tools/installer-ui/server.mjs:493-500`;
`tools/installer-ui/server.mjs:552`). A run writes its answers and progress file to a per-run
temporary directory and removes that directory after the child exits (`tools/installer-ui/server.mjs:359-368`;
`tools/installer-ui/server.mjs:526-534`). A disconnected browser does not kill the child. `GET
/api/run/status` reports the active or last run without the tail, and `GET /api/run/attach?after=<seq>`
streams prior and live events from the bounded tail (`tools/installer-ui/server.mjs:441-445`;
`tools/installer-ui/run-record.mjs:10-126`).

The run tail keeps the latest 8 MiB or 50,000 events, and each client reads at its own pace. A stream
whose position leaves the tail receives one notice with the number of events it missed
(`tools/installer-ui/run-record.mjs:5-8`; `tools/installer-ui/run-record.mjs:78-126`). Console and
progress lines are redacted before they leave the server (`tools/installer-ui/server.mjs:149-167`;
`tools/installer-ui/server.mjs:190-201`). Console output above 4 MiB per run is replaced by one
notice, a console line above 64 KiB is truncated with ` [line truncated]`, and the browser keeps
2,000 visible output lines with one line naming the number removed (`tools/installer-ui/server.mjs:31-33`;
`tools/installer-ui/server.mjs:156-167`; `tools/installer-ui/run-transport.mjs:28-64`;
`tools/installer-ui/installer-ui.js:474-483`).

The run output is a labelled log region (`tools/installer-ui/index.html:32`). The Stop run button is
enabled only while a run is active, confirms the running step name and then stops the process tree
(`tools/installer-ui/installer-ui.js:301-311`; `tools/installer-ui/installer-ui.js:646-652`). Windows
uses `taskkill.exe /PID <pid> /T /F`; POSIX children run in a detached process group so the group can
be signalled (`tools/installer-ui/server.mjs:56-66`; `tools/installer-ui/server.mjs:71-82`). The stop
response and stream say that the install checkpoint resumes when the same steps run again
(`tools/installer-ui/server.mjs:543-551`).

Read-only child routes use per-route timeouts: step list 60 seconds, identity 120 seconds, prefill
120 seconds and preflight 600 seconds, with the test override `readOnlyTimeoutMs`
(`tools/installer-ui/server.mjs:293`). Idle shutdown is armed only when no tracked read-only job or
run is active (`tools/installer-ui/server.mjs:286-318`).

## Sections

| Section | Source and behaviour |
|---|---|
| Account | Shows user, tenant id, subscription name and subscription id from the Azure CLI account through repository PowerShell. A button shows `az login --use-device-code` when sign-in is needed (`scripts/Get-ClaudeInstallerUiIdentity.ps1:1-29`; `tools/installer-ui/installer-ui.js:544-551`; `tools/installer-ui/installer-ui.js:584-586`). |
| First install | Renders the subscription, Foundry account, gateway resource group, region, publisher, tier, initial groups, quotas and model deployment fields that `Install-ClaudeGateway.ps1` applies. Select fields start as `not set (the installer default)`. Server mode can read subscriptions, Foundry accounts and deployment names through `POST /api/prefill`; static mode hides those read actions (`tools/installer-ui/ui-model.js:7-32`; `tools/installer-ui/installer-ui.js:102-116`; `tools/installer-ui/installer-ui-prefill.js:15-24`; `tools/installer-ui/installer-ui.js:675-679`). |
| Optional parts | Renders company-address, existing-APIM reuse, Desktop sign-in, projection toggle, entitlement-store and business-unit answers that `Install-ClaudeGateway.ps1` applies. Fields with declarative conditions are hidden until their condition holds and hidden fields are not written to `answers.json`. The PFX password is not an answer, and the installer prompt behaviour is the one stated above (`tools/installer-ui/ui-model.js:33-58`; `tools/installer-ui/ui-model.js:140-189`; `tools/installer-ui/installer-ui.js:220-246`; `Install-ClaudeGateway.ps1:1164-1179`). |
| Advanced | Renders projection renewal, resolver app, organisation quota, developer estimate, revocation window, model-organisation metadata, team-budget behaviour, unassigned-developer behaviour and the optional pending Claude deployment object that `Install-ClaudeGateway.ps1` applies (`tools/installer-ui/ui-model.js:59-78`; `tools/installer-ui/installer-ui.js:171-189`). |
| Business units | Provides a two-level editor: add a unit, add a team under a unit, remove either, then serialize units before teams. Add unit and Add team focus the new row's first field. Remove focuses the row that takes the removed row's place, else the previous row, else Add unit. Fields are id, Entra group, monthly USD budget, mode and percent only for `Allowance`. Ids are lower-case letters, digits and hyphens, max 64; ids are unique; group names exclude `'`, `,` and `:`; `Allowance` requires percent 1-100; teams name one parent unit. The JSON view round-trips through the same validation (`tools/installer-ui/installer-ui-business-units.js:7-29`; `tools/installer-ui/installer-ui-business-units.js:65-158`; `tools/installer-ui/ui-model.js:214-233`; `tools/installer-ui/ui-model.js:504-542`). |
| Review | Runs installer preflight and shows check, result, message, remedy and field links when a problem names or maps to an answer path. A passing preflight returns a 64-character SHA-256 fingerprint over canonical answers, engine and step scope. Failing checks mark fields through a problem path when present, otherwise through the schema's `x-checkId` mapping. Non-JSON preflight output returns a visible error with the exit code and a short redacted, path-scrubbed output tail (`tools/installer-ui/installer-ui.js:386-405`; `tools/installer-ui/installer-ui-problems.js:39-58`; `tools/installer-ui/preflight-record.mjs:28-46`; `tools/installer-ui/server.mjs:472-491`). |
| Run | Lists installer step ids, streams selected-step output as it arrives, shows a failed step with a rerun action and resume command, reattaches to an active run after reload and keeps a full run as a separate confirmed action. A run starts only when its fingerprint matches a stored passing preflight for the same answers and a covering scope. Displayed commands use `./` relative paths (`tools/installer-ui/installer-ui.js:414-468`; `tools/installer-ui/installer-ui.js:486-538`; `tools/installer-ui/installer-ui.js:613-652`; `tools/installer-ui/ui-model.js:593-618`). |

## Installer interface checks

The server validates the P92 step list, preflight result and progress event interfaces before using
them. Each must use `schemaVersion: 1`, required fields and accepted vocabularies; malformed step
lists and preflight results return `502`, and malformed progress events become stream error events
(`tools/installer-ui/installer-contract.mjs:1-89`; `tools/installer-ui/server.mjs:251-269`;
`tools/installer-ui/server.mjs:472-491`; `tools/installer-ui/server.mjs:190-201`).

## Screenshots

![Installer UI overview](guide/installer-ui-overview.png)

![Installer UI preflight table](guide/installer-ui-preflight.png)

![Installer UI failed step and resume command](guide/installer-ui-run.png)
