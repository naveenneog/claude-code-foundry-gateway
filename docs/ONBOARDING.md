# Onboarding guide — granting, changing, and revoking access

**For the platform team.** Everything here needs Entra rights; none of it is
the developer's job.

What the developer does is one command on their own machine, with no Azure
rights at all — that is **[DEVELOPER.md](../DEVELOPER.md)**, and handing them
that link is step 5 below.

Prerequisites and roles are in the [Setup guide](SETUP.md#2-permissions-and-roles).

---

## How entitlement actually works

Understanding this makes every operation below obvious.

```
Entra group  ──(Sync-ClaudeAccess.ps1)──▶  APIM named value  ──▶  policy check
claude-code-standard                        allow-standard         oid in list?
claude-code-premium                         allow-premium
```

The policy compares the `oid` claim in the caller's token against the
`allow-standard` and `allow-premium` named values. Those are **flat lists of
object ids**, not group references — the gateway never calls Graph at request
time.

Three consequences:

1. Group membership is not live. **A change takes effect when the sync runs**, not
   when you click Add member.
2. `allow-premium` is evaluated first. Someone in both groups gets premium.
3. Object ids, not UPNs. Renaming a user changes nothing; deleting and recreating
   the account breaks their access.

---

## 1. Add a developer

One command. It edits the **Entra group**, because that is the durable change —
`Sync-ClaudeAccess.ps1` rebuilds `allow-standard` and `allow-premium` from group
membership every time it runs, so a developer added straight to a named value
works until the next sync and then silently stops.

```powershell
./scripts/Set-ClaudeDeveloper.ps1 -User amara@contoso.com -Tier standard -Sync
./scripts/Set-ClaudeDeveloper.ps1 -User amara@contoso.com -Tier premium -BusinessUnit mcaps -Sync
./scripts/Set-ClaudeDeveloper.ps1 -User amara@contoso.com -Remove -Sync
```

`-Sync` publishes to the gateway as well. Without it the change is in the
directory but not yet at the gateway, and the script says so rather than
implying it is done.

Moving someone between tiers removes them from the one they left. Leaving them
in both is not an error — the policy checks premium first — but it makes the
lists unreadable and the applied tier hard to predict from the portal.

`-Remove` clears **every** business unit as well as both tiers. Removing
entitlement but leaving someone in a business unit group leaves a member on a
budget who can no longer call the gateway, which reads as a team that has
stopped working rather than an offboarding that was only half done.

Guests work by the address you invited them with. A guest's UPN is not their
email — in this tenant `amara@contoso.com` is stored as
`amara_contoso.com#EXT#@tenant.onmicrosoft.com` — and the script tries the
object id, the mail attribute and the UPN in turn.

The sections below cover the same job done by hand, and the portal walkthrough.

## 1a. Add a developer by hand

### Step 1 — find their object id

```bash
az ad user show --id developer@contoso.com --query "{name:displayName, oid:id}" -o table
```

Guests are listed under their **home** address in some tenants and their invited
address in others. If the lookup fails:

```bash
az ad user list --filter "startswith(mail,'developer')" \
  --query "[].{name:displayName, upn:userPrincipalName, mail:mail, oid:id}" -o table
```

For a service principal or CI identity:

```bash
az ad sp show --id <app-id> --query "{name:displayName, oid:id}" -o table
```

### Step 2 — add them to the tier group

Portal: **Entra ID → Groups → `claude-code-standard` → Members → Add members**

CLI:

```bash
az ad group member add --group claude-code-standard --member-id <object-id>
```

### Step 3 — push the change to the gateway

**This is the step people forget.** Until it runs, the developer gets `403`.

```powershell
./scripts/Sync-ClaudeAccess.ps1 -ApimName <apim> -ResourceGroup <rg>
```

Preview first if you want:

```powershell
./scripts/Sync-ClaudeAccess.ps1 -ApimName <apim> -ResourceGroup <rg> -WhatIf
```

The script prints each resolved identity and flags anyone in both groups.

> **Service principals** are not returned by a delegated token without
> `Application.Read.All`. Pass CI identities explicitly:
> `-AdditionalPremiumOids <oid>` or `-AdditionalStandardOids <oid>`.

> **Schedule it** if you want membership changes to apply without a person in the
> loop. A daily Azure Automation runbook or a scheduled pipeline is enough; the
> script is idempotent.

### Step 4 — verify

```bash
az apim nv show -g <rg> --service-name <apim> --named-value-id allow-standard --query value -o tsv
```

Their object id must appear. Then confirm end to end:

```powershell
./scripts/Show-Governance.ps1 -ApimName <apim> -ResourceGroup <rg>
```

### Step 5 — hand over the developer guide

Send the developer **[DEVELOPER.md](../DEVELOPER.md)**, plus
**`onboarding/claude-gateway.json`** — the file the wizard wrote when you
deployed. Their setup script reads the gateway URL, tenant and tier limits from
it, so they type none of them.

Or generate the whole handover — a formatted email with the config alongside it:

```powershell
./scripts/New-OnboardingEmail.ps1 `
    -ConfigPath ./onboarding/claude-gateway.json `
    -To developer@contoso.com -DisplayName 'Sam'
```

Writes HTML, plain text and an `.eml` you can open in Outlook and send. Add
`-Send` to try Microsoft Graph directly — that needs the `Mail.Send` delegated
permission, and falls back to the `.eml` cleanly when it is not granted.

![The onboarding email generator writing HTML, plain text and an .eml for a named developer](images/run-onboarding-email.png)

The config file carries **no secret**: the gateway URL, the tenant id and the
tier limits. All of it is information the developer needs, none of it grants
access. Access is group membership.

> Put `Setup-ClaudeWorkstation.ps1` and `claude-gateway.json` on a share or
> internal site and pass `-DistributionUrl`; the email then contains a
> two-line command that fetches and runs them.

---

## 2. UI walkthrough — adding a member in the portal

Two portals work. **Microsoft Entra admin center** (`entra.microsoft.com`) is
the current home for identity; the Azure portal blade is identical underneath.

### Get a direct link to the group

Skip the navigation entirely — generate the deep link once and bookmark it:

```powershell
$gid = az ad group show --group claude-code-standard --query id -o tsv
"https://entra.microsoft.com/#view/Microsoft_AAD_IAM/GroupDetailsMenuBlade/~/Members/groupId/$gid"
```

### Or navigate

1. **entra.microsoft.com** → **Groups** → **All groups**
2. Search `claude-code-` — both tier groups appear
3. Open **claude-code-standard**
4. Left nav → **Members** → **+ Add members**
5. Search by name or email, tick the person, **Select**
6. Confirm they now appear in the list

### Then run the sync — this is the step people miss

The portal grants *group membership*. The gateway reads an **allowlist of
object ids** that is refreshed by the sync, so until it runs the developer still
gets `403`:

```powershell
./scripts/Sync-ClaudeAccess.ps1 -ApimName <apim> -ResourceGroup <rg>
```

To check whether the gateway is already current, without reading two lists by
eye:

```powershell
./scripts/Compare-ClaudeEntitlement.ps1 -ApimName <apim> -ResourceGroup <rg>
```

It resolves every identity from both sides and exits non-zero when they
disagree. `missing` is someone added in the portal who will get `403` until the
sync runs; `stale` is someone removed who can still call the gateway.

> **Why there is no live lookup.** Resolving group membership at request time
> would need the gateway to hold the Graph `GroupMember.Read.All` application
> permission, which requires tenant admin consent. The sync approach needs no
> admin consent at all — the trade-off is that changes apply when it runs.
> Schedule it (Azure Automation, or a pipeline on a timer) if you want the
> portal to be the only step.

### Copying someone's object id from the portal

The allowlists key on **object id**, not UPN. If you want to verify a specific
person landed:

**Entra admin center → Users →** search them **→ Overview → Object ID** (there
is a copy button next to it). Then:

```powershell
az apim nv show -g <rg> --service-name <apim> --named-value-id allow-standard --query value -o tsv
```

Their id should be in that list.

### Delegating this without handing over Azure rights

Adding members needs group **Owner** or Groups Administrator — not any Azure
RBAC role. Make a team lead the **owner of the group** and they can entitle
people from the portal without any access to the gateway, the Foundry account,
or the subscription. Pair that with a scheduled sync and the platform team is
out of the loop entirely.

> Screenshots of these two blades are not shipped, because they show real
> directory membership. Capture them against your own tenant:
>
> ```powershell
> node guide/auth.mjs
> $env:STANDARD_GROUP_ID = (az ad group show --group claude-code-standard --query id -o tsv)
> node guide/capture.mjs c2-entra-groups c3-group-members
> ```
>
> See [guide/README.md](../guide/README.md).

---

## 3. Common variations

| Situation | What to do |
|-----------|-----------|
| Whole team at once | Loop `az ad group member add`, then sync once |
| Nested group | **Not supported.** The sync reads direct members only. Flatten it, or add each person |
| Contractor, time-boxed | Use an Entra **access package** or PIM-eligible membership so it expires on its own, then schedule the sync |
| CI/CD identity | Service principal in `claude-code-premium`, passed with `-AdditionalPremiumOids` |
| Someone needs it *now* | Add to group, run the sync immediately — the whole path is under a minute |

---

## 4. Change a developer's tier

Two different things get called "changing the tier". Be clear which one you mean.

### 4a. Move one person to a different tier

```bash
az ad group member remove --group claude-code-standard --member-id <oid>
az ad group member add    --group claude-code-premium  --member-id <oid>
```

```powershell
./scripts/Sync-ClaudeAccess.ps1 -ApimName <apim> -ResourceGroup <rg>
```

Verify from the developer's own response headers — the gateway reports the tier
it applied:

```
x-claude-tier: premium
x-ratelimit-remaining-tokens: 79980
```

> Leaving them in **both** groups is not an error and does not double their
> budget. `allow-premium` is checked first, so they get premium. Remove them from
> the standard group anyway, so the lists stay readable.

### 4b. Change what a tier *means*

This changes the budget for everyone in that tier. **No sync needed** — named
values are read on the next request.

`./scripts/Set-ClaudeTier.ps1` is the way to do it. It shows what is set now,
prints before-and-after for anything it changes, and checks a model allowlist
against what the Foundry account actually serves:

```powershell
./scripts/Set-ClaudeTier.ps1 -List
./scripts/Set-ClaudeTier.ps1 -Tier standard -DailyQuota 750000
./scripts/Set-ClaudeTier.ps1 -Tier premium -Models claude-opus-5,claude-sonnet-5
./scripts/Set-ClaudeTier.ps1 -Tier standard -Models ''        # back to all models
```

The model check matters because the failure it prevents is confusing: a tier
that allows a model the account does not serve refuses the caller with a model
name that looks correct. `-SkipModelCheck` overrides it for a deployment you are
about to create.

**There are two tiers, and no script can make a third.** The gateway policy
names `standard` and `premium` directly — resolving the tier from the allow
lists, checking the model, the per-minute limit, the daily quota and the refusal
message. A third tier is a policy change plus the named values to go with it,
not a configuration change.

These are the values behind it:

| Named value | Meaning | Shipped default |
|-------------|---------|----------------:|
| `tpm-standard` | tokens/minute, standard | 20,000 |
| `tpm-premium` | tokens/minute, premium | 80,000 |
| `quota-standard` | tokens/day, standard | 500,000 |
| `quota-premium` | tokens/day, premium | 5,000,000 |
| `quota-org` | tokens/month, everyone combined | 100,000,000 |
| `quota-overrides` | per-developer daily budgets, `,oid=tokens,` | empty |
| `models-standard` | models the standard tier may call, `,model,model,` | empty — all |
| `models-premium` | as above, for premium | empty — all |

The model allowlist is enforced **at the gateway**, before the request reaches
Foundry, so it holds regardless of what a client is configured to send. Every
other capability control — permission rules, hooks, Desktop tabs, MCP servers —
is delivered to clients and is a management control rather than a security
boundary: "a user who can run a modified Claude Code binary can bypass any
client-side control"
([reference](https://code.claude.com/docs/en/server-managed-settings), retrieved
2026-09-03). `docs/adr/0004-policy-out-of-band.md` records why the split falls
where it does.

`quota-overrides` is written by `./scripts/Set-ClaudeBudget.ps1`, not by hand.
It gives one person a different daily budget without moving them between tiers,
and applies on their next request. `./scripts/Get-ClaudeBudget.ps1` shows what
the gateway would actually apply to each developer, and what they have spent
this month.

`quota-org` is a single shared counter, so tier budgets sit underneath it. A
developer inside their own budget is still refused once the organisation's is
spent, and the reply says so — `"budget": "organisation"` rather than
`"personal"`. It is a soft cap: high-concurrency requests can temporarily exceed
it.

Portal: **APIM → APIs → Named values → select → edit Value → Save**

![APIM named values, with the per-minute, per-day and entitlement groups ringed](guide/a6-named-values.png)

CLI:

```bash
az apim nv update -g <rg> --service-name <apim> \
  --named-value-id tpm-standard --value 30000
```

Confirm:

```bash
az apim nv show -g <rg> --service-name <apim> \
  --named-value-id tpm-standard --query value -o tsv
```

> **The daily quota does not reset when you raise it.** `llm-token-limit` tracks
> consumption against the period that is already running. Someone who exhausted
> 500,000 today stays blocked until the period rolls over, even after you set it
> to 5,000,000. Move them to premium instead if they need unblocking now.

### 4c. Add a third tier

Add a named value pair (`tpm-<name>`, `quota-<name>`), an `allow-<name>` list, an
Entra group, and a branch in the policy's tier lookup. The policy structure is in
[ARCHITECTURE.md](ARCHITECTURE.md).

---

## 5. Revoke access

```powershell
./scripts/Set-ClaudeDeveloper.ps1 -User developer@contoso.com -Remove -Sync `
    -ApimName <apim> -ResourceGroup <rg>
```

`-Remove` takes them out of both tier groups and every business-unit group, so a
premium developer, or one who is in both tiers, is not left with access. `-Sync`
runs the sync straight after. Confirm the object id appears in neither
`allow-standard` nor `allow-premium` afterwards.

The next request returns `403`. There is no credential to rotate and nothing to
collect from the developer's machine, because none was ever issued.

**When someone leaves the company**, disable the Entra account as part of normal
offboarding — but do not treat that as the revocation. Disabling the account
stops them acquiring a *new* token; it does not invalidate one already issued.
The gateway checks the token's signature and claims with `validate-jwt`, which
does not call Entra per request, so an access token obtained shortly before the
account was disabled keeps working until it expires. Remove the group membership
and run the sync as well.

> **Also check the bypass.** Removing someone from the group does nothing if they
> hold `Cognitive Services User` directly on the Foundry account. See
> [Setup §4.2](SETUP.md#42-close-the-bypass).

---

## 6. Offboarding checklist

- [ ] Removed from both `claude-code-*` tier groups
- [ ] Removed from every business-unit and team group
- [ ] `Sync-ClaudeAccess.ps1` run, allowlists confirmed clean
- [ ] No direct `Cognitive Services User` on the Foundry account
- [ ] Usage exported from [Monitoring](MONITORING.md) if it is being charged back

---
---

# Part B — Developer

Moved to **[DEVELOPER.md](../DEVELOPER.md)**, at the root of the repository.

The developer setup is one command and needs no Azure rights, so it is a
separate page rather than the second half of this one.

Send them that link. Nothing else on this page applies to them.

## 7. Checking a machine before you promise a date

A developer who is in the right group, on the right tenant, with the right
role can still fail — because their machine sits behind a proxy that breaks
streaming, or carries a managed identity that Azure prefers to their sign-in.
Neither is visible from the portal, and both produce errors that name
something else.

`Onboard-ClaudeDeveloper.ps1` reads the file you hand out and checks the
machine against it. With `-PreflightOnly` it writes nothing, so it is safe to
run across a fleet before committing to a rollout.

```powershell
./scripts/Onboard-ClaudeDeveloper.ps1 -ConfigPath .\claude-gateway.json -PreflightOnly
```

![Onboard-ClaudeDeveloper.ps1 -PreflightOnly running four checks — tooling, identity, network and access — and reporting that nothing was written](guide/onboard-preflight.png)

Four checks, cheapest question first:

| # | Check | Catches |
|---|---|---|
| 1 | tooling | no Azure CLI, or a PowerShell that cannot run the rest |
| 2 | identity | not signed in, or signed in to a different tenant than the file names |
| 3 | network | a blocked host, and separately a proxy that cuts the response once it streams |
| 4 | access | a token that the model refuses, or a model name that is not a deployment |

> [!IMPORTANT]
> Nothing is written unless all four pass. That ordering is the whole point:
> the setup scripts configure correctly, and a correct configuration on a
> machine that cannot reach the endpoint still fails — at which point the
> evidence is a 401 or a hang, and the reconfiguration you try next is not the
> problem.

Without `-PreflightOnly` it checks, configures by delegating to the right
setup script for the file's mode, pins the credential chain if this machine
has a managed identity, and then verifies with the health check.

```powershell
./scripts/Onboard-ClaudeDeveloper.ps1 -ConfigPath .\claude-gateway.json
```

> [!TIP]
> It is safe to re-run. That is how a machine moves between the gateway and
> the direct path, and how a reissued file — a new gateway address, a
> different sign-in mode — gets picked up. Re-running with the same file
> changes nothing.

### What the file decides

Both paths use the same shape, distinguished by `mode`:

| Field | `gateway` | `foundry-direct` |
|---|---|---|
| `mode` | `gateway` | `foundry-direct` |
| target | `gatewayUrl` | `foundryResource` |
| `tenantId` | checked against the signed-in session | same |
| `authMode` / `auth` | `interactive`, `device` or `helper` | `interactive`, `device` or `current` |

> [!NOTE]
> A file written before `mode` existed still works — the mode is inferred from
> whether it carries `gatewayUrl` or `foundryResource`, and the inference is
> printed. Reissue the file to remove the warning.
