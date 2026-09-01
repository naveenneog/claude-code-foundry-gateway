# Migrating a large organisation from first-party Claude to Foundry

Four requirements, treated separately, because they have genuinely different
answers and different owners:

| # | Requirement | Short answer |
|---|---|---|
| [1](#1-history-memory-and-sessions) | Keep chat history, memory and sessions intact | **All of it migrates — Desktop chats, Cowork and Code sessions, projects and memory — through an import wizard that is off by default at both ends. Attachments are the exception.** |
| [2](#2-mass-deployment-through-mdm) | Bulk install and push user-level config via MDM | Fully supported. Managed settings override every user-level value. |
| [3](#3-bulk-entitlement-from-a-csv-or-an-entra-group) | Bulk migration from C4E, CSV or Entra groups | `Import-ClaudeEntitlement.ps1`. Budget effort for identity resolution, not for the import. |
| [4](#4-cutover-runbook) | How to actually run it | Switch on import, export, pilot, dual-run, cut over, decommission. |

Every claim below was checked against Anthropic's documentation or against a
live deployment. Where something is genuinely undocumented it says so rather
than guessing.

---

## 1. History, memory and sessions

### What survives

**Everything except attachments — but the import that moves it is off by
default at both ends.** The work is switching it on before people cut over, not
recovering data afterwards.

| Artefact | Survives? | What you do |
|---|---|---|
| Claude Code transcripts, prompt history, settings | Yes | Nothing. Local and provider-independent |
| CLAUDE.md memory, `rules/`, auto memory | Yes | Nothing |
| **Cowork memory** | Yes | Nothing — Cowork runs on Claude Code and reads the same files |
| MCP servers and plugins | Yes | Nothing |
| **Claude Desktop chats** | Via import | Switch on `claudeAiImport` **and** the claude.ai export toggle |
| **Cowork and Code sessions on the machine** | Via import | Same — or `automatic3pImport` for a silent fleet-wide copy |
| Claude.ai projects | Via import, as **Spaces** | Custom instructions are shown for review first |
| Claude.ai chat memory | Via import | It is included in the export |
| **Project knowledge files and attachments** | **No** | **The one real gap.** Only an org-level export has file contents |
| Terminal Claude Code sessions | n/a | They never left `~/.claude` — nothing to move |

### Why an import is needed at all

Nothing crosses between the two modes on its own. Anthropic's architecture
table for third-party mode:

| Component | Standard Claude Desktop | Claude Desktop on 3P |
|---|---|---|
| Web application | Loaded from claude.ai | Bundled inside the desktop app |
| User identity | Anthropic account | **Local device identity only** |
| Conversation storage | **Anthropic backend** | **Local disk on the user's machine** |

— [Claude Desktop on 3P: overview](https://claude.com/docs/third-party/claude-desktop/overview)

The two modes keep separate storage roots, each with its own IndexedDB, which
is observable on any machine that has run both:

```
%APPDATA%\Claude\                 first-party: Local Storage, IndexedDB, Session Storage
%LOCALAPPDATA%\Claude-3p\         Foundry mode: its own Local Storage and IndexedDB
```

So a user switched to Foundry sees an empty Desktop until the import runs.
That is why the switches below need to be on *before* they cut over, not after.

### How the import works

Claude Desktop on 3P ships an import wizard at **Settings → Import & export**.
It has three steps, and any can be skipped:

| Step | Brings across |
|------|---------------|
| **Chats** | claude.ai conversations and projects — sign in and fetch directly, or select a downloaded export `.zip` |
| **Cowork & Code** | **Cowork and Claude Code sessions already on this machine** from an earlier install, with a time-range selector |
| **Review** | Confirms, then copies into the local session store |

Imported projects become **Spaces**. Opening an imported conversation and
sending a message shows a **Resume imported session?** prompt — accept it and
the reply comes from your provider, not claude.ai.

Sessions are **copied, not moved**, and the import is a **one-time copy, not a
sync**. Re-running it matches existing imports and skips them, so it does not
duplicate — which makes "import again just before cutover" a safe step.

— [Import history from claude.ai](https://claude.com/docs/third-party/claude-desktop/import)

**Two switches, both off by default.** Neither end is enabled out of the box,
and both are administrator-controlled. This is the part that bites: a user who
tries to import before the switches are on is told import is not enabled for
this deployment, with no indication that it is a policy decision rather than a
missing feature.

**1. In your Desktop managed configuration**, set `claudeAiImport`:

| Field | Default | What it does |
|-------|---------|--------------|
| `enabled` | `false` | Turns on Settings → Import |
| `automatic3pImport` | `false` | **Beta.** Copies this machine's earlier third-party sessions in once, in the background. Independent of `enabled` — no user action at all |
| `exportEnabled` | `false` | Lets a user export this machine's chats, Cowork tasks and Code sessions as a zip another install can import. No effect unless `enabled` |
| `bannerBehavior` | unset | `detect` prompts only when earlier sessions are found, `show` always, `off` never |

For a fleet migration, `automatic3pImport` is the one that scales — it moves
local Cowork and Code sessions with nobody having to run a wizard.

**2. On claude.ai, for Team and Enterprise**, a workspace owner must turn on
**Settings → Organization → Data and privacy → Allow members to export their
own data**. It is off by default. It does not expose one member's data to
another; each person can still download only their own.

### The one real gap: attachments

**Project knowledge files and conversation attachments do not come across.**
A member's own export never includes the contents of files uploaded to a
project's knowledge base or attached to a conversation. Imported chats keep the
messages that *referenced* an attachment, but not the file.

This is a claude.ai security policy and it applies to both import paths —
signing in and selecting a downloaded zip. The only export that includes file
contents is the **organization-level export**, which only a workspace owner can
request.

So if a team has been treating a Claude project's knowledge base as a document
store, plan to move those files separately. That is the item to surface early,
not conversation history.

### Getting the claude.ai export

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

This archive is not just for the record: the `.zip` a member downloads is
exactly what **Choose file…** takes in the import wizard's first step. Signing
in to claude.ai from the wizard fetches the same thing without the round trip.

— [Export your organization's data](https://support.claude.com/en/articles/13346720-export-your-organization-s-data)
· [Export your Claude data](https://support.claude.com/en/articles/9450526-export-your-claude-data)

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

**3. Claude.ai chat memory — it is in the export.** Anthropic's import
documentation is explicit that an export contains "your own conversations,
projects, and memory", so the wizard is the primary route and it needs no
manual step.

There is still a reason to move it into `CLAUDE.md` as well: memory that lives
in a `CLAUDE.md` reaches Claude Code and Cowork, is reviewable in a text editor,
and can be version-controlled or deployed fleet-wide as a house standard.
Anthropic separately documents a **prompt-based export** — you ask Claude to
list everything it has stored about you and it returns a single code block —
which is exactly the right shape for that:

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

### An org-wide CLAUDE.md

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

— [Claude Code memory](https://code.claude.com/docs/en/memory)

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

— [Claude Code monitoring and OpenTelemetry](https://code.claude.com/docs/en/monitoring-usage)
· [Claude Code settings and `CLAUDE_CONFIG_DIR`](https://code.claude.com/docs/en/settings)
· [Cowork monitoring](https://claude.com/docs/cowork/monitoring)

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

— [Deploy managed settings](https://code.claude.com/docs/en/managed-settings)
· [Claude Desktop configuration reference](https://claude.com/docs/third-party/claude-desktop/configuration)
· [Deploy Claude Desktop with MDM](https://claude.com/docs/third-party/claude-desktop/mdm)

### Three traps

**Server-managed settings from the claude.ai console do not apply to you.**
Claude Code fetches that source only when the session authenticates to
Anthropic's API directly. Pointing it at your own gateway makes it skip
straight to MDM. For this deployment the console is not a lever; MDM or the
file is.
— [Server-managed settings](https://code.claude.com/docs/en/server-managed-settings)

**The default is first-wins, not merge.** When several managed sources reach
one machine, the highest-ranked source that supplies *any* policy key wins
outright and the rest are ignored, silently. The order is:

```
remote  >  MDM / HKLM  >  managed-settings.json  >  HKCU
```

Ship both a `.reg` and a `.json` and the `.reg` wins — the file is not merged
in, it is discarded. Set `managedSourcesBehavior: "merge"` if you want them
combined (Claude Code v2.1.242+).
— [How Claude Code combines managed sources](https://code.claude.com/docs/en/managed-settings)

**Cowork does not always see device policy.** Cowork sessions run on Claude
Code and normally read the device's MDM policy — but not when your Desktop
configuration sets `requireCoworkFullVmSandbox`, because the VM has no device
policy to read, and not for remote Cowork sessions on Anthropic-managed VMs. If
you enforce the full VM sandbox, Cowork will not pick up the gateway
configuration from MDM.
— [Cowork overview](https://claude.com/docs/cowork/overview)

### Installing the binaries

| Platform | Method |
|---|---|
| Windows | `winget install Anthropic.ClaudeCode`, or the native installer script |
| macOS | `brew install --cask claude-code`, or the native installer |
| Linux | apt, dnf, apk, or the native installer |

No MSI is documented. WinGet and Homebrew do not auto-update; the native
installer does. For a locked-down fleet that is usually the point.

— [Claude Code overview and install](https://code.claude.com/docs/en/overview)
· [MDM starter templates](https://github.com/anthropics/claude-code/tree/main/examples/mdm)

### Per-group policy

One MDM profile applies to everyone it reaches, so different tiers need
different profiles — which is straightforward in Intune or Jamf with group
assignment. A self-hosted Claude apps gateway can deliver managed settings per
IdP group, if you would rather not manage two profiles. A bootstrap server is
the Desktop equivalent for role-based configuration too complex for per-group
profiles.

— [Claude apps gateway](https://code.claude.com/docs/en/claude-apps-gateway)
· [Deploy Claude Desktop with a bootstrap server](https://claude.com/docs/third-party/claude-desktop/bootstrap)

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

**Turn on both import switches first.** `claudeAiImport.enabled` in the Desktop
managed configuration, and **Allow members to export their own data** on
claude.ai for Team and Enterprise. Both are off by default, and a user who hits
the wizard before they are on is simply told import is not enabled. Consider
`automatic3pImport` so local Cowork and Code sessions move with no user action.

**Deal with attachments separately.** Project knowledge files and conversation
attachments are the one thing the member-level export leaves behind. If any
team is using a project's knowledge base as a document store, get a workspace
owner to run the organisation-level export, which does include file contents,
and land those files wherever they should have been in the first place.

**Export the organisation archive before anything is deleted.** Primary Owner,
Organization settings → Data and privacy. Do it at the *start*: anything already
removed by a retention policy will not be in the archive.

**Pilot — one team, two weeks.** Deploy the gateway, entitle the team, push MDM
to their machines only. Confirm `/status` shows the managed source, traffic
carries `x-governed-by`, and budgets appear in Application Insights. Have them
run the import wizard and confirm their Cowork and Code sessions came across —
that is the step most likely to surprise you, so surface it with volunteers.

**Dual-run.** Leave first-party accounts live while both are configured. Import
is a one-time copy rather than a sync, so re-running it just before cutover
picks up anything created in the meantime, without duplicating what is already
there.

**Land the memory.** The wizard brings memory across. Optionally also run
`Import-ClaudeMemory.ps1`, or publish a shared `-Scope managed` CLAUDE.md for
house standards — Cowork reads the same file.

**Cut over.** Push MDM fleet-wide. Run the bulk import for the full population.
Sync. Watch Application Insights for `403`s — that is your list of people the
roster missed.

**Decommission.** Deprovision first-party accounts only after the import has
been verified on real machines and the archive has been confirmed readable.
Then check the direct-access bypass: anyone holding `Cognitive Services User`
on the Foundry account directly can skip the gateway and every budget with it.
[SETUP.md §4.2](SETUP.md) has the audit commands.

---

## What is still genuinely unknown

- **Accepted values for `forceLoginMethod`.** It restricts login to claude.ai,
  the Console, or a gateway, and would stop someone signing in to a personal
  account — but the exact enum was not confirmed, so the generated policy does
  not set it. See
  [the settings reference](https://code.claude.com/docs/en/settings-reference).

---

## Anthropic references

Everything above is grounded in these. Worth checking them directly before a
cutover date: Claude Desktop on 3P is moving quickly, and the support site
recently moved from `support.anthropic.com` to `support.claude.com`, so older
links 404 rather than redirect.

**Migrating the data**

- [Import history from claude.ai](https://claude.com/docs/third-party/claude-desktop/import) — the wizard, what it carries, and what it leaves behind
- [Export your organization's data](https://support.claude.com/en/articles/13346720-export-your-organization-s-data) — Primary Owner, Team and Enterprise
- [Export your Claude data](https://support.claude.com/en/articles/9450526-export-your-claude-data) — individual plans
- [Import and export your memory](https://support.claude.com/en/articles/12123587-import-and-export-your-memory-from-claude) — the prompt-based memory export

**Claude Desktop on third-party**

- [Overview](https://claude.com/docs/third-party/claude-desktop/overview) — architecture, and the storage change that underlies all of this
- [Configuration reference](https://claude.com/docs/third-party/claude-desktop/configuration) — every managed key, including `claudeAiImport` and `otlpContentCapture`
- [Deploy with MDM](https://claude.com/docs/third-party/claude-desktop/mdm) · [Deploy with a bootstrap server](https://claude.com/docs/third-party/claude-desktop/bootstrap)
- [Deploy on Microsoft Foundry](https://claude.com/docs/third-party/claude-desktop/foundry)
- [Write a credential helper](https://claude.com/docs/third-party/claude-desktop/credential-helper)
- [Feature matrix vs Claude Enterprise](https://claude.com/docs/third-party/claude-desktop/feature-matrix)

**Claude Code**

- [Claude Code on Microsoft Foundry](https://code.claude.com/docs/en/microsoft-foundry) — `CLAUDE_CODE_USE_FOUNDRY` and Entra auth
- [Deploy managed settings](https://code.claude.com/docs/en/managed-settings) — delivery mechanisms, precedence, first-wins
- [Settings](https://code.claude.com/docs/en/settings) · [Settings reference](https://code.claude.com/docs/en/settings-reference)
- [Memory](https://code.claude.com/docs/en/memory) — CLAUDE.md scopes, auto memory, Cowork behaviour
- [Sessions](https://code.claude.com/docs/en/sessions) — where transcripts live and how long they are kept
- [Connect to an LLM gateway](https://code.claude.com/docs/en/llm-gateway-connect)
- [Monitoring and OpenTelemetry](https://code.claude.com/docs/en/monitoring-usage)
- [Feature availability by provider](https://code.claude.com/docs/en/feature-availability)
- [MDM starter templates](https://github.com/anthropics/claude-code/tree/main/examples/mdm) — Jamf, Intune, Group Policy

**Cowork**

- [Overview](https://claude.com/docs/cowork/overview) · [Monitoring](https://claude.com/docs/cowork/monitoring)
