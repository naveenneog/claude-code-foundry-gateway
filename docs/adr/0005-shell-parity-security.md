# ADR-0005: Shell entry points and script security

- Status: Accepted
- Packet: P17
- Decision authority: user's renewed instruction to finish shell parity and security autonomously

## Decision

Activate P17 after completed P16. Add only the nineteen missing shell counterparts.
Bash entry points use shared Node.js modules, not PowerShell subprocesses. Existing
shell counterparts remain in place. Use structured JSON and argument arrays, never
shell evaluation. All new entry points support offline --dry-run and --help.
Dry runs do not sign in, acquire credentials, access Azure, or write files.
Live effects are described in help and docs/SHELL-SCRIPTS.md. Some administrative
commands write by default without --dry-run; only the documented commands require
--execute. Unix diagnostics adapt Windows-only client inspection.

Security fixes cover existing PowerShell and Bash scripts as well as the new code.
Tests use synthetic identities, temporary directories and mocked boundaries. No live
purge, role change, entitlement update, installation or inference is authorized by
this packet's validation. A successful local review is not a security certification.

## Verification

Run the Node test suite, Bash syntax checks, isolated Bash tests, PowerShell parsing
and the repository packet gate where tooling is available. Record unavailable
platforms and live checks rather than claiming parity from syntax checks alone.

## Consequences

Node.js is required for the new administrative shell commands. It is already used
in this repository. Ported implementations share transport and validation helpers.
No commits are made without explicit user permission. The packet exceeds the
normal uncommitted-file budget by construction; report that gate warning rather
than disabling or relaxing the detector.

Transcript capture is intentionally offline: shell operation plans and PowerShell
help replace interactive setup recordings. APIM policies use rawxml with embedded
policy expressions; the repository policy is not accepted by a generic XML parser.
Reject DTD/entity declarations locally and leave full policy syntax validation to
APIM. Conditional replacement still requires an ETag. No live policy deployment
was performed to validate this boundary. The packet remains open until its gate
passes; local tests do not waive the contract.

## Deployment-specific defaults (2026-09-07)

At the user's request, administrative scripts under `scripts/` default to
`claude-code-standard-sombaner` and `claude-code-premium-sombaner`, incorporating
the user's spelling correction. The tier key stays `premium`. Explicit group
arguments and configuration values remain authoritative.
Root installers and infrastructure defaults are outside this requested change.