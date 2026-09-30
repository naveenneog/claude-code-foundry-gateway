# ADR-0035: Bounded AUM readiness and progressive reads

- **Status:** Accepted for P71 implementation; council and merge belong to the lead
- **Date:** 2026-09-28
- **Packet:** P71

## Context

The owner authorizes this packet on `p71-aum-speed`, alongside other worktrees.
This supersedes the single-active-packet wording for this assigned worktree, not
the test-first or gate contract. The lead conducts the five council reviews.
This branch records its tests, mutations, live measurements and packet gate, and
does not mark the ROADMAP packet complete.

The 2026-09-27 investigation found a stopped Turnstile PostgreSQL server behind a
healthy `/health` endpoint. Authenticated `/api/v1/auth/me` waited about 30 s for a
database pool connection, then returned 500. Tonight's initial state and stop
timestamps are recorded under U32. Direct also repeated token acquisition and
PowerShell processes, and the terminal withheld all data until identity and
capability discovery completed.

The dominant criterion is time to truthful, actionable information. Replacing a
blank screen with an indefinite spinner would not satisfy the owner's rule that
every wait has a progress indicator or an estimate.

## Options

1. Change Turnstile readiness or pool configuration. That product is in another
   repository and is outside this packet's authorization.
2. Automatically start the database or fall back to Direct. Either changes cost
   or authority without the operator's explicit choice; neither is accepted.
3. Bound the client's authenticated readiness read, diagnose through read-only
   Azure metadata, and remove redundant work within each Direct read cycle.
   This is the selected approach.

## Decision

### Readiness and diagnosis

The existing authenticated identity read is the readiness probe; an additional
liveness call is not evidence of database readiness. Turnstile identity uses a
short HTTP timeout. A timeout or 5xx initiates a bounded read of PostgreSQL state
in the deployment resource group recorded by `turnstile-integration`.
Discovery preserves that address metadata in `turnstile_resource_group`; older
gateway-backed profiles can resolve it from their gateway. Address-only profiles
remain valid without any Azure resource-management permission.

Only an unambiguous, validated server reported as `Stopped` produces exit **9**
and the command `az postgres flexible-server start -g <group> -n <server>`.
The diagnostic command includes the selected subscription when known. Ready,
starting, missing, unreadable, malformed and ambiguous inventories are not
reported as a stopped database. Authentication and scope failures keep their
existing codes. Generic availability failures keep exit 7 and explain when
database state could not be verified. No response body, bearer token or raw
transport exception is included in the message. Nothing starts automatically.

HTTP timeouts bound network inactivity, not all possible workstation or network
delays. The approximately-five-second acceptance is measured end to end with a
warm Azure CLI session; the ledger records cold-start and metadata-lookup costs
separately rather than treating a configured timeout as a timing measurement.

The first live implementation measured the PostgreSQL CLI inventory at **3.075 s**
and `az rest` at **2.524 s**, exceeding its 2.5 s diagnostic subprocess budget.
The diagnostic therefore uses bounded ARM HTTP reads with one resource token,
including the named-value read for older profiles. It does not add a healthy-path
inventory request or accept a timeout as proof that a database stopped. The tests
pin the exact ARM origin, resource group, subscription, API version and no-redirect
behavior instead of the removed CLI command spelling.
For an Azure-selected profile the diagnostic ARM credential is acquired while
the authenticated readiness request is pending. The database inventory is still
read only on timeout or 5xx; an address-only app-role profile does not acquire that
credential. Token acquisition, including a wait on another in-process acquisition,
has a bounded deadline. A healthy API does not require a successful ARM read.

