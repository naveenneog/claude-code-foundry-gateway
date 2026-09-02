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

| Named value | Meaning | Shipped default |
|-------------|---------|----------------:|
| `tpm-standard` | tokens/minute, standard | 20,000 |
| `tpm-premium` | tokens/minute, premium | 80,000 |
| `quota-standard` | tokens/day, standard | 500,000 |
| `quota-premium` | tokens/day, premium | 5,000,000 |
| `quota-org` | tokens/month, everyone combined | 100,000,000 |

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

```bash
az ad group member remove --group claude-code-standard --member-id <oid>
```

```powershell
./scripts/Sync-ClaudeAccess.ps1 -ApimName <apim> -ResourceGroup <rg>
```

The next request returns `403`. There is no credential to rotate and nothing to
collect from the developer's machine, because none was ever issued.

**When someone leaves the company** their Entra account is disabled and token
acquisition fails immediately — access is revoked at that moment, ahead of any
sync. Run the sync anyway to keep the allowlists clean.

> **Also check the bypass.** Removing someone from the group does nothing if they
> hold `Cognitive Services User` directly on the Foundry account. See
> [Setup §4.2](SETUP.md#42-close-the-bypass--do-not-skip-this).

---

## 6. Offboarding checklist

- [ ] Removed from both `claude-code-*` groups
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
