# ADR-0042: Status sections live in per-packet files

Date: 2026-10-01

## Status

Accepted for P87.

## Context

`.ironclad/gate.mjs` reads files through `ctx.read()`, which returns `null` when a file is larger
than `MAX_SCAN_BYTES = 512 * 1024` (`.ironclad/gate.mjs:172`, `:283-291`). Before P87,
`docs/STATUS.md` was 593,685 bytes on a Windows CRLF checkout and 585,672 bytes as a git blob.
The gate's `ledger.status` check therefore could not read the active-packet line and warned that
`docs/STATUS.md` did not name an active packet. The same size limit also meant content scans skipped
the large status file.

## Decision

Merged packet sections move to `docs/status/<ID>.md`, one file per packet ID, or to
`docs/status/YYYY-MM-DD.md` when a section has no packet ID. `docs/STATUS.md` keeps only the active
packet line, a short index, the proof commands and next work. A future packet writes its evidence
section in `docs/status/<ID>.md` on its branch; when it merges, `docs/STATUS.md` gets one index row
and the active line is updated.

`tests/Test-DocReferences.ps1` enforces that `docs/STATUS.md` stays below 64 KiB, that gate-read
ledger files and `docs/status/*.md` stay below 75 percent of `MAX_SCAN_BYTES`, and that status
archive links resolve.

## Consequences

The gate can read `docs/STATUS.md` again, so `ledger.status` reports the active packet instead of a
size-induced warning. The archived packet files are small enough for the gate's scans to read them.

The in-flight P81 branch must move its status section into `docs/status/P81.md` when it next merges
main, then add a `docs/STATUS.md` index row and active-line update.

The pre-split history remains in git before the P87 split commit; use `git log -- docs/STATUS.md`
and `git show <commit>:docs/STATUS.md` to inspect it.
