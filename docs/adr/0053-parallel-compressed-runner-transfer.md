# ADR-0053: A snapshot travels to the runner compressed, in parallel parts, and is checked there

- **Status:** Accepted. The owner approved merges, live testing and architecture decisions on 2026-10-05
  and asked for P99 to proceed on 2026-10-06.
- **Date:** 2026-10-06
- **Packet:** P99
- **Amends:** [ADR-0052](0052-cosmos-default-installer.md), amendment 2, "Snapshot transfer limit"
  (about 40,000 developers)

## Context

The projection's Cosmos account and the runner have no public endpoint. Only `az container exec` reaches
the runner. That channel has these properties, measured on 2026-09-23 (`scripts/ClaudeRunner.ps1`, header):

- the runner splits the command on spaces and runs it without a shell;
- the command is URL-decoded on the way in;
- a command of 5,000 characters or more fails with `InvalidCommandLength`.

Before this decision, `Send-RunnerFile` sent one base64url chunk per exec, one exec at a time, without
compression. One exec took 6.3 s (measured 2026-10-06), about 0.8 KB of base64url a second.

A full snapshot of 500,000 records in the exporter's format is 63,152,686 bytes. That was measured on
2026-10-06 with a synthetic snapshot written in the shape of `scripts/Sync-ClaudeProjection.ps1:260-284`
(`ConvertTo-Json -Depth 6`, random object IDs, 20 business units). One chunk at a time, that file needs
about 17,400 execs, or about 30 hours. The snapshot's apply-by time is 7,200 seconds from the start of the
directory scan, and the writer checks it before its first write (`sync/src/apply-projection.mjs:342-346`).

**Exec throughput.** Measured on 2026-10-06 in East US 2 against a 2-CPU container instance. Each exec wrote
4,850 characters with `node -e`. All 318 execs succeeded.

| Execs at once | Execs | Wall time | Mean per exec | Execs a second |
|---|---|---|---|---|
| 1 | 6 | 38.0 s | 6.3 s | 0.16 |
| 4 | 24 | 41.9 s | 6.9 s | 0.57 |
| 8 | 48 | 51.9 s | 8.1 s | 0.93 |
| 16 | 96 | 68.9 s | 10.9 s | 1.39 |
| 24 | 144 | 99.5 s | 15.6 s | 1.45 |

**Compression**, measured on the same 63,152,686-byte file on 2026-10-06:

| Method | Bytes | Parts of 4,860 characters |
|---|---|---|
| gzip, .NET `CompressionLevel.Optimal` | 12,126,017 | 3,327 |
| gzip, .NET `CompressionLevel.SmallestSize` (.NET 10) | 12,860,707 | 3,529 |
| Brotli, .NET `CompressionLevel.Optimal` | 11,641,280 | 3,194 |

