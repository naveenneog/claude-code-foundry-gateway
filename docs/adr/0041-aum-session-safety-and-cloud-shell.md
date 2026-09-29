# ADR-0041: AUM session safety and a HOME-local Cloud Shell bootstrap

- **Status:** Accepted for P85 builder implementation; lead council/gate pending
- **Date:** 2026-09-29
- **Packet:** P85, owner additions 7 and 8

## Context

The owner reported repeated Escape closing AUM and requested a Cloud Shell
launch path. Escape currently clears navigation or dismisses a modal; a
refresh exception can independently enter Textual's fatal worker handling.
The reproduction and measured correction belong to
[P85 STATUS](../STATUS.md); this decision does not infer a live crash cause.

Cloud Shell documentation lists Python 3.9, while this package requires
Python 3.12 or newer. An unqualified `python3 -m venv` therefore cannot be
the promised path. The launcher needs a user-local supported interpreter,
not a system-Python change, root installation or new Azure resource.

Microsoft's storage-specific article and Features page describe a persisted
HOME disk image with attached storage. The FAQ currently says HOME files
are deleted after the session in both modes. These sources conflict.
The selected contract follows the storage-specific mechanism but does not
claim measured durability: U61 remains open for the owner's live restart
check. Ephemeral sessions have no persistence guarantee in either account.

## Decision

Escape never deliberately quits. Expected network/authentication failures
and publication refusals remain errors with visible explanations; their
handling does not grant a new publication origin or retry a mutation.
Unexpected programming failures are not reclassified as successful reads.
Quit requires a separate confirmation that Escape cancels.

Council round 1 extends this to application-owned mutation lifetime. A
cancelled modal worker does not cancel the transaction task or release quit
deferral before the backend and receipt handling finish. Native change forms,
generic mutation/local-write forms and assistant writes share that lifetime.
Read-only work does not. Every application exit route checks it; pending
confirmation is disabled and never automatically replayed after a save.
Explicit sign-out retains its intentional exit after its own operation
completes. Unexpected orphaned-task failures still reach error handling.

Council round 2 moves that successful sign-out intent into application-owned
completion handling after registry release. A cancelled modal worker cannot
lose it. Other pending mutations finish before exit; failed sign-out does not
request exit. The form replaces saving progress with completed-sign-out
status while another operation remains.

The Cloud Shell launcher installs a pinned uv wheel into a HOME-local
bootstrap directory, uses its managed Python 3.12 to create/reuse the AUM
venv, and installs the checked-out package in editable mode. Editable
installation keeps Direct's repository-script lookup attached to that
checkout. uv's documented automatic Python download avoids assuming the
image's system Python meets AUM's requirement. No downloaded shell script
is executed and no system interpreter or shell profile is replaced.

Launcher-controlled state, Python downloads, caches, bytecode and temporary
files stay under a canonical HOME-local root. Canonical destination checks
reject escaping symlinks before setup. Source/build metadata stays in the
selected repository. Inherited Python/pip destinations do not redirect the
bootstrap. This is a boundary for trusted tooling and the trusted checkout,
not an operating-system sandbox for malicious package code.

Council round 1 found that the original selective environment reset missed
`PIP_LOG`. The corrected bootstrap removes inherited pip, uv and XDG namespaces,
then supplies only canonical HOME-local destinations. Python's user base is
also pinned under that root. Real pip runs with explicit no-network flags in
the regression, alongside individual destination-write probes; fake argument
inspection alone is not evidence that pip cannot create an external log.

The launcher neither signs in nor changes Azure CLI configuration. AUM uses
the Cloud Shell session's existing identity and the same governance writers.
Cloud Shell hosting adds no Azure component to this repository's deployment.
Private endpoints still require an appropriately connected VNet Cloud Shell.

## Evidence and outstanding verification

All references were accessed on 2026-09-29:

- [Cloud Shell features and tools](https://learn.microsoft.com/azure/cloud-shell/features):
  automatic authentication, Python 3.9, PowerShell, HOME persistence.
- [Persist files in Cloud Shell](https://learn.microsoft.com/azure/cloud-shell/persisting-shell-storage):
  HOME disk image and clouddrive mechanisms.
- [Cloud Shell FAQ](https://learn.microsoft.com/azure/cloud-shell/faq-troubleshooting):
  twenty-minute inactivity limit and the conflicting HOME wording.
- [Ephemeral sessions](https://learn.microsoft.com/azure/cloud-shell/get-started/ephemeral):
  files are deleted when the session ends.
- [uv installation](https://docs.astral.sh/uv/getting-started/installation/)
  and [managed Python](https://docs.astral.sh/uv/guides/install-python/):
  PyPI wheels and automatic interpreter acquisition.
- [uv 0.12.20 binary lookup](https://github.com/astral-sh/uv/blob/0.12.20/python/uv/_find_uv.py):
  the wheel installed with `pip --target` places the executable in that
  target's `bin` directory.
- [CAE IP-address troubleshooting](https://learn.microsoft.com/entra/identity/conditional-access/howto-continuous-access-evaluation-troubleshoot#ip-address-configuration):
  split tunneling, IPv4/IPv6 differences and administrator-reviewed named locations.

Offline tests use fake commands and backends. The owner-only live check covers
bootstrap downloads, actual runtime availability, terminal keys, selected
endpoint reachability, Conditional Access and persistence after a session
restart. No live Cloud Shell success is claimed.
