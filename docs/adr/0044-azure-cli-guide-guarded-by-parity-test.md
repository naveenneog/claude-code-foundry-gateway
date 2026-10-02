# ADR-0044: Azure CLI setup guide is guarded documentation, not a replacement control path

- **Status:** Accepted for P89 builder implementation; lead council/gate pending
- **Date:** 2026-10-01
- **Packet:** P89

## Context

The owner asked for plain Azure CLI commands that perform the setup work now
done by the installer, setup scripts and administration scripts. The guide is
for customer deployment review, so it must be correct enough to audit and run
manually, but a hand-written command guide can drift from the scripts that are
exercised by the packet gate.

The scripts also contain safety behavior that is not a single Azure CLI
primitive: APIM named-value size checks and read-back, premium-over-standard
entitlement precedence, fail-closed Graph reads, Cosmos projection switch
refusal, and preservation of named values that day-two operations own.

## Decision

The scripts remain the tested and supported automation path. `docs/AZ-COMMANDS.md`
is a customer-facing manual equivalent that mirrors those scripts in Cloud Shell
bash and states its verification status. It does not claim a live end-to-end run
until the owner schedules one in the customer tenant.

The guide is guarded by `tests/Test-AzCommandsGuide.ps1`. The guard parses bash
code blocks, checks every documented `az` command path and `--flag` against the
installed Azure CLI help output, checks that named values mentioned by the guide
exist in the policy XML or gateway Bicep, checks that documented Bicep parameters
exist in the target templates, and checks parity for in-scope named values that
the scripts write. Relative links remain under the existing documentation
reference check.

Out-of-scope controls are named in the guide rather than silently omitted. A
future packet that moves those controls into scope must either document their
manual command sequence or update the parity test's explicit not-covered list
with a reason.

## Consequences

The manual command guide can be reviewed independently of PowerShell automation
while still failing fast when script-owned configuration drifts. The guard
cannot prove that a command sequence succeeds in a live tenant; it proves command
shape, flags, template parameters and script/document parity. Live execution
remains separate customer-tenant evidence.
