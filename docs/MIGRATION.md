# Migrating a large organisation from first-party Claude to Foundry

Four requirements, treated separately, because they have genuinely different
answers and different owners:

| # | Requirement | Short answer |
|---|---|---|
| [1](#1-history-memory-and-sessions) | Keep chat history, memory and sessions intact | **Claude Code and Cowork memory survive intact. Desktop conversations do not, and cannot be imported — but they can be exported, and Claude.ai memory can be moved across as CLAUDE.md.** |
| [2](#2-mass-deployment-through-mdm) | Bulk install and push user-level config via MDM | Fully supported. Managed settings override every user-level value. |
| [3](#3-bulk-entitlement-from-a-csv-or-an-entra-group) | Bulk migration from C4E, CSV or Entra groups | `Import-ClaudeEntitlement.ps1`. Budget effort for identity resolution, not for the import. |
| [4](#4-cutover-runbook) | How to actually run it | Export first, pilot, dual-run, cut over, decommission. |

Every claim below was checked against Anthropic's documentation or against a
live deployment. Where something is genuinely undocumented it says so rather
than guessing.

---

## 1. History, memory and sessions

### The short version

**Claude Code loses nothing. Claude Desktop loses conversation history, and
there is no import path.**

That asymmetry is the single most important thing to communicate to a customer
before they commit to a date, because it is a one-way door and it surprises
people late if nobody said it early.

### Why

Claude Code keeps its state on local disk, and that state is
provider-independent. Switching to Foundry changes environment variables, not
storage. Anthropic's feature matrix confirms CLAUDE.md memory, plugins and MCP
servers work on every provider.

Claude Desktop is different. Anthropic's own architecture table for third-party
mode:

| Component | Standard Claude Desktop | Claude Desktop on 3P |
|---|---|---|
| Web application | Loaded from claude.ai | Bundled inside the desktop app |
| User identity | Anthropic account | **Local device identity only** |
| Conversation storage | **Anthropic backend** | **Local disk on the user's machine** |

— [claude.com/docs/third-party/claude-desktop/overview](https://claude.com/docs/third-party/claude-desktop/overview)

In third-party mode there is no Anthropic account, so there is nothing to sync
*from*. This is observable on any machine that has run both modes: they use
separate storage roots, each with its own IndexedDB.

```
%APPDATA%\Claude\                 first-party: Local Storage, IndexedDB, Session Storage
%LOCALAPPDATA%\Claude-3p\         Foundry mode: its own Local Storage and IndexedDB
```

Switching a user to Foundry gives them an empty Desktop. Their old
conversations are still in the first-party app, and still on Anthropic's
backend, until the account is deprovisioned.

### What to do about it

| Artefact | Survives? | Action |
|---|---|---|
| Claude Code session transcripts | Yes | None. `~/.claude/projects/<project>/*.jsonl` |
| Claude Code prompt history | Yes | None. `~/.claude/history.jsonl` |
| CLAUDE.md memory, all scopes | Yes | None — and you can now deploy an org-wide one, see below |
| Claude Code auto memory | Yes | None. `~/.claude/projects/<project>/memory/` |
| **Cowork memory** | **Yes** | None — Cowork runs on Claude Code and reads the same files |
| MCP servers, plugins, settings | Yes | None. `~/.claude.json`, `~/.claude/settings.json` |
| **Claude Desktop conversations** | **No** | **Export first. No import path into third-party mode.** |
| **Claude.ai chat memory** | Not automatically | **Exportable, and it lands as CLAUDE.md.** See below |
| Claude.ai Projects | No | Not available in third-party mode |
| Claude.ai server-side Memory feature | No | No equivalent surface in third-party mode |

### Exporting past conversations

This is a **central admin task on Team and Enterprise, not a per-user one** —
which changes the runbook, because "tell everyone to export" does not work.

| Plan | Who exports | Where |
|------|-------------|-------|
| Team, Enterprise | **Primary Owner only** | Organization settings → Data and privacy |
| Free, Pro, Max | Each user | Settings → Privacy |

Both run from the web app **or Claude Desktop**; neither works from iOS or
Android. The export is processed asynchronously and a download link arrives by
email.

> **Export before you delete anything.** Anthropic's documentation is explicit:
> messages, files and projects deleted from the account — manually *or by
> enterprise retention settings* — are not included in exports initiated after
> the deletion. A retention policy that trims at 90 days will already have
> removed what you were hoping to archive. Run the export as the first step of
> the migration, not the last.

Audit logs are a separate export for Enterprise Primary Owners.

Treat the archive as a read-only reference. It does not load into Desktop on
Foundry.

— [Export your organization's data](https://support.claude.com/en/articles/13346720-export-your-organization-s-data),
[Export your Claude data](https://support.claude.com/en/articles/9450526-export-your-claude-data)

### Memory: three things with the same name

Most of the confusion here comes from "memory" meaning three separate
mechanisms. They have three different answers.

**1. Claude Code memory — survives untouched.** `CLAUDE.md` at every scope,
`~/.claude/rules/`, and auto memory under
`~/.claude/projects/<project>/memory/`. All local, all provider-independent.

**2. Cowork memory — the same files, so it also survives.** Cowork sessions in
Claude Desktop run on Claude Code and read `~/.claude/CLAUDE.md` and
`~/.claude/rules/`. This is the part people expect to lose and do not.

> One real difference: in Cowork sessions Claude Code deliberately **skips
> `@`-imports inside user-scope memory files**, as a hardening measure. A
> `CLAUDE.md` that pulls content in by reference will look empty in Cowork.
> Keep the content inline.

**3. Claude.ai chat memory — no automatic path, but not lost either.** There is
no Anthropic account in third-party mode, so Claude's own memory import flow has
nothing to import into. Anthropic does document a **prompt-based export**: you
ask Claude to list everything it has stored about you, and it returns a single
code block.

That block is Markdown, and `CLAUDE.md` is Markdown, so it moves across
directly:

```powershell
# paste the exported block, or point at the file you saved it to
./scripts/Import-ClaudeMemory.ps1 -Path .\exported-memory.md
```

It strips the code fence, writes `~/.claude/CLAUDE.md`, keeps anything already
in that file, and replaces its own block rather than stacking on a re-run.
`-Scope managed` writes the fleet-wide file instead — for shared standards,
rather than one person's memory.

Two caveats worth passing on: memory import on the Claude.ai side is described
as experimental, and Team and Enterprise organisations are currently on the
legacy memory experience pending a rollout. Neither affects the
export-to-CLAUDE.md route above, which is just text.

— [Import and export your memory](https://support.claude.com/en/articles/12123587-import-and-export-your-memory-from-claude)

**Claude Desktop's Chat surface has no memory feature in third-party mode.**
There is no configuration key for it and no mention in the reference. The only
memory that reaches Desktop is through Cowork, from Claude Code's files.

### Give people a reason not to mind

The migration is a good moment to deploy an organisation-wide CLAUDE.md, which
first-party users never had. It sits above every user and project file:

| Scope | Location |
|---|---|
| Managed policy | `C:\Program Files\ClaudeCode\CLAUDE.md` (Windows) |
| | `/Library/Application Support/ClaudeCode/CLAUDE.md` (macOS) |
| | `/etc/claude-code/CLAUDE.md` (Linux, WSL) |
| User | `~/.claude/CLAUDE.md` |
| Project | `./CLAUDE.md` or `./.claude/CLAUDE.md` |
| Local | `./CLAUDE.local.md` |

A `claudeMd` key in managed settings inlines the same content without shipping
a file.

### Where history lives afterwards: local or cloud

Local disk is the default and is all either client does on its own. For an
organisation that usually is not enough: nothing roams, nothing is backed up, a
reimaged laptop loses everything, and there is nothing to search when Legal
asks. There are three shapes, and they combine.

**Local** — device only. Simplest. Nothing leaves the machine. Accept that
history dies with the device.

**Redirected** — put the state on a path you control:

```powershell
./scripts/New-ClaudeCodePolicy.ps1 -GatewayUrl <url> `
    -ConversationStorage redirected `
    -ConfigDir 'H:\ClaudeState'
```

`CLAUDE_CONFIG_DIR` moves settings, session history and plugins wholesale, so
they roam and are backed up with the rest of the profile.

> **Do not point this at a continuously syncing client** such as OneDrive on
> the same folder. Transcripts are written while Claude Code is running, and a
> sync client that copies a file mid-write produces a corrupt transcript rather
> than a backup. Folder redirection to a share, Azure Files, or an FSLogix
> container is the right shape.

Claude Desktop's profile lives in `%LOCALAPPDATA%\Claude-3p`, which is
LevelDB-backed and has the same constraint. FSLogix is the sane way to roam it.

**Audited** — keep the local working copy, and export to your own collector for
retention, chargeback and eDiscovery:

```powershell
./scripts/New-ClaudeCodePolicy.ps1 -GatewayUrl <url> `
    -ConversationStorage audited `
    -OtlpEndpoint 'https://otel.contoso.internal:4317'
```

Both clients support this, under different names, and both default to metadata
only:

| | Claude Code | Claude Desktop |
|---|---|---|
| Endpoint | `OTEL_EXPORTER_OTLP_ENDPOINT` | `otlpEndpoint` |
| Auth | `OTEL_EXPORTER_OTLP_HEADERS` | `otlpAuthMode`, `otlpHeaders` |
| Content | `OTEL_LOG_USER_PROMPTS`, `OTEL_LOG_ASSISTANT_RESPONSES` | `otlpContentCapture` |

Claude Desktop's `otlpContentCapture` takes categories: `userPrompts`,
`assistantResponses`, `toolDetails`, `toolContent`, `rawApiBodies`. Anthropic's
documentation is explicit that this content goes to your collector and **never
reaches Anthropic**.

`otlpAuthMode: inference-credential` reuses the Entra token the app already
holds for Foundry, so there is no second secret to deploy — the collector just
has to accept that audience.

> Content capture is off by default in both clients, and `-CaptureContent` is a
> separate switch here for the same reason. Turning it on exports what people
> typed and what the model replied. That is a change in what the organisation
> collects: it belongs in a privacy review, and in most jurisdictions the
> people affected have to be told.

Most organisations end up with **redirected + audited**: redirection for
continuity, telemetry for the compliance record. The gateway already gives you
token counts per person for chargeback without any of this — see
[MONITORING.md](MONITORING.md).

---

## 2. Mass deployment through MDM

Both clients are designed for this. Managed settings sit above every other
level: no user, project, local or `--settings` value overrides them.

### Generate the policy

```powershell
# Claude Code - CLI, VS Code and JetBrains extensions, and Desktop's Code tab
./scripts/New-ClaudeCodePolicy.ps1 -ConfigPath ./onboarding/claude-gateway.json

# Claude Desktop - Chat and Cowork
#   github.com/naveenneog/claude-desktop-foundry
./scripts/New-DesktopPolicy.ps1 -Mode GatewayHelper -GatewayBaseUrl <url>
```

Each emits `managed-settings.json`, a `.reg`, an Intune OMA-URI CSV, a
`.mobileconfig`, and an apply script for piloting.

### Where each mechanism stores the policy

| | Claude Code | Claude Desktop |
|---|---|---|
| Windows MDM | `HKLM\SOFTWARE\Policies\ClaudeCode`, `REG_SZ` named `Settings` holding the JSON | `HKLM\SOFTWARE\Policies\Claude`, one value per key |
| Windows file | `C:\Program Files\ClaudeCode\managed-settings.json` | — |
| macOS | `com.anthropic.claudecode` managed preferences | `/Library/Managed Preferences/<user>/com.anthropic.claudefordesktop.plist` |
| Linux | `/etc/claude-code/managed-settings.json` | `/etc/claude-desktop/managed-settings.json` |

> `C:\ProgramData\ClaudeCode\managed-settings.json` is a **legacy path that is
> no longer read**. It is the natural place to guess, which is what makes it
> worth stating.

### Three traps

**Server-managed settings from the claude.ai console do not apply to you.**
Claude Code fetches that source only when the session authenticates to
Anthropic's API directly. Pointing it at your own gateway makes it skip
straight to MDM. For this deployment the console is not a lever; MDM or the
file is.

**The default is first-wins, not merge.** When several managed sources reach
one machine, the highest-ranked source that supplies *any* policy key wins
outright and the rest are ignored, silently. The order is:

```
remote  >  MDM / HKLM  >  managed-settings.json  >  HKCU
```

Ship both a `.reg` and a `.json` and the `.reg` wins — the file is not merged
in, it is discarded. Set `managedSourcesBehavior: "merge"` if you want them
combined (Claude Code v2.1.242+).

**Cowork does not always see device policy.** Cowork sessions run on Claude
Code and normally read the device's MDM policy — but not when your Desktop
configuration sets `requireCoworkFullVmSandbox`, because the VM has no device
policy to read, and not for remote Cowork sessions on Anthropic-managed VMs. If
you enforce the full VM sandbox, Cowork will not pick up the gateway
configuration from MDM.

### Installing the binaries

| Platform | Method |
|---|---|
| Windows | `winget install Anthropic.ClaudeCode`, or the native installer script |
| macOS | `brew install --cask claude-code`, or the native installer |
| Linux | apt, dnf, apk, or the native installer |

No MSI is documented. WinGet and Homebrew do not auto-update; the native
installer does. For a locked-down fleet that is usually the point.

### Per-group policy

One MDM profile applies to everyone it reaches, so different tiers need
different profiles — which is straightforward in Intune or Jamf with group
assignment. A self-hosted Claude apps gateway can deliver managed settings per
IdP group, if you would rather not manage two profiles.

### Verify it landed

Run `/status` inside Claude Code. The `Setting sources` line names the source
that applied *and* the ones it skipped — which is how you catch the first-wins
trap. Then confirm traffic is actually going through the gateway: responses
carry `x-governed-by`, and the call appears in Application Insights.

---

## 3. Bulk entitlement from a CSV or an Entra group

Entitlement is Entra group membership. Filling those groups is the migration.

```powershell
# From a roster exported from wherever the population currently lives
./scripts/Import-ClaudeEntitlement.ps1 -Csv .\c4e-roster.csv -ReportPath .\result.csv -WhatIf

# Or from a group that already holds them, including nested groups
./scripts/Import-ClaudeEntitlement.ps1 -FromGroup 'ai-c4e-members' -Tier standard

# Then push membership to the gateway
./scripts/Sync-ClaudeAccess.ps1 -ApimName <apim> -ResourceGroup <rg>
```

The script is idempotent, so re-running it after the roster changes adds only
what is new. It collapses duplicates, and when someone appears in both tiers
premium wins — matching how the gateway policy resolves a dual member.

### The part that actually costs you time

Not the import. Identity resolution.

A person can exist in the directory under several different strings, and the
one a colleague typed into a spreadsheet is often none of them. From the tenant
this was built against — a single real account:

```
userPrincipalName   navg_microsoft.com#EXT#@fdpo.onmicrosoft.com
mail                naveen.g@microsoft.com
otherMails          nag@microsoft.com
```

Three addresses, and the one that person actually signs in with —
`navg@microsoft.com` — appears on none of them. Their `userType` is `Member`
despite the `#EXT#` form, so filtering on `userType` would not have caught it
either. A naive `az ad user show --id <email>` returns nothing for all four
variants, and a naive importer would silently drop them.

So each identifier is tried four ways, in order:

1. as a UPN or object id, directly
2. `mail eq`
3. `otherMails/any` (needs the `ConsistencyLevel: eventual` header and `$count`)
4. the guest form — `local_domain.com#EXT#@<each verified tenant domain>`

In the test tenant, **every** user resolved only via steps 2–4. None would have
been found by step 1 alone.

Anything still unresolved is reported, never skipped quietly. `-ReportPath`
writes a per-row CSV — input, what it resolved to, which method matched, and
the outcome — which is the artefact you hand back to whoever owns the roster.
The report is written even under `-WhatIf`, because a dry run is exactly when
you want it.

### Suggested sequence

1. `-WhatIf -ReportPath` and send the not-found rows back for correction
2. Repeat until the unresolved list is empty or explained
3. Run for real; it is idempotent
4. Run `Sync-ClaudeAccess.ps1`
5. Spot-check: a member gets `200`, a non-member gets `403`

### Keeping it in sync afterwards

The import is for the migration. Afterwards, membership changes come from
joiner/mover/leaver, and `Sync-ClaudeAccess.ps1` on a schedule pushes them to
the gateway. Removal takes effect at the next sync — or immediately if the
account is disabled, since token acquisition fails at that moment.

---

## 4. Cutover runbook

**Export first, before anything is deleted.** On Team or Enterprise this is the
Primary Owner, from Organization settings → Data and privacy. Do it at the
*start* of the migration: anything already removed by a retention policy will
not be in the archive. Ask people to run the memory export prompt in the same
window, while their account is still live.

**Pilot — one team, two weeks.** Deploy the gateway, entitle the team, push MDM
to their machines only. Confirm `/status` shows the managed source, traffic
carries `x-governed-by`, and budgets appear in Application Insights. Have them
use Desktop specifically, so the empty-history reality is discovered by
volunteers rather than by everyone at once.

**Dual-run.** Leave first-party accounts live while both are configured. This
is what makes the Desktop history gap survivable: people still have their old
conversations to refer back to. Tell them the window and when it closes.

**Land the memory.** Run `Import-ClaudeMemory.ps1` for anyone who exported, or
publish a shared `-Scope managed` CLAUDE.md for the house standards. Cowork
picks up the same file.

**Cut over.** Push MDM fleet-wide. Run the bulk import for the full population.
Sync. Watch Application Insights for `403`s — that is your list of people the
roster missed.

**Decommission.** Deprovision first-party accounts only after the export window
has closed and the archive has been verified as readable. Then check the
direct-access bypass: anyone holding `Cognitive Services User` on the Foundry
account directly can skip the gateway and every budget with it.
[SETUP.md §4.2](SETUP.md) has the audit commands.

---

## What is still genuinely unknown

Short list, stated plainly, because a migration plan built on a guess is worse
than one with a known gap:

- **Whether Projects and Artifacts are included in the data export.** The
  export article does not enumerate its contents beyond messages, files and
  projects being subject to the deletion caveat. Open one archive during the
  pilot and look, rather than assuming either way.
- **Accepted values for `forceLoginMethod`.** It restricts login to claude.ai,
  the Console, or a gateway, and would stop someone signing in to a personal
  account — but the exact enum was not confirmed, so the generated policy does
  not set it. See
  [the settings reference](https://code.claude.com/docs/en/settings-reference).
