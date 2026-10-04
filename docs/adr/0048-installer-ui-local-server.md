# ADR-0048: Installer UI uses a local Node server with explicit localhost controls

- **Status:** Proposed
- **Date:** 2026-10-03
- **Packet:** P93

## Context

The installer UI spike selected a local browser UI started from the repository checkout, with a
static fallback for hosts that cannot run live child processes. Microsoft Learn states that Azure
Cloud Shell Web preview can open a port and browse it in a new tab, and it documents **Manage files
> Upload** for file upload
([Cloud Shell window](https://learn.microsoft.com/en-us/azure/cloud-shell/use-the-shell-window),
fetched 2026-10-05; ms.date 2026-08-07). The same page does not state whether Web preview reaches a
loopback-bound process, which Host header it forwards, whether it adds a URL prefix or how a
`Path=/` cookie behaves. Microsoft Learn states that Cloud Shell includes Node.js
([Cloud Shell features](https://learn.microsoft.com/en-us/azure/cloud-shell/features), fetched
2026-10-05; ms.date 2025-12-03). Microsoft Learn states that Cloud Shell sessions time out after 20
minutes without interactive activity
([Cloud Shell FAQ](https://learn.microsoft.com/en-us/azure/cloud-shell/faq-troubleshooting), fetched
2026-10-05; ms.date 2026-02-09).

The implemented UI includes static mode, PowerShell live-mode detection, Azure identity and prefill
seams, preflight fingerprints, stream reattachment and stop, a single browser/server/test model file
and versioned installer-interface adapters (`tools/installer-ui/server.mjs:125-142`;
`tools/installer-ui/server.mjs:441-464`; `tools/installer-ui/ui-model.js:561-644`;
`tools/installer-ui/installer-contract.mjs:29-89`).

## Decision

The portable start command is:

```powershell
node ./tools/installer-ui/server.mjs
```

The server uses Node's built-in `http` module and no packages. It binds `127.0.0.1` by default and
prints a token URL. A non-loopback bind requires `--allow-host <host[:port]>`; refused Host requests
log the Host and `X-Forwarded-*` shape to the terminal, while the HTTP response stays generic
(`tools/installer-ui/server.mjs:388-391`; `tools/installer-ui/server.mjs:608-627`).

The bootstrap token is accepted on the initial top-level page request, then the server sets an
`HttpOnly; SameSite=Strict` cookie and redirects to a tokenless URL. `GET /api/session` returns the
CSRF token and `live` or `static` mode. JSON POST routes require `Content-Type: application/json`,
state-changing routes require `x-csrf-token`, child-spawning routes check Origin and Fetch Metadata,
the server sends no CORS header, and `OPTIONS` is refused (`tools/installer-ui/server.mjs:394-418`;
`tools/installer-ui/server.mjs:320-330`; `tools/installer-ui/http-helpers.mjs:23-53`;
`tools/installer-ui/http-helpers.mjs:79-108`).

The server exposes fixed routes. The page uses classic deferred scripts so the same
`tools/installer-ui/index.html` works from `file://` and from the server. The server serves `/` and
`/index.html` byte for byte from that file and serves only the declared script and CSS routes
(`tools/installer-ui/index.html:8-14`; `tools/installer-ui/server.mjs:420-435`;
`tests/installer-ui-structure.test.mjs:55-65`).

The run record is server-side. It stores the active or last run id, selected steps, state, current
step, failed step, resume command, exit code, start time and a bounded tail. `GET /api/run/status`
returns the run without the tail. `GET /api/run/attach?after=<seq>` streams tail and live events.
`POST /api/run/stop` kills the process tree and reports checkpoint-based resume semantics
(`tools/installer-ui/run-record.mjs:10-126`; `tools/installer-ui/server.mjs:441-445`;
`tools/installer-ui/server.mjs:543-551`).

The run transport uses per-source UTF-8 decoders, line carry, final flush, a progress-file byte
offset, serialized console line handling, a 4 MiB console-output cap, a 64 KiB console-line cap and
backpressure-aware NDJSON writes. Slow or disconnected clients do not hold back the run record or
child completion (`tools/installer-ui/run-transport.mjs:5-80`; `tools/installer-ui/server.mjs:149-167`;
`tools/installer-ui/server.mjs:173-248`; `tools/installer-ui/run-record.mjs:90-126`).

Versioned adapters validate `-ListSteps -Json`, `-Preflight -Json` and progress NDJSON before the UI
uses them. They require `schemaVersion: 1`, required fields, allowed step states, allowed preflight
results and allowed progress events. Malformed step lists and preflight results fail closed as
`502`; malformed progress events become redacted stream error events
(`tools/installer-ui/installer-contract.mjs:29-89`; `tools/installer-ui/server.mjs:190-201`;
`tools/installer-ui/server.mjs:251-269`; `tools/installer-ui/server.mjs:472-491`).

Preflight fingerprints are lower-case SHA-256 values over a canonical JSON object containing schema
version, engine, sorted answers and a sorted step scope or `full`. The server stores at most 20
passing records. A later fail or exit-code failure for the same answers and engine clears the prior
pass. A run is admitted only when the submitted fingerprint exists, the answers digest matches, the
engine is `pwsh` and the stored scope covers the requested run scope
(`tools/installer-ui/preflight-record.mjs:2-46`; `tools/installer-ui/server.mjs:472-509`).

Live mode uses the configured PowerShell command, `pwsh` by default. `listenAsync` checks PowerShell
once and requires major version 7 or newer. If that check fails, `/api/session` reports static mode
and live child-spawning routes return `503`. Static mode is also the `file://` path
(`tools/installer-ui/server.mjs:125-142`; `tools/installer-ui/server.mjs:337-343`;
`tools/installer-ui/server.mjs:584-594`).

The page and server share one model file, `tools/installer-ui/ui-model.js`. The page loads it as a
classic script, the server loads it through `node:vm`, and tests use the same file. It owns field
groups, browser validation, installer argument generation, portable command rendering, `x-checkId`
field mapping and the bash step list (`tools/installer-ui/ui-model.js:7-78`;
`tools/installer-ui/ui-model.js:439-644`; `tools/installer-ui/server-model.mjs:77-91`;
`tests/installer-ui-structure.test.mjs:9-87`).

The server never spawns `az`. Azure reads go through repository PowerShell seams, and installer work
goes through `Install-ClaudeGateway.ps1`. The direct child allowlist is PowerShell, `process.execPath`
for the test stub and `taskkill.exe` for Windows tree stop. Prefill validates the read kind and text
parameters before PowerShell starts, and the seam refuses parentheses when `az` resolves to a Windows
`.cmd` or `.bat` shim (`tools/installer-ui/server.mjs:47-82`; `tools/installer-ui/server.mjs:446-464`;
`tools/installer-ui/server.mjs:472-509`; `scripts/Get-ClaudeInstallerUiPrefill.ps1:28-32`;
`tests/installer-ui-structure.test.mjs:67-87`).

Bash remains a static command-rendering option only when the current answers and selected steps are
all applied by the bash installer. The Node server does not run the bash installer
(`tools/installer-ui/ui-model.js:561-604`; `tools/installer-ui/installer-ui.js:319-338`).

## Consequences

The UI can run without `npm install` on a workstation or Cloud Shell host that already has Node.js.
The local server remains proposed, not accepted, until the owner-attended Cloud Shell Web preview
check records loopback reachability, Host forwarding, URL prefix and cookie-path behaviour.

Static mode is a supported fallback rather than a second product path. It can validate answers, write
`answers.json` and render portable commands, but it cannot read Azure or start installer work
(`tools/installer-ui/installer-ui.js:319-338`; `tools/installer-ui/installer-ui.js:675-679`).

The run tail and fingerprint store are in-memory. Restarting the server loses them, while the
installer checkpoint remains the resume authority for a later installer run
(`tools/installer-ui/run-record.mjs:10-126`;
`docs/adr/0046-installer-checkpoint-and-resume.md#4-schema-version-1`).

PowerShell is the live engine for the Node server. Bash parity stays visible through generated
commands only when the bash installer applies the selected answers and steps
(`tools/installer-ui/ui-model.js:561-604`; `tools/installer-ui/installer-ui.js:319-338`).

The charter treats `tools/installer-ui/**` and `scripts/Get-ClaudeInstallerUi*.ps1` as
architecture-significant paths. Those files hold the local HTTP server, browser model, PowerShell
seams and Node-to-child-process boundary, so later changes to them need ADR-aware review
(`.ironclad/charter.json:30-37`).

## Process record

Implementation preceded this ADR in two slices. Commit `4871cbb` added the first local server before
commit `9553aa7` recorded the ADR and unknowns. Commit `2356d77` added milestone-two code before
commit `d77cac9` recorded its unknown updates. History is not rewritten; this record states the
exception and keeps the ADR status Proposed until the Cloud Shell live check closes the remaining
network unknowns (`docs/status/P93.md#p93-installer-ui-phase-1-2026-10-03`;
`docs/status/P93.md#lead-verification-of-group-4-2026-10-05`).