**Limits.** Azure Resource Manager throttles writes for each subscription and service principal: a
bucket of 200 requests, refilled at 10 a second. Global subscription limits are 15 times that
([Understand how Azure Resource Manager throttles requests](https://learn.microsoft.com/azure/azure-resource-manager/management/request-limits-and-throttling),
updated 2026-04-03, read 2026-10-06). The Container Instances quota page lists no limit for exec
([Resource availability and quota limits for ACI](https://learn.microsoft.com/azure/container-instances/container-instances-resource-and-quota-limits),
updated 2026-07-26, read 2026-10-06). An exec is a `POST` that returns a WebSocket URI and a password for a
terminal session
([Containers - Execute Command](https://learn.microsoft.com/rest/api/container-instances/containers/execute-command),
updated 2026-07-09, read 2026-10-06).

## Options considered

1. **gzip, then parts written in parallel through exec.** This option needs no new resource, identity or
   token. Each part is its own exec, so a failed part can be retried alone. The transfer runs at most about
   1.4 parts a second.
2. **Stream the file through one exec session's terminal input.** The Azure CLI uses the WebSocket that the
   exec returns as a terminal. Input passes through a pseudo-terminal, and the protocol beyond the URI and
   the password is not documented. Not measured, and not taken in this packet.
3. **Stage the snapshot in a storage account.** A public endpoint would place the directory's membership
   outside the private network that the projection uses ([SECURE-PROJECTION](../SECURE-PROJECTION.md)). A
   private endpoint cannot be reached from the operator's machine. Either way, this option adds a resource,
   an identity and a data path. Rejected.
4. **Scan the directory inside the network with the operator's token.** The operator's Azure CLI token
   would leave the operator's machine for a container. Rejected.
5. **Rely on the optional sync job.** The job already scans Microsoft Graph inside the network
   ([ADR-0045](0045-scheduled-projection-renewal.md), [ADR-0051](0051-persistent-sync-based-cosmos-entitlement.md)).
   It needs the tenant administrator's `GroupMember.Read.All` grant (U17). The deployer's populate step
   and the switch's snapshot compare run before, or without, that grant. The job stays the path for
   day-2 syncs of very large directories. It does not replace the transfer.
6. **Brotli instead of gzip.** Brotli is 4% smaller, about 130 parts or 1.5 minutes. `BrotliStream` is not
   in .NET Framework, so `ClaudeRunner.ps1` would no longer load on Windows PowerShell 5.1. Not taken.

## Decision

Option 1. It is the only option that adds no resource and no credential path.

- **Compression.** `Send-RunnerFile` compresses the file with gzip (`CompressionLevel.Optimal`), encodes it
  as base64url, and splits it into parts that fit one exec command under 5,000 characters.
- **Parts.** Each part is written to its own file in a new directory, `.xfer-<16 hex>`, next to the
  destination, with `writeFileSync`. A retry rewrites the same file. A part counts as written only when
  its exec prints `ok <index> <length>`, with the part's own index and length.
- **Parallelism.** At most 16 parts are in flight at once (`-Parallel`, 1 to 24). Each part is its own
  `az container exec` process, started from a runspace pool. The measured throughput levels off between
  16 and 24.
- **Retries.** A failed part is retried, for at most 3 attempts. The waits are 2 seconds, then 4 seconds.
  A part that fails 3 times stops the transfer. The part directory is removed, and nothing is assembled.
- **Assembly.** One exec reads the parts in name order and checks their count and total length. It decodes
  and decompresses them, writes the destination, removes the part directory, and prints the SHA-256 of what
  it wrote. The caller compares that hash with the local file's SHA-256, as before.
- **Deadline.** Before the first exec, the transfer is estimated as (waves + 2) times the measured mean
  time per exec at the chosen parallelism (10.9 s at 16). A wave is the number of parts divided by the
  parallelism, rounded up. A transfer estimated to end after the apply-by time is refused.
  During the transfer, the measured rate projects the end after each completed wave. If the projected end
  falls after the apply-by time, the transfer stops: the part directory is removed and nothing is written.
- **In-process fallback.** When `az` resolves to a PowerShell function or alias, as in the offline tests,
  runspaces cannot see it. Parts are then sent one at a time in-process, with the same protocol, checks and
  retries.
- **Command characters.** Every command follows the existing rules: no space inside the program, and no
  `"`, `%`, `+`, `&`, `|`, `<`, `>` or `^`. The programs also contain no `!`, which `cmd.exe` changes when
  delayed expansion is on.
- **Unchanged.** The callers, the snapshot format and the writer are unchanged.

## Consequences

- A 500,000-record snapshot is 3,327 parts. The estimate at 16 parallel is 38 minutes. The live result
  is in [P99 status](../status/P99.md).
- The 2-hour apply-by time must also hold the directory scan. The operator-side Graph scan of 500,000
  developers is not measured (U10). A transfer that cannot end in time is refused or stopped before it
  writes anything.
- The operator's machine runs up to 16 Azure CLI processes at once during a transfer.
- If the runner stops during a transfer, a part directory can remain until the runner restarts. A
  restarted container instance starts with a new file system, and the next transfer uses a new directory.
- The manual bash steps in [AZ-COMMANDS](../AZ-COMMANDS.md) still send one chunk at a time. A ROADMAP
  follow-up records them.

## How we'd know this was wrong

- The live run or a customer's run measures fewer than about one part a second at 16 parallel. The
  in-flight check reports the measured rate.
- Execs fail or return 429 for more than 1% of parts.
- A real directory's scan plus transfer does not fit in 2 hours. Option 2, or the sync job as the only
  directory-scale path, would then be measured.