Live terminal measurement also reproduced a Windows process-tree failure:
`subprocess.run(timeout=...)` killed the `az.cmd` wrapper, but its Python child
kept redirected pipes open. An offline two-second child outlived a 150 ms timeout.
AUM recognizes the installed MSI launcher's existing `python.exe -IBm azure.cli`
entry point and calls that owned process directly with the same installer
environment. Other Windows wrappers run in an owned Windows job, terminated with
their descendants on timeout. The Turnstile sign-in credential has its own short
deadline. This does not terminate any other operator's process or change Azure
CLI's global account. Windows job inheritance and termination are documented in
[Job Objects](https://learn.microsoft.com/windows/win32/procthread/job-objects),
retrieved 2026-09-27 UTC.

### Direct read cycles

Resource tokens are kept only in process memory, keyed by resource and selected
Azure account context, synchronized across simultaneous reads and refreshed
before expiry. Explicit sign-out clears them. A token is never written to a
profile, evidence file, command line or log.

A read cycle shares a bounded gateway snapshot. One PowerShell invocation and
one named-value listing supply catalog, tiers, budgets and the existing USD
conversions. The existing PowerShell serializers remain the only serializers.
Individual batch-read errors remain errors for their requested view, not
invented empty data. The snapshot does not survive the read cycle or a write;
authorization preflight, optimistic conflict detection and compensation continue
to read fresh state. Independent read-only telemetry queries can overlap.
Writes remain serial and are never retried automatically.

### Terminal

The existing Textual widgets, themes, keyboard navigation and no-motion policy
remain. A refresh tracks the actual pending sources and displays an estimate
and elapsed time. Each Overview panel renders when its source arrives; missing,
loading, failed and genuinely empty data remain distinct.

Direct read-only data is authorized by Azure independently of its identity
label. Those reads can begin while Azure identity/RBAC lookup runs, but edits
stay disabled until identity and capabilities are verified. HTTP-backed scoped
data still waits for the current identity/scope check required by ADR-0018;
settings and wait/error feedback do not. This preserves the existing empty-scope,
context-parent and scope-change guarantees instead of trading them for speed.
Cancelled or superseded refreshes cannot publish stale data into a newer view.

## Evidence and assumptions before implementation

- The full investigation is the owner's 2026-09-27
  `aum-turnstile-investigation.md`; public observations are in U32 and STATUS.
- Microsoft documents the resource-group PostgreSQL list and each server's
  state in [Servers - List By Resource Group](https://learn.microsoft.com/rest/api/postgresql/servers/list-by-resource-group?view=rest-postgresql-2024-08-01).
- The explicit operator action is documented in
  [az postgres flexible-server start](https://learn.microsoft.com/cli/azure/postgres/flexible-server#az-postgres-flexible-server-start).
- [HTTPX timeouts](https://www.python-httpx.org/advanced/timeouts/) distinguish
  connect, read, write and pool timeouts; they are not a whole-operation SLA.
- Sources were retrieved 2026-09-27 UTC. U37 records the deployment-inventory
  assumption and its fail-closed negative cases before implementation.

## Council round 1 amendment, 2026-09-28

A caller's token deadline covers both the cache-lock wait and acquisition; the
acquirer receives only the remaining monotonic budget. A Windows command wrapper
is created with `CREATE_SUSPENDED`, assigned to its job, and only then resumed.
CPython closes the primary thread handle, so AUM locates its own suspended
thread using [Thread32First](https://learn.microsoft.com/windows/win32/api/tlhelp32/nf-tlhelp32-thread32first)
and resumes it with [ResumeThread](https://learn.microsoft.com/windows/win32/api/processthreadsapi/nf-processthreadsapi-resumethread)
(sources retrieved 2026-09-28). Assignment failure kills the suspended wrapper
without executing its child program.

The existing 150 ms timeout / one-second completion assertion is retained and
now requires evidence of a real process creation. A separate, longer startup
window proves the child and grandchild both executed, then verifies their PIDs
are terminated. This distinguishes an enforced deadline from a launch failure
and covers a 350 ms scheduling delay before assignment.

Resource-token reuse additionally requires a verified principal and Azure CLI
session binding. A changed binding invalidates its previous generation; an
unbound caller obtains a fresh token rather than borrowing a previous person's
credential. Direct verifies the account once per read cycle and shares that
fast result across its queries and identity label. RBAC permission lookup remains
independent of data arrival. A new cycle rechecks the account, and an identity
change invalidates credentials and the cycle's snapshot. In-flight results from
an obsolete credential generation are refused before they can become current
data. This supersedes the earlier interpretation that a configured subscription
alone was sufficient to reuse a token before identity verification.
HTTP identity reads obtain current CLI credentials instead of using the previous
identity's cached bearer. A verified identity change clears that backend's
credentials and increments a response generation; an older in-flight response
is refused. The token-cache tests now supply explicit verified contexts, and the
Direct independence tests distinguish the required account check from the RBAC
permission lookup they continue to forbid before data.

## Council round 2 amendment, 2026-09-28

The credential-generation binding also covers a read cycle's cached account,
gateway snapshot and aggregates. The first verified principal pins that cycle's
immutable credential generation; a cached account never rebinds it. Each cached
or newly completed snapshot and each completed aggregate checks the same
generation before returning data. Invalidating credentials makes every cycle
holding that generation obsolete, not only the calling cycle. Obsolete cycles
fail with a sign-in-changed error; a new cycle performs fresh verification.
Multi-source chargeback, lookup, trend comparison and person-detail reads keep
that cycle open through assembly, as status and governance already do. This
prevents an aggregate from combining a completed A-only source with later reads
after a verified B sign-in.

## Council round 3 amendment, 2026-09-28

HTTP reads pin a generation across complete aggregate assembly, not only each
request. Already-completed sources cannot be combined after a different
identity is verified. Progressive delivery and final publication validate the
same read-cycle generation immediately before writing the UI cache or rendering;
the outer cycle exit alone is too late for a progressive view. The same
publication boundary applies to completed capability results and command output.
A mismatch discards the result and reports sign-in changed, not success with
data from the previous principal.
The publication guard captures the originating cycle and serializes its
validation and synchronous publication with identity changes. Cached redraws
and deferred dialogs retain that guard. The follow-up review reproduced the
same delayed-completion defect in HTTP backend caches, identity/CSV output,
lookup/detail/export controls, assistant state and membership links; these
surfaces keep the read cycle through publication as well.

## Council round 4 amendment, 2026-09-28

A cached item's originating publication guard remains attached when the item
is passed to another deferred control. A newly opened cycle that performed no
read cannot replace that guard. Freshly re-read details use their new read's
guard; cached details retain the prior source guard through dialog composition.
The lead explicitly owns integration and full-suite/gate execution for this
round; targeted pytest and mutation evidence are the branch handoff.
The same source guard accompanies dashboard rows, cached edit/prefill defaults,
assistant chart pins and request copy/ledger actions. Chaining one cached form
into another retains the parent's guard. Closing the source HTTP or Direct
connection invalidates retained guards rather than leaving deferred items
authorized indefinitely. No new component, endpoint or authorization authority
is introduced by these guard-lifetime corrections.

## Council round 5 amendment, 2026-09-28

All backend-derived publication uses one function that accepts the originating
guard and executes the synchronous write while that guard is valid. It also
guards reuse of cached assistant context for outgoing requests. The UI observes
verified principal transitions and clears prior-principal tables, selections,
forms, dialogs, cached guards, capabilities and assistant context before input
dispatch or direct action reuse. Failure reports sign-in changed without
publishing stale values. An AST contract rejects bypassing sinks and has a
commented, exact static-text allowlist; allowlist entries do not exempt a whole
handler. This replaces the earlier convention that each handler manually
remembered to apply a guard.
`guarded_publish` is the single execution function; `published` delegates
synchronous renderer/generator execution to it. Source origins retain both
backend validation and the UI engine/revision, including rejection cleanup.
`PrincipalUI` drains verified transitions before event/input dispatch, closes
obsolete controls and clears all old-principal presentation state. Assistant
egress re-verifies identity before using its cached context. Formatters require
an active publication; expired inherited scopes and async publication
decorators are refused. The structural detector discovers presentation modules
and checks calls, widget property assignments and clipboard subprocesses,
with 51 exact commented static-write exceptions and no handler exemptions.

## Council round 6 amendment, 2026-09-28

Presentation sinks enforce the active, current originating publication at
runtime, independently of a call's spelling. The widget/property, status,
clipboard, export/formatter and assistant egress layers refuse a deferred raw
call once its scope ends. `guarded_deferred(origin, callback)` is the explicit
way to schedule publication: it rechecks the captured origin when the callback
runs. Deferred async work rechecks at each sink rather than holding an identity
lock across an await. The AST contract is a second line of defense: dynamic
sink attributes, partials and guarded-scope callbacks escaping to schedulers
must not bypass it. The 51 static exceptions remain exact and separate from
documented framework-internal access needed to implement the sink layer.
The concrete layers are `publication_widgets.py` (Textual methods, properties
and app clipboard/links), `publication_output.py` (final text, rich, CSV file
and clipboard-helper output), and the HTTP assistant-request transport.
They delegate to `publication_sink`, which checks the active source through
`guarded_publish` at the write. The sink decorator rejects coroutine, generator
and async-generator functions: checking creation of a deferred body does not
authorize its later execution. Six identified framework input/mount handlers
and framework input actions use retained provenance; application handlers and
layout/idle dispatch do not gain implicit authority. A refused scheduled write
is handled before Textual abandons its message loop, clearing the view and
retaining the explicit exit-3 explanation.
Repeated input edits retain one immutable content origin rather than nesting
the previous keystroke's wrapper. This bounds guard depth without replacing
the original credential generation with an unpinned current-identity guard.

The reported navigation cancellation is investigated with a bounded repeated
test/file run under the shared lock. No timeout, assertion or suite budget is
relaxed to conceal it. The resumed correction runs the full AUM/FinOps Python
suite once under the shared lock; council round 7 and the integration gate
remain with the lead.

## Council round 7 amendment, 2026-09-28

The public `Static.content` setter has the same origin check and provenance
retention as `update`, `value` and `text`. Descriptor setters and raw widget
state are not supported presentation APIs: they bypass provenance even inside
a syntactically guarded scope. The structural contract rejects those accesses,
`exec`/`eval`, additional scheduler spellings and partial methods. Three exact
internal operations remain necessary: the sink's base setter, its non-content
attribute forwarding and the framework action MRO lookup. These are local,
documented expressions, not module or handler exemptions; the 51 static
presentation exceptions remain unchanged.

Direct or wrapped publication refusals reach the application exception
boundary before Textual constructs fatal diagnostics. The boundary presents
only the safe refusal, not wrapper text, callback arguments or traceback
locals. The app-owned event-loop handler routes the same refusals to that
boundary and restores the previous handler when its lifetime ends. Other
exceptions retain their existing application or loop handling. Actual
scheduled callbacks test both liveness and absence of payload in output.

The installed Textual 6.12.0 implementation was inspected on 2026-09-28:
`App._handle_exception` calls a fatal renderer with `show_locals=True`;
`Timer._tick`, `MessagePump._flush_next_callbacks` and screen callbacks reach
that boundary, while `MessagePump.on_timer` may wrap the original error.
Python event-loop callback errors have a separate loop handler. The ownership
and restoration controls therefore accompany the refusal fix, rather than
assuming that every scheduler runs through message dispatch.

The shared lock is held for one long validation command and released in that
command's `finally`. One full Python suite follows the fixes. Round 8 and the
packet gate remain with the lead; no integration or Azure operation occurs.

## Council round 8 amendment, 2026-09-29

### Threat model and closed source contract

Presentation modules are maintainer-written. The detector enforces a closed
import allowlist and a metaprogramming ban. New modules and imports require
an explicit classification/approval rather than being trusted because a
known sink name did not match. Presentation output comes only from the
protected output module; displayed controls use approved wrappers. Raw
terminal streams, raw output functions, raw Rich consoles, unwrapped Textual
widgets and direct file/clipboard writers are not presentation imports,
regardless of aliases.

`sys.modules`, computed `getattr`/`setattr`/`delattr`, writes to classes or
raw instance state, `object.__setattr__`, dynamic code and dynamic imports
are not presentation APIs. A necessary internal operation has an exact
justification entry checked by the tests. This is not a handler-wide or
module-wide metaprogramming exemption.

The runtime guards cover construction, writes, protected-instance class
changes, attachment/reuse of retained widgets, and scheduling through retained
origins. Attachment checks the original source before DOM registration;
the current caller's scope cannot replace that origin. Reused subtrees and
compose results take the same path. The round 7 safe refusal and input
liveness boundaries remain.

Deliberately malicious in-process code is out of scope: Python code with
access to the process can bypass an in-process check. The source contract
prevents unsupported operations in maintained presentation code; it is not
a sandbox or a claim that arbitrary Python reflection is contained.

The maintained policy explicitly classifies all package source modules and
approves named imports and member interfaces. Importing an approved module
does not expose every member or permit passing the module object elsewhere.
Raw implementation imports exist only in `publication_output.py` and
`publication_widgets.py`; reviewed AST fingerprints bind those exceptions to
their implementation, not just their filenames. Exact metaprogramming
exceptions also bind the enclosing function's AST, including the fixed
cache-field tuple and framework input checks on which their reasons depend.

Layout containers, tabs and the application now come from the protected
widget module too. An empty modal shell has a local-message origin when no
publication is active. Data-bearing dialog constructors enter their explicit
retained guard first, so that fallback does not replace the source of their
cached facts; their children keep the same source. Terminal console creation,
CLI prompting and profile/report writes stay inside the protected output
module. Presentation passes path strings and receives values, not raw
filesystem or stream capabilities.

The installed Textual 6.12.0 `_register_child` implementation inserts into
the parent's nodes and application registry before `_attach`. Prevalidation
therefore occurs at the application's registration boundary. Checking only
`on_mount` or `render` is too late or can miss cached visuals. These native
paths were inspected on 2026-09-29 before implementation.

## Council round 9 amendment, 2026-09-29

The maintained presentation contract is closed at import, attribute and
builtin level. Every attribute load and literal `getattr`/`hasattr` member
needs approval; approving an imported object does not approve its entire
interface. Raw console/stream/driver access, private and dunder members,
`write`/`writelines` and raw `notify` are excluded from the ordinary member
set. Necessary internal operations retain exact-expression justifications
and reviewed context fingerprints. Parameterized `super` is rejected;
ordinary constructor/adapter forwarding uses explicit checked contexts.
The ordinary attribute set has no private names or raw output members.
Existing internal cache/lifecycle accesses, backend operator writes and
native sink operations are separate exact-expression exceptions, each with
a factual reason and its function's AST fingerprint. They do not approve a
private name elsewhere or exempt the rest of a handler. Synthetic detector
fixtures use reviewed public names so that the import/attribute checks do
not accidentally substitute for the specific lexical rule under test.

`publish_notification` requires the originating guard and retains it in the
queued notification. Acceptance, toast creation and visible rendering
validate that same source. A principal transition clears old notifications.
The standard selector enables notifications and observes their rendered
output; headless mode alone does not establish notification safety.
The native Textual 6.12.0 notification queue, rack and toast lifecycle were
inspected on 2026-09-29 before these changes.

This remains a contract for maintainer-written code, not a Python sandbox.
Approved application/backend APIs and the two reviewed boundary modules
remain trusted implementation. The checker does not infer data provenance
from arbitrary Python values, and deliberate in-process code can bypass
checks. Supported presentation paths carry and validate their actual source;
the contract rejects access to capabilities outside those paths.

## Council round 10 amendment, 2026-09-29

Approval of a DOM query also includes the effects of the objects it returns.
Native descendants that can display content require the same receiver-level
publication enforcement as directly imported wrappers. Unsupported native
content types are refused before attachment rather than trusted by omission.
Framework chrome displays only static or source-guarded content.
The native adapter accepts exact reviewed classes, not a module-name prefix or
an inherited class name. It guards content properties, mutating methods and
cached rendering. Application titles remain static after construction.
Native-first inheritance preserves Python's instance layout when a framework
child is adapted; ordinary code cannot replace a protected widget's class.
Textual's asynchronous reactive watcher retains the publication origin on
both widgets and the app. Initial Header watchers are scheduled on the watched
app or screen, not necessarily the Header, and unused watcher coroutines are
closed on refusal or shutdown.
Expired cached paint returns blank output and emits one fixed refusal notice;
it does not cancel a newer source read merely because an older native caption
still needs repainting. Input/write refusals keep the existing application
rejection path. Native command search recognizes only Textual's exact
`CommandPalette._gather_commands` worker and receiver, retains that origin
through awaits, and replaces its argument-bearing diagnostic description.
Its three input/selection handlers use the same reviewed framework-input
boundary. Arbitrary supplied workers do not acquire this authority.

These effects were checked against installed Textual 6.12.0 on 2026-09-29:
[`App._register_child` and exit rendering](https://github.com/Textualize/textual/blob/v6.12.0/src/textual/app.py),
[`MessagePump._on_message` logging](https://github.com/Textualize/textual/blob/v6.12.0/src/textual/message_pump.py),
[`reactive._watch` and `await_watcher`](https://github.com/Textualize/textual/blob/v6.12.0/src/textual/reactive.py),
and the native Header/Footer implementations under `src/textual/widgets`.
The command-search worker and handlers are in
[`command.py`](https://github.com/Textualize/textual/blob/v6.12.0/src/textual/command.py).
The local counterexamples are in `test_publication_native.py` and
`test_publication_diagnostics.py`.

`exit(result)` returns a value and remains supported. The optional
Textual exit `message` is an output sink and is refused on the raw exit API.
Any displayed farewell/error text takes the guarded publication path.
Queued messages and notification records omit payloads from both normal and
Rich representations before Textual logs them; this includes message/title
and deferred callback arguments, not only the originating guard.

### Diagnostic message compatibility correction, 2026-09-30

Payload-free diagnostic subclasses must preserve Textual's message controls:
an original message type passed to `prevent`, `disable_messages` or
`enable_messages` still identifies its sealed messages, including forwarded
instances and messages posted by adapted native descendants. Other native
eligibility checks, dispatch handlers and payload-free representations remain
unchanged. No publication origin or source approval is relaxed.

Textual 6.12.0's `MessagePump.check_message_enabled` and
`Widget.check_message_enabled` compare exact types, while
`TabbedContent._watch_active` suppresses the internal `Tabs.TabActivated`
notification before publishing its own activation. Sealing before that check
caused duplicate activations and cancelled exclusive refreshes. The correction
is at the diagnostic adapter, not a test sleep or a broader readiness timeout.
Deterministic tests cover original and already-sealed messages, protected and
adapted-native receivers, re-enabling delivery and an event-held real tab read.
They remain in the existing standard `test_publication_diagnostics.py` selector.
The native chrome probe additionally holds a real footer remove/remount gap,
then awaits the native after-refresh callback and batch lock before testing the
current receiver. Its original raw-write refusal and privacy assertions remain;
neither worker completion nor an arbitrary pause substitutes for that lifecycle.

### Stale tab activation correction, 2026-09-30

The terminal may receive a retained tab activation after main content has
been removed during remount or shutdown. `switched` must check that main
content exists before querying its active pane; an absent main view makes the
event stale, not an error or a request to restart a read. Current activations
retain their existing principal-notice and active-pane checks. Deterministic
running-gap and shutdown cases include a live-activation positive control.
This lifecycle rule does not grant a new publication capability.

### Compound view refresh correction, 2026-09-30

A compound navigation action prepares its query state before requesting one
explicit view refresh. Every accepted lookup follows this rule, including
request lookups; a request lookup also opens one detail worker. A refresh
preserves request paging/cursors and consumes its pending selection, matching
request rows by `request_id`. An open detail modal remains open during the read.
Keyboard tab actions keep their existing behavior. Programmatic selector
changes must not add another refresh to that same action. No publication origin,
output permission or worker-cancellation error handling changes.

"Tab changed" is not proof that its later activation will refresh.
A principal notice, a newer active pane or removed main content can
cause `switched` to ignore that message. Accepted compound actions instead own
one explicit refresh of their fully prepared current state and suppress their
redundant native activation. Ordinary native activations keep all existing
notice, stale-pane and missing-main checks. The notice remains an advisory
latch, never a source credential: fresh guarded lookups are usable, while
expired guards still refuse old results before navigation or input publication.
`PrincipalUI.on_event` clears the notice on the first `InputEvent`, before
dispatching its action. A normal user-started lookup therefore sees it cleared;
the notice-present rule covers non-input direct calls and guarded callbacks.
No read is resurrected by a late event after the view has been removed.
Native pane-focus delivery is also asynchronous. The protected tab receiver
checks that the event pane still contains the current focus before forwarding
the native focus handler once. An obsolete focus message cannot retarget a
newer lookup or create a replacement refresh. This changes no source origin
or content-write permission; exact receiver/effect approvals cover the adapter.

### Approval recipe for attributes and builtins

An approval is reviewed like code. The review identifies every supported
receiver type, whether the member is read, invoked or assigned, and the value
or capability it returns. The effects include terminal/error streams,
diagnostic logs, notifications, exit rendering, files, clipboard, browser
links, deferred callbacks and native descendants returned by queries.
A member name alone does not establish that every receiver is protected.
The resulting receiver/effect findings are recorded with the approval's
reason and, for an exception, its exact expression and enclosing context.

A new ordinary member/builtin needs a positive current-origin control and
a negative expired/changed-origin or forbidden-capability control through
its actual effect. Deferred paths include delivery/rendering, not only queue
acceptance. Log-sensitive paths use a fresh process with `TEXTUAL_LOG`;
notification paths enable rendering. A removal probe retains the baseline
test identities and must fail a behavioral or source-contract assertion,
not collection or syntax.

Implementation changes precede fingerprint updates. The affected source and
its call chain are inspected, the RED/GREEN evidence is retained, and
`publication_policy.digest(ast.parse(source))` supplies the reviewed boundary
fingerprint. Exact exception contexts use `digest(functions(tree)[scope])`.
The changed reason/expression and literal fingerprint are reviewed together;
a failing fingerprint is not updated merely to silence the detector.
The source-contract tests and targeted runtime cases then pass on the same
tree before the green commit. Changes to a diagram witness are followed by
the existing architecture renderer and image review.

The import, attribute and builtin contract remains a maintainer-code
contract, not a malicious-Python sandbox or automatic taint analysis.
Reviewed backend APIs, framework adapters and source guards are trusted
implementation. Approvals that expose a new receiver/effect require the
same review and counterexamples as a new sink.

## Consequences

No server deployment, account switch, consent, resource grant or authority
change is added. The only authorized live write by this packet is the owner's
named database start after stopped-case measurements; the database is left
running. The U32 external stopping automation remains an operational unknown.

Offline pytest and PowerShell checks cover the new boundaries, followed by
deliberate detector mutations and a full locked packet gate with pytest enabled.
Live timings use separate CLI processes and saved profiles, with output and
failure timings distinguished. Terminal captures are read-only and redacted.
