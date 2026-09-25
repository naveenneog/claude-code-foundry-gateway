# Batch portal capture specs

Put each packet's requirements in a separate `guide/captures/<packet>.json` file.
The runner loads **every JSON file**, plus its built-in gateway steps, and validates the
whole set before Azure discovery or opening a browser. IDs and output paths must be unique.

```json
{
  "version": 1,
  "steps": [
    {
      "id": "turnstile-app-overview",
      "output": "docs/guide/turnstile-entra-1-overview.png",
      "target": {
        "discover": "entra-app",
        "nameFilterEnv": "TURNSTILE_APP_DISPLAY_FILTER",
        "selectionKey": "turnstile-app"
      },
      "entraBlade": { "kind": "app-registration", "name": "Overview" },
      "waitFor": { "text": "Application (client) ID" },
      "settle": 1500,
      "redaction": { "mapEnv": "PORTAL_REDACTIONS_FILE" }
    }
  ]
}
```

The executable Turnstile example is [turnstile.json](turnstile.json).

Built-in capture catalogue:

| ID | Documented output | Surface |
|---|---|---|
| `gateway-overview` | `docs/guide/a3-apim-overview.png` | API Management Overview |
| `gateway-identity` | `docs/guide/a4-identity.png` | System-assigned identity |
| `gateway-named-values` | `docs/guide/a6-named-values.png` | Named values |

## Fields

- `id`: lower-case stable slug; used by `--only`.
- `output`: repository-relative PNG path, with `/` separators and no `..` or absolute path.
  A document must reference it. For a not-yet-taken image, an explicit inline code reference
  such as `docs/guide/planned-portal.png` marked “capture pending” is sufficient; do not add
  a broken image or pretend a placeholder is live.
- `target.discover`: `gateway`, `foundry`, `workspace`, `app-insights`, `vnet`, `key-vault`,
  `private-dns`, `workbook`, `resource`, `entra-app` or `entra-group`.
  No literal resource name, resource ID, tenant/subscription ID, URL or hostname is allowed.
- Generic `resource` discovery requires `resourceType` and `tags` or `nameFilterEnv`.
  For example: `{"discover":"resource","resourceType":"Microsoft.App/jobs",
  "nameFilterEnv":"APPLY_JOB_NAME_FILTER","selectionKey":"apply-job"}`.
  `tags` is a map of logical tag keys/values. `nameFilterEnv` names an operator-provided
  prefix/substring filter, never the literal deployed name. Entra app/group discovery
  requires `nameFilterEnv`.
- `selectionKey`: optional logical key shared by steps using one target. Pass
  `--select key=<discovered-id-or-name>` to choose it without a prompt. Explicit selections
  must match a real discovered candidate. Otherwise the numbered picker offers real choices.
- ARM resources use `blade`, such as `/overview` or `/namedValues`.
- Entra steps use `entraBlade`: `kind` is `app-registration`, `enterprise-application` or
  `group`; `name` is the portal blade identifier, such as `Overview`, `ProtectAnAPI`,
  `AppRoles`, `Properties`, `Users`, `Members` or `Owners`.
- `waitFor`: exactly one of `text` or `selector`; optional `exact` for text.
  All frames are checked, and the **first visible** match counts: the portal keeps hidden
  copies of many labels (collapsed menus, tooltips, other blades), so the first match in
  the DOM is often not the one on screen. Do not put real resource names or IDs into
  selectors. A timeout names the locator that did not render.
- `clicks`: optional ordered navigation actions, each with `text` or `selector`, optional
  `exact`, optional `waitFor`, and optional `settle`. Authentication and commit actions
  (Sign in, Save, Delete, Create, Grant, etc.) are refused. There is no credential typing.
  A click whose `waitFor` is already on screen is skipped: the portal remembers menu groups
  open, and clicking an open group closes it. The top-level `waitFor` is checked **before**
  the clicks, so it must be on the landing blade, not on the page the clicks reach.
- Prefer `/overview` plus menu clicks to deep links. `/namedValues`, `/identity`, `/apis`,
  `/networking` and `/deployments` stopped rendering their content in the current portal.
  Proven patterns: a gateway menu item under the APIs group is
  `{"selector":"a.fxc-menu-item >> text=\"APIs\""}` (the group header has the same text);
  a job's execution history is the overview's `View` link; Log Analytics Functions are in
  KQL mode (`Simple mode` > `KQL mode` > `[role="tab"][aria-label="Functions"]` >
  `Workspace functions`). A Foundry resource has no deployments blade in the Azure portal.
