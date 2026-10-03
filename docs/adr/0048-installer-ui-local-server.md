# ADR-0048: Installer UI uses a local Node server with explicit localhost controls

- **Status:** Proposed
- **Date:** 2026-10-03
- **Packet:** P93

## Context

The installer UI spike recommends a local web UI started from a repository checkout in Cloud Shell or
on a workstation, with a static fallback. Microsoft Learn documents that Cloud Shell Web preview
opens a port and can browse it in a new tab (`use-the-shell-window`, ms.date 2026-08-07). The same
page does not state the preview URL shape, Host header or whether it reaches a loopback-bound
process. Microsoft Learn states that Cloud Shell includes Node.js (`features`, ms.date 2025-12-03).
The public Azure/CloudShell image source fetched on 2026-10-03 installs `nodejs24` and `nodejs24-npm`
in `linux/base.Dockerfile`. Cloud Shell sessions time out after 20 minutes without interactive
activity (`faq-troubleshooting`, ms.date 2026-02-09).

## Decision

The installer UI server uses Node's built-in `http` module and no packages. The start command is:

```powershell
node .\tools\installer-ui\server.mjs
```

The server binds `127.0.0.1` by default. A non-loopback bind address is an explicit option and prints
a risk warning. U90 records that Cloud Shell Web preview loopback reachability is unverified.

The server prints a 32-byte random token from `crypto.randomBytes`. Every request supplies the token
either as the initial query value, an `HttpOnly; SameSite=Strict` cookie set by that initial request,
or an internal test header. Token comparison hashes both sides and uses `timingSafeEqual`. Relative
URLs are used throughout because U91 leaves Cloud Shell preview path-prefix behaviour open.

The server allowlists loopback Host headers with the selected port, sends no CORS headers, refuses
`OPTIONS`, sends a Content-Security-Policy, exposes fixed routes only, limits request bodies and
returns JSON parse failures without stack traces.

The server never spawns `az` directly. Installer work goes through repository scripts. PowerShell
starts as `pwsh -NoProfile -NonInteractive -File Install-ClaudeGateway.ps1` with argument arrays and
no shell. This avoids `.cmd` and shell reparsing on Windows.

Only one installer run is active at a time. A second run receives `409`. The run route writes answers
to a per-run temporary directory, validates requested step ids against `-ListSteps -Json`, passes a
progress file path to the installer and removes the temporary directory after the request completes.
Every line returned to the browser is redacted with the existing installer redaction rule table from
`scripts/ClaudeInstallResume.ps1`. The server has an idle shutdown and does not close itself while a
run is active. Ctrl+C triggers temporary-file cleanup.

## Consequences

The milestone-1 UI can run without npm install in Cloud Shell or on a workstation. Security review
can test the server over HTTP without a browser. The static fallback, Azure prefill, plan fingerprint
and Cloud Shell live Web preview checks remain milestone-2 work.
