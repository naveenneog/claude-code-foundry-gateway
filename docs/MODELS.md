# Adding a model

A new Claude model appearing in Foundry is routine. Making it usable takes one
command.

```powershell
./scripts/Add-ClaudeModel.ps1 -Model claude-opus-5 -Tier premium `
    -InputPerMillion 5 -OutputPerMillion 25 `
    -ResourceGroup <rg> -ApimName <apim>
```

That checks the model is deployed, adds it to the tier's allow list, writes its
price so usage is charged, and prints what developers have to change.

To see where things stand first:

```powershell
./scripts/Add-ClaudeModel.ps1 -List -ResourceGroup <rg> -ApimName <apim>
```

```
  Model                      Deployed   Priced             In/M        Out/M
  claude-haiku-4.5           no         yes                  $1           $5
  claude-opus-5              yes        yes                  $5          $25
                             tiers: premium
  claude-sonnet-5            yes        yes                  $2          $10
                             tiers: standard, premium
```

Only Claude deployments are listed. The reference account also carries GPT,
Sora and embedding deployments; this gateway does not front them, so showing
them as unpriced would be true and useless.

---

## The four things that have to agree

| | Where it lives | What happens if it is missed |
|---|---|---|
| **Deployed** | The Foundry account | The gateway forwards and Foundry refuses |
| **Allowed** | `models-standard` / `models-premium` named values | The gateway refuses with 403 before Foundry sees it |
| **Priced** | `config/price-book.json` | Served, and reported at **$0** |
| **Selectable** | `availableModels` in managed settings, if you pin it | The client hides a model the gateway would serve |

The third is the one that fails quietly. A model with no price still works, and
its usage lands in reports as nothing, which reads as nobody using it rather
than as a configuration gap. `-List` marks it in red, and the command refuses to
add an unpriced model unless you pass `-SkipPrice`.

A model that is not deployed is refused outright, and the error names what *is*
deployed:

```
'claude-opus-9' is not deployed on Foundry account 'ai-contoso'.
Deployed: claude-opus-5, claude-sonnet-5. Pass -Deploy to create it now, or
-SkipDeploymentCheck if you are staging configuration ahead of the deployment.
```

`-Deploy` creates the Foundry deployment as part of the same command. A quota
refusal is reported as quota rather than as a generic failure, because the
answer to one is a quota request and not a retry.

---

## The price book

To use your own rates, copy the example and edit it:

```powershell
Copy-Item config/price-book.example.json config/price-book.json
```

With no such file, built-in list rates apply, so a fresh clone works. Prices are
**US dollars per million tokens**:

```json
{
  "date": "2026-09-16",
  "source": "list price, https://platform.claude.com/docs/en/about-claude/pricing",
  "models": {
    "claude-sonnet-5": { "inputPerM": 2.0, "outputPerM": 10.0 }
  }
}
```

Only base input and output are stored. For Anthropic prompt caching, reusing
cached input costs 0.1x the base input rate, writing to a five-minute cache
costs 1.25x, and writing to a one-hour cache costs 2x — so the three cache rates
are derived rather than stored.

`config/price-book.json` is **not** in the repository, because it may hold your
negotiated rates rather than list price, and a negotiated schedule is
commercially sensitive. `config/price-book.example.json` ships instead.

A malformed price book raises an error; the script does not quietly fall back to
built-in rates. See [ADR-0010](adr/0010-financial-semantics.md) for how a dollar
figure here is calculated and what it does and does not mean.

---

## What developers change

The model name, and nothing else:

```bash
claude --model claude-opus-5
```

Their gateway URL, token and settings are unchanged. If your managed settings
pin `availableModels`, regenerate that profile too — otherwise the client hides
a model the gateway is willing to serve, which presents as the model missing:

```powershell
./scripts/New-ClaudeCodePolicy.ps1 -GatewayUrl <url> -Tier premium `
    -AvailableModels claude-opus-5, claude-sonnet-5
```

---

## Retiring one

```powershell
./scripts/Add-ClaudeModel.ps1 -Model claude-opus-4.8 -Remove -Tier both `
    -ResourceGroup <rg> -ApimName <apim>
```

That takes it out of both tier allow lists and reports what is left. The list
keeps its sentinel commas, so `,claude-opus-5,claude-opus-4.8,` becomes
`,claude-opus-5,` and an emptied list becomes `,,`.

Its price-book entry stays, and that is deliberate: reports over past months
still need the rate that applied then, and
[ADR-0010](adr/0010-financial-semantics.md) prices each request from the book in
force at the time rather than today's.

If your managed settings pin `availableModels`, regenerate and redistribute that
profile too, or the client will keep offering a model the gateway now refuses.
