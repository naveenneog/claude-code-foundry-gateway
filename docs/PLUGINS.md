# Plugins, marketplaces and extensions

A plugin is code that runs with the developer's own permissions. It can add
tools, skills, hooks and MCP servers to a session. A marketplace is where
plugins are installed from.

Left alone, a developer may add any marketplace and install anything in it. This
page is how to narrow that, and — importantly — what these controls do not do.

## Prerequisites

- An approved plugin repository and review owner. Plugins execute with the
  developer's permissions; approve their tools/network access separately.
- The gateway URL and selected tier from the platform owner.
- PowerShell to generate files; device/MDM administration rights to deploy
  machine policy (Intune/Jamf/GPO). This is not a Foundry RBAC operation.
- A test device with the installed client versions and a saved prior policy.
  Run generator commands from the repository root.

## Generate the profiles

```powershell
./scripts/New-ClaudeCodePolicy.ps1 -GatewayUrl <url> -Tier premium `
    -Marketplace 'contoso/approved-plugins' `
    -BlockUserPlugins -RequireSignedExtensions
```

That writes both profiles: `claude-code.*` for Claude Code, and
`claude-desktop.*` for Claude Desktop. They use different key names for the same
idea, which is why one command emits both rather than leaving you to keep two
files in step.

**Manual/device-management path:** use the keys in the next table in the
existing approved profile. Intune admin center > Devices > Configuration >
your approved Windows/macOS profile, Jamf configuration profiles, or Group
Policy delivers the settings to the stores below. Azure portal itself does not
manage these client files. Do not deploy both file and registry policies
without understanding first-wins precedence in
[Migration](MIGRATION.md#2-mass-deployment-through-mdm).

---

## What each switch sets

| Switch | Claude Code | Claude Desktop |
|---|---|---|
| `-Marketplace owner/repo` | `strictKnownMarketplaces` | `allowedPluginMarketplaces` |
| `-BlockUserPlugins` | — | `userPluginMarketplacesEnabled: false`, `userPluginUploadsEnabled: false`, `disableDeploymentModeChooser: true` |
| `-RequireSignedExtensions` | — | `isDesktopExtensionSignatureRequired: true` |

`-Marketplace` takes `owner/repo` — the same string you would type into
`/plugin marketplace add`. Anything else is refused at generation time rather
than producing a profile that silently matches nothing.

`disableDeploymentModeChooser` comes with `-BlockUserPlugins` because the two
plugin keys apply only while the app runs in third-party mode. Without it a user
can sign in to claude.ai and leave the policy behind.

---

## What these controls are not

**They are feature-availability controls, not data boundaries.** Anthropic
states that marketplaces already registered on a machine — including any
registered outside the app, for example by the Claude Code CLI or by editing
Claude Code's plugin files — are not removed or blocked by
`userPluginMarketplacesEnabled`.

So `-BlockUserPlugins` hides the routes in. It does not revoke what is already
there. `strictKnownMarketplaces` is the one that constrains what loads.

This sits under the same limit as every other client-side setting here:
Anthropic states that a user who can run a modified Claude Code binary can
bypass any client-side control. The controls that must hold — entitlement,
budgets and the model allowlist — are enforced at the gateway instead, which is
[ADR-0004](adr/0004-policy-out-of-band.md).

Treat the plugin settings as a way to make the approved path the easy one, not
as something that stops a determined user.

---

## Where the policy goes

Claude Code and Claude Desktop read different stores. The generated files map
onto them:

| File | Deploy to |
|---|---|
| `claude-code.managed-settings.json` | `C:\Program Files\ClaudeCode\` · `/Library/Application Support/ClaudeCode/` · `/etc/claude-code/` |
| `claude-code.reg` | `HKLM\SOFTWARE\Policies\ClaudeCode` |
| `claude-code.mobileconfig` | macOS, `com.anthropic.claudecode` |
| `claude-desktop.managed-settings.json` | `/etc/claude-desktop/managed-settings.json` |
| `claude-desktop.reg` | `HKLM\SOFTWARE\Policies\Claude` |

Three details that cause silent failures, all from the
[configuration reference](https://claude.com/docs/third-party/claude-desktop/configuration):

- **Desktop values are strings**, including booleans and arrays. Arrays and
  objects are a JSON document encoded into one string. The generated `.reg`
  does this; hand-editing usually does not.
- **Desktop reads no subkeys.** Values sit directly under
  `HKLM\SOFTWARE\Policies\Claude`. A value nested one level down is invisible.
- **The Linux file must be root-owned** and not group- or world-writable, and
  `/etc/claude-desktop` must be too. A file failing that check is rejected
  entirely — and local settings are disabled as well, so the app ends up with
  neither.

Desktop reads its configuration **at launch**. Quit and reopen after deploying;
a running app notices a changed managed configuration at its next re-check
(10 minutes by default) and then asks for a restart.

---

## Checking it applied

**Claude Code.** Open an interactive session and type `/status`. The
`Setting sources` line names the source in force — `Enterprise managed settings
(file)` for the JSON file. If no managed source is listed, the policy is not
being read: usually the wrong directory, or another managed source winning.
Claude Code uses **one** managed source by default rather than merging them, so
deploying the file *and* the registry key means one of them is ignored.

**Claude Desktop.** Quit and reopen the app — configuration is read at launch.
With `-BlockUserPlugins`, the add-marketplace and upload routes are hidden in
the plugin browser. On Linux a rejected `managed-settings.json` is logged to
`main.log` in the app's logs directory (`~/.config/Claude/logs/`, or
`~/.config/Claude-3p/logs/` in third-party mode); search it for
`managed-settings.json`, which also names any key that failed schema validation.

---

## Running your own marketplace

A marketplace is a GitHub repository with a catalog file at
`.claude-plugin/marketplace.json` listing the plugins it offers:

```json
{
  "name": "approved-plugins",
  "owner": { "name": "Contoso Platform Team" },
  "plugins": [
    { "name": "code-formatter", "source": "./plugins/code-formatter" }
  ]
}
```

Create it, then pass the repository as `-Marketplace 'owner/repo'` — the same
string you would type into `/plugin marketplace add`. The
[marketplace documentation](https://code.claude.com/docs/en/plugin-marketplaces)
has the full schema.

Pointing the allowlist at a repository you control is what makes it useful: the
review of what goes in is yours, and the allowlist then pins Claude to it.

This accelerator does not publish a marketplace or review a plugin. Those are
decisions about what your organisation trusts, and this page does not make them
for you.

## Verify the trust controls, not just the UI

On an isolated test device, test the approved plugin, an unapproved marketplace,
and an intentionally modified hash-pinned package. Where signed Desktop
extensions are required, test an approved signed bundle and an unsigned one.
Do not mark this complete merely because a generated key exists.

The recorded P14 client acceptance remains open ([Roadmap](ROADMAP.md)):
the configuration generator ships, but this repository does not claim those
real-client install/refusal tests have all passed. Claude Code plugins do not
have a publisher-signing scheme; pin supported content to a commit/hash and
review updates. Desktop `.mcpb` signing is a different mechanism.

## Troubleshoot and next steps

| Symptom | Check |
|---|---|
| No managed source in `/status` | Target path, file permissions and source precedence |
| Plugin still visible after blocking additions | Existing registrations are not removed by the add/upload UI switches |
| Desktop setting ignored | String encoding, direct registry key placement and full restart |

[Migration](MIGRATION.md) covers fleet delivery; [Network](NETWORK.md) covers
client egress, with extra plugin/MCP destinations requiring separate review.
