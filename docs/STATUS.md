# Status

**Active packet:** P-0 — adopt Ironclad. Ledger and gate in place; no parity code started.

## What is shipped (M0)

| | |
|---|---|
| Gateway | API Management Basic v2, `llm-token-limit` per tier keyed on Entra `oid` |
| Clients | Claude Code CLI, VS Code extension, Claude Desktop including Cowork |
| Entitlement | Entra group membership synced to APIM named values |
| Deployment | `Install-ClaudeGateway.ps1`, reuses an existing v2 instance rather than creating a second |
| Fleet | Managed settings for Claude Code and Claude Desktop, with Intune, GPO and Jamf payloads |
| Migration | Import from claude.ai, bulk entitlement from CSV or an Entra group |

## P-0 acceptance criteria

- [x] `.ironclad/charter.json` declares commands, budgets and one architecture boundary
- [x] `.ironclad/gate.mjs` vendored from the sibling repository, unmodified
- [x] Ledger present: CHARTER, ROADMAP, STATUS, UNKNOWNS, CHANGELOG, two ADRs
- [x] Tests relocated to `tests/` so the detector finds them honestly — see ADR-0001
- [x] `./tests/Test-All.ps1` passes from its new location
- [x] `node .ironclad/gate.mjs --stage packet` exits 0 — 23 passed, 1 warning (6 open unknowns), 0 failures

## Commands that prove it

```powershell
./tests/Test-All.ps1                          # 5 checks, offline
./tests/Test-All.ps1 -IncludeAzure            # plus the two that call Azure
node .ironclad/gate.mjs --stage packet        # definition of done
```

## Next

P10 — the analytics equivalent. ADR-0002 records the design; the packet is not started.

Before P11 begins, **U1** has to be closed: whether APIM supports a usable shared counter
across principals decides whether the org-wide spend ceiling sits in the request path or in a
scheduled job. That question is answered by deploying both shapes and measuring, not by reading
the policy reference.
