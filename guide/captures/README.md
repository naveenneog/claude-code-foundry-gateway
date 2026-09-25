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
| `gateway-identity` | `docs/guide/a4-identity.png` | System-assigned identity; batch capture pending |
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
  All frames are checked. Do not put real resource names or IDs into selectors.
- `clicks`: optional ordered navigation actions, each with `text` or `selector`, optional
  `exact`, optional `waitFor`, and optional `settle`. Authentication and commit actions
  (Sign in, Save, Delete, Create, Grant, etc.) are refused. There is no credential typing.
- `settle`: milliseconds, 0–60000.
- `redaction.mapEnv`: names an environment variable pointing to a **private**, uncommitted
  JSON array of `[real, Contoso replacement]` pairs. Common email, UUID, resource-host and
  photo redaction remains mandatory. Optional `hideSelectors` hides sensitive UI regions
  before the shared rendered-DOM leak check.

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
