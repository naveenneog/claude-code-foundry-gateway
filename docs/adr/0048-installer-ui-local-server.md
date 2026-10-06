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
and versioned installer-interface adapters (`tools/installer-ui/server.mjs:106-127`; `tools/installer-ui/server.mjs:249-255`;
`tools/installer-ui/server.mjs:352-356`; `tools/installer-ui/server.mjs:371-424`; `tools/installer-ui/server.mjs:357-370`;
`tools/installer-ui/server.mjs:524-537`; `tools/installer-ui/server-model.mjs:77-83`; `tools/installer-ui/installer-contract.mjs:31-116`).

## Decision

The portable start command is:

```powershell
node ./tools/installer-ui/server.mjs
```

The server uses Node's built-in `http` module and no packages. It binds `127.0.0.1` by default and
prints a token URL. A non-loopback bind requires `--allow-host <host[:port]>`; refused Host requests
log the Host and `X-Forwarded-*` shape to the terminal, while the HTTP response stays generic
(`tools/installer-ui/server.mjs:1-19`; `tools/installer-ui/server.mjs:301-302`; `tools/installer-ui/server.mjs:589-594`;
`tools/installer-ui/server.mjs:604-608`).

The bootstrap token is accepted on the initial top-level page request, then the server sets an
`HttpOnly; SameSite=Strict` cookie to a new session secret and redirects to a tokenless URL. The
bootstrap URL token is never accepted as the session cookie (`tools/installer-ui/session-auth.mjs:4-13`;
`tools/installer-ui/server.mjs:309-325`). `GET /api/session` returns the
CSRF token and `live` or `static` mode. JSON POST routes require `Content-Type: application/json`,
state-changing routes require `x-csrf-token`, child-spawning routes check Origin and Fetch Metadata,
the server sends no CORS header, and `OPTIONS` is refused (`tools/installer-ui/server.mjs:304`; `tools/installer-ui/server.mjs:330-334`;
`tools/installer-ui/server.mjs:239-247`; `tools/installer-ui/http-helpers.mjs:36-59`;
`tools/installer-ui/http-helpers.mjs:80-96`).

The server exposes fixed routes. The page uses classic deferred scripts so the same
`tools/installer-ui/index.html` works from `file://` and from the server. The server serves `/` and
`/index.html` byte for byte from that file and serves only the declared script and CSS routes,
including the split renderer page script (`tools/installer-ui/index.html:8-16`;
`tools/installer-ui/server.mjs:336-345`; `tests/installer-ui-structure.test.mjs:9-13`; `tests/installer-ui-structure.test.mjs:54-61`;
`tools/installer-ui/installer-ui-render.js:7-108`).

The run record is server-side. It stores the active or last run id, selected steps, state, current
step, failed step, resume command, exit code, start time and a bounded tail. `GET /api/run/status`
returns the run without the tail. `GET /api/run/attach?after=<seq>&run=<id>` streams tail and live
events only for that run id and returns `409` with `reason: run-replaced` when the active or last
record has another id. Run and attach streams carry `x-installer-run-id` when the response is
attached. `POST /api/run/stop` kills the followed process tree and reports checkpoint-based resume semantics
(`tools/installer-ui/run-record.mjs:10-41`; `tools/installer-ui/run-record.mjs:78-129`; `tools/installer-ui/server.mjs:357-370`;
`tools/installer-ui/server.mjs:532-536`).
A stop for a run that is already stopping returns the message of the first stop, without a second
stopped event and without stopping the process tree again (`tools/installer-ui/server.mjs:544-545`).
Run requests also carry a browser-generated client request id. The server records a small admission
history for that id before reading the body, then marks it `started` with the run id or `refused`
with the response reason; `GET /api/run/status?request=<id>` includes that record. The page uses it
to wait through admission, attach only the admitted run, and report when a later run replaced the
admitted run record
(`tools/installer-ui/run-admission.mjs:1-30`; `tools/installer-ui/server.mjs:428-434`; `tools/installer-ui/server.mjs:464-475`;
`tools/installer-ui/server.mjs:357-361`; `tools/installer-ui/installer-ui-run.js:242-295`).

The run transport uses per-source UTF-8 decoders, line carry, final flush, a progress-file byte
offset, serialized console line handling, a 4 MiB console-output cap, a 64 KiB console-line cap and
backpressure-aware NDJSON writes. Slow or disconnected clients do not hold back the run record or
child completion (`tools/installer-ui/run-transport.mjs:5-91`; `tools/installer-ui/installer-stream.mjs:6-7`;
`tools/installer-ui/installer-stream.mjs:9-98`; `tools/installer-ui/run-record.mjs:52-76`; `tools/installer-ui/run-record.mjs:78-129`).
Authenticated requests count as in flight before their JSON body is read, so idle shutdown cannot
close the server while a run request is still being admitted
(`tools/installer-ui/server.mjs:325-328`; `tools/installer-ui/server.mjs:550-552`).