- `settle`: milliseconds, 0–60000. Every settle, including a click's, lasts at least
  `PORTAL_MIN_SETTLE_MS` (default 8000), because blades render their frame first and fill
  values from later calls.
- `redaction.mapEnv`: names an environment variable pointing to a **private**, uncommitted
  JSON array of `[real, Contoso replacement]` pairs. Common email, UUID, resource-host and
  photo redaction remains mandatory. Optional `hideSelectors` hides sensitive UI regions
  before the shared rendered-DOM leak check. A value of 8 or more characters, or a 6+
  character mix of letters and digits (a deployment suffix), is replaced and leak-checked
  wherever it occurs, including inside a longer name built from it; shorter plain words
  keep word boundaries. `keepTargetName` keeps a target named with the product's own word.
- `redaction.people`: on an Entra group or application page that lists people, require the
  principals discovery read from the directory (the group's direct members, or the users and
  service principals assigned to the application). Each is shown as `Contoso user N`; the
  capture is refused when none were discovered, because no private map can list people.

## Run one batch

```powershell
node guide/capture-portal.mjs --list
node guide/capture-portal.mjs --dry-run --only turnstile-app-overview,turnstile-app-roles
node guide/capture-portal.mjs --profile $profilePath --only turnstile-app-overview,turnstile-app-roles
```

`--list` requires no Azure access. `--dry-run` resolves all selected targets and prints their
real portal URLs **without opening a browser**. Use `--subscription`, `--resource-group`,
`--select key=value` and `--non-interactive` for automation. Real choices belong in runtime
parameters/environment, not in spec files.

A blade whose data plane is private (a private Key Vault's **Certificates** list) loads only
when the browser reaches that host through a route inside the network. Set
`PORTAL_PROXY_PAC_URL` to a PAC file served on this machine (`http://127.0.0.1:<port>/<name>.pac`)
that sends only that host through such a route; any other value is refused. The runner never
disables TLS checks or adds other browser switches.

The runner refuses to start while its own code (`guide/*.mjs`, `guide/lib/**`) differs from
the commit, because every record names the commit that took it; spec files may differ, and each
record carries the hash of the step it ran (`spec_sha256`).

ARM discovery passes the selected subscription explicitly. Entra discovery uses the current
Azure CLI tenant and refuses a selected subscription in another tenant; it never changes the
CLI account or passes ARM's `--subscription` option to directory commands.

The lead runs the authenticated batch against the one original profile immediately after
the owner's sign-in. Other agents must not launch that profile. The runner requires an
explicit `--profile`, takes an exclusive lock for that profile and opens one browser.
Close the owner's sign-in browser before starting. A lock is not permission to share a
profile with another browser.

At the first **actual authentication surface** (not a silent redirect), the runner stops,
does not click or type anything, and reports the current and remaining steps. The summary
lists captured, skipped and failed IDs. A stale profile or a missed blade is never saved
as evidence of the requested page. Failed/skipped steps make the process nonzero.

Entra blades (app registrations, enterprise applications, groups) intermittently ask for
a step-up approval (**Approve sign in request**) even in a signed-in profile. Run the
resource steps and the Entra steps as separate batches, so a step-up cannot strand the
rest. When the runner stops on one, the owner opens that blade in a headed window of the
same profile, approves it, closes the window, and the lead reruns the remaining IDs from
the report.

Batch metadata is written to `docs/guide/portal-captures.json`; Turnstile outputs also update
their existing manifest and require `TURNSTILE_FORK_COMMIT` for that version record.
The private operational report defaults to `.finops-evidence/portal-batch-result.json`.
Never commit the profile, replacement map, resolved private target file or raw report.

## Fast offline validation

```powershell
pwsh -NoProfile -File tests/Test-PortalCaptureSpecs.ps1
```

The check is registered in Test-All, reads specs/docs only, and uses in-memory fixtures to
prove that malformed schemas, literal targets, unsafe output paths, credential actions,
duplicates and undocumented outputs are rejected. It opens no browser and calls no Azure
CLI, so it remains suitable for the parallel lane.