Versioned adapters validate `-ListSteps -Json`, `-Preflight -Json` and progress NDJSON before the UI
uses them. They require `schemaVersion: 1`, required fields, allowed step states, allowed preflight
results and allowed progress events. Malformed step lists and preflight results fail closed as
`502`; malformed progress events become redacted stream error events
(`tools/installer-ui/installer-contract.mjs:12-17`; `tools/installer-ui/installer-contract.mjs:31-116`;
`tools/installer-ui/server.mjs:129-133`; `tools/installer-ui/installer-stream.mjs:61-68`; `tools/installer-ui/server.mjs:401-409`;
`tools/installer-ui/server.mjs:545-549`).
The preflight adapter requires the schema's full preflight-check set exactly once and rejects a
top-level result that does not match the producer blocking rule. The progress adapter accepts an
empty `stepId` only for whole-run `failed` and `refused` events
(`tools/installer-ui/installer-contract.mjs:57-104`; `tools/installer-ui/installer-contract.mjs:106-116`;
`tools/installer-ui/server.mjs:399-401`).

Preflight fingerprints are lower-case SHA-256 values over a canonical JSON object containing schema
version, engine, sorted answers, a sorted step scope or `full`, and the Azure identity snapshot read
after a PASS. The server stores at most 20 passing records. A passing record also stores the
signed-in state, user, tenant and subscription snapshot. A preflight attempt clears the prior pass
for the same answers and engine as soon as the server has read the request, before step validation,
the Azure lease or any child, and becomes the latest attempt for those answers. Only the latest
attempt stores a pass: an earlier attempt that passes after a later one began answers without a
fingerprint and with `superseded: true`, which the page shows as a stale preflight. A failure at any
stage (step list, Azure CLI busy, malformed output, timeout or identity read) therefore leaves no
stored pass. A
run is admitted only when the submitted fingerprint exists, the answers digest matches, the engine is
`pwsh`, the stored scope covers the requested run scope and the current identity snapshot matches
the passing preflight (`tools/installer-ui/preflight-record.mjs:3-37`; `tools/installer-ui/preflight-record.mjs:46-82`;
`tools/installer-ui/server.mjs:155`; `tools/installer-ui/server.mjs:388-423`; `tools/installer-ui/server.mjs:450-463`;
`tools/installer-ui/installer-ui.js:462-481`).

One Azure CLI lease covers identity, prefill, preflight and run work. Reads wait behind reads in
arrival order, wait time counts against the read timeout, runs are refused while a read holds the
lease, and reads or second runs are refused while a run holds it. Server shutdown closes the lease
first, refusing queued and later Azure work with `installer-ui-stopping`, and child spawning also
refuses after cleanup starts (`tools/installer-ui/azure-lease.mjs:6-11`; `tools/installer-ui/azure-lease.mjs:44-45`; `tools/installer-ui/azure-lease.mjs:78-88`;
`tools/installer-ui/server.mjs:74-80`; `tools/installer-ui/server.mjs:170-177`;
`tools/installer-ui/server.mjs:205-211`; `tools/installer-ui/server.mjs:435`; `tools/installer-ui/server.mjs:450`).
Shutdown writes those refusals before it closes the remaining connections, waiting at most 1 s for
them (`tools/installer-ui/server.mjs:181-189`).

The server refuses a live run with `AddressMode = custom` and `AddressCertificateSource = Pfx`
before creating a run because the page does not collect the PFX password and the installer asks for
that password only when it runs without `-Yes` (`tools/installer-ui/server.mjs:442-447`;
`Install-ClaudeGateway.ps1:1164-1166`).

The page mirrors the same decision: PFX custom-address answers disable browser run buttons and render
the PowerShell run command without `-Yes`, while omitted custom-address certificate and DNS modes use
the installer defaults for visibility and validation only (`tools/installer-ui/installer-ui.js:329-336`;
`tools/installer-ui/installer-ui.js:418-456`; `tools/installer-ui/ui-model.js:155-161`; `tools/installer-ui/ui-model.js:172-181`;
`tools/installer-ui/ui-model.js:520-527`; `tools/installer-ui/ui-model.js:585-605`; `tools/installer-ui/ui-model.js:614-651`).

Live mode uses the configured PowerShell command, `pwsh` by default. `listenAsync` checks PowerShell
once and requires major version 7 or newer. If that check fails, `/api/session` reports static mode
and live child-spawning routes return `503`. The browser also has a `file://` static path
(`tools/installer-ui/server.mjs:106-127`; `tools/installer-ui/server.mjs:560-562`; `tools/installer-ui/server.mjs:249-255`;
`tools/installer-ui/server.mjs:330`; `tools/installer-ui/installer-ui.js:564-569`).

The page and server share one model file, `tools/installer-ui/ui-model.js`. The page loads it as a
classic script, the server loads it through `node:vm`, and tests use the same file. It owns field
groups, browser validation, installer argument generation, portable command rendering and the bash
step list (`tools/installer-ui/ui-model.js:6-77`; `tools/installer-ui/ui-model.js:451-651`;
`tools/installer-ui/server-model.mjs:77-91`; `tests/installer-ui-structure.test.mjs:30-31`). It also owns `x-checkId` field mapping
(`tools/installer-ui/ui-model.js:200-216`;
`tests/installer-ui-structure.test.mjs:25-45`).

The server never spawns `az`. Azure reads go through repository PowerShell seams, and installer work
goes through `Install-ClaudeGateway.ps1`. The direct child allowlist is PowerShell, `process.execPath`
for the test stub and `taskkill.exe` for Windows tree stop. Prefill validates the read kind and text
parameters before PowerShell starts (`tools/installer-ui/server.mjs:51-56`; `tools/installer-ui/server.mjs:58-68`;
`tools/installer-ui/server.mjs:74-93`; `tools/installer-ui/server.mjs:101-108`; `tools/installer-ui/server.mjs:371-376`;
`tools/installer-ui/server-model.mjs:62-75`; `tests/installer-ui-structure.test.mjs:69-96`). The prefill seam refuses parentheses when `az` resolves to a Windows
`.cmd` or `.bat` shim (`scripts/Get-ClaudeInstallerUiPrefill.ps1:28-32`;
`tests/installer-ui.test.mjs:380-385`).

Bash remains a static command-rendering option only when the current answers and selected steps are
all applied by the bash installer. The Node server does not run the bash installer
(`tools/installer-ui/ui-model.js:582-583`; `tools/installer-ui/ui-model.js:614-651`; `tools/installer-ui/installer-ui-render.js:7-50`;
`tools/installer-ui/server.mjs:51-56`).

## Consequences

The UI can run without `npm install` on a workstation or Cloud Shell host that already has Node.js.
The local server remains proposed, not accepted, until the owner-attended Cloud Shell Web preview
check records loopback reachability, Host forwarding, URL prefix and cookie-path behaviour.

Static mode is a supported fallback rather than a second product path. It can validate answers, write
`answers.json` and render portable commands, but it cannot read Azure or start installer work
(`tools/installer-ui/installer-ui.js:257-276`; `tools/installer-ui/installer-ui.js:654-662`; `tools/installer-ui/installer-ui-render.js:14-25`;
`tools/installer-ui/installer-ui.js:677-678`).

The bootstrap URL authenticates only the first page load. After that load, API access depends on the
separate session cookie secret and the CSRF token, so copying the original URL token into a cookie
does not authenticate later requests (`tools/installer-ui/session-auth.mjs:4-13`;
`tools/installer-ui/server.mjs:309-334`).

Azure reads are serialized with other Azure CLI work. A read waits behind another read and can time
out while waiting; a read sent during a run is refused immediately with `azure-busy`, and a run sent
during a read is refused with the read operation named (`tools/installer-ui/azure-lease.mjs:1-89`;
`tools/installer-ui/server.mjs:205-209`; `tools/installer-ui/server.mjs:450`).

A passing preflight reads identity once after the installer preflight passes, and run admission reads
identity once again before creating the run. Those reads add one PowerShell/`az account show` path to each passing preflight and admitted run. A changed tenant, user or
subscription requires a new preflight (`scripts/Get-ClaudeInstallerUiIdentity.ps1:8-20`;
`tools/installer-ui/server.mjs:213-237`; `tools/installer-ui/server.mjs:414-417`; `tools/installer-ui/server.mjs:456-463`).

A PFX certificate run from the page is refused. Installing a PFX certificate remains a terminal
operation because the installer asks for the PFX password only when it is not running with `-Yes`
(`tools/installer-ui/server.mjs:442-447`; `Install-ClaudeGateway.ps1:1164-1166`).

The browser treats invalid business-unit JSON as a blocking draft instead of replacing it from the
last valid tree, and it keeps deployment choices scoped to the current account. Nested problem paths
focus their exact controls, including business-unit rows (`tools/installer-ui/installer-ui-business-units.js:17-21`;
`tools/installer-ui/installer-ui-business-units.js:45-51`; `tools/installer-ui/installer-ui-business-units.js:179-199`;
`tools/installer-ui/installer-ui.js:257-272`; `tools/installer-ui/installer-ui-prefill.js:90-102`;
`tools/installer-ui/installer-ui-prefill.js:109-126`; `tools/installer-ui/installer-ui-problems.js:7-22`).

The run tail and fingerprint store are in-memory. Restarting the server loses them, while the
installer checkpoint remains the resume authority for a later installer run
(`tools/installer-ui/run-record.mjs:10-35`; `tools/installer-ui/run-record.mjs:54-76`; `tools/installer-ui/preflight-record.mjs:46-82`;
`docs/adr/0046-installer-checkpoint-and-resume.md#4-schema-version-1`).

PowerShell is the live engine for the Node server. Bash parity stays visible through generated
commands only when the bash installer applies the selected answers and steps
(`tools/installer-ui/server.mjs:51-56`; `tools/installer-ui/ui-model.js:614-651`; `tools/installer-ui/installer-ui-render.js:7-50`).

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
