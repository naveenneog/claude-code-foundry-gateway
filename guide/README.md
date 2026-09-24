# Screenshot tooling

Generates the annotated portal images used across the guides, mainly
[`../docs/SETUP.md`](../docs/SETUP.md) and
[`../docs/ONBOARDING.md`](../docs/ONBOARDING.md).

For the terminal screenshots of the installer, see
[`redact-terminal.mjs`](redact-terminal.mjs) instead — those are captured from
real runs and redacted rather than generated.

Two entry points:

| Script | Source | Use when |
|--------|--------|----------|
| `capture.mjs` | live pages via Playwright | you want fresh shots of your own deployment |
| `compose.mjs` | PNGs already on disk | you have a capture and want the guide's banner treatment on it |

Both call the same `lib/annotate.mjs`, so the output is visually consistent
regardless of where the pixels came from.

## Setup

The gateway itself needs none of this — the tooling is only for regenerating
the guide's images.
Use Node/npm, an installed Microsoft Edge and an account authorised to see the
target blades. Live capture needs interactive MFA; no unattended workaround is
implied. Run commands from the **repository root**, not this `guide` folder.

```bash
npm ci
```

The capture launches your installed **Microsoft Edge** (`channel: 'msedge'`),
so no browser download is needed. If Edge is not present, run
`npx playwright install chromium` and drop the `channel` option.

## Capturing

### 1. Discover and select the capture targets

Resolve the signed-in subscription/tenant and enumerate the actual gateways and
Foundry accounts. This is a read-only step:

```powershell
$account = az account show -o json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $account.id) { throw 'No selected signed-in subscription' }
$env:AZURE_SUB = $account.id
$env:AZURE_TENANT = $account.tenantId
az apim list --query "[].{name:name,rg:resourceGroup}" -o table
az cognitiveservices account list --query "[].{name:name,rg:resourceGroup,kind:kind}" -o table

# Set these to the actual selected rows, never a capture script's old defaults.
$env:APIM_NAME = '<selected-apim-name>'
$env:GATEWAY_RG = '<selected-gateway-resource-group>'
$env:FOUNDRY_RESOURCE = '<selected-foundry-account>'

# only needed for the "add a member" capture:
$env:STANDARD_GROUP_ID = (az ad group show --group '<recorded-standard-group>' --query id -o tsv)
```

**Portal equivalents and value sources:**

| Value | Portal source |
|---|---|
| Subscription / tenant | Subscriptions > selected subscription > Overview; Entra ID > Overview > Tenant ID |
| APIM name / group | API Management services > selected instance > Overview > Essentials |
| Foundry account | The selected gateway's API backend, then that account's Overview; it may be in another resource group |
| Standard group ID | Entra ID > Groups > the recorded tier group > Overview > Object ID |
| Workbook GUID | The discovered workbook's resource ID, not a guessed display name |

The [operations discovery procedure](../docs/OPERATIONS.md#1-select-the-gateway-and-workspace)
locates the logger/workspace. When the installer record exists, reuse
`scripts/Get-ClaudeGatewayTarget.ps1` rather than copying another environment's
names. Confirm every deep link opens the intended resource; some historical
capture steps assume resources share a group, so do not run them unchanged when
your layout differs.

### 2. Use an authorised dedicated browser profile

An **interactive owner**, not unattended automation, may initialise its dedicated
profile with `node guide/auth.mjs` and approve the required sign-in. Set the tenant
first and close that browser before another process uses the profile.

For an already-authorised capture session, copy its dedicated profile to this
checkout's `.pw-profile` with the owner's permission. Never launch a browser
against the source profile and never run two browsers on one profile. Do not use
someone's normal personal browser profile. If a sign-in page appears, stop
portal capture and report the blocker; do not attempt to sign in automatically.

### 3. Capture, inspect and redact

```powershell
# Uses the authorised local profile; does not initialise a new sign-in here.

node guide/capture.mjs              # everything
node guide/capture.mjs a3-apim-overview   # one step
```

**Manual/portal path:** open the relevant guide's portal blade, capture it with
your approved screenshot tool, then redact and review before publication.
Capturing does not require running a deployment script. The scripted tool has
historical resource-name defaults and assumes some shared resource locations:
set every environment value above, inspect the destination URLs, and do not
assume a wrong/empty blade means your resource does not exist.

The tool writes into `docs/guide`. Work in a controlled checkout and never stage
its output before redaction/review. `.pw-profile` and `guide/.auth.json` can
authenticate as you; keep them private, never commit them, and remove that
dedicated capture state when it is no longer needed.

Step ids:

| id | Backs |
|----|-------|
| `a1`–`a8`, `b1`–`b5` | [Setup guide](../docs/SETUP.md) |
| `c2-entra-groups`, `c3-group-members`, `c4-tier-budget` | [Onboarding guide](../docs/ONBOARDING.md) |
| `c5-metrics` | [Monitoring guide](../docs/MONITORING.md) |
| `d1`–`d3` | [Monitoring guide](../docs/MONITORING.md) — the chargeback workbook |

The `d*` steps need the workbook to exist and its id passed in, because the id
is a generated guid rather than a name and cannot be derived:

```powershell
# Publish it, then use the guid the publisher prints.
./scripts/Publish-ClaudeWorkbook.ps1 -ResourceGroup '<workbook-resource-group>' `
    -WorkspaceName '<ledger-workspace>' `
    -WorkbookFile infra/workbook-chargeback.json -Name 'Claude gateway - chargeback'

$env:CHARGEBACK_WORKBOOK_ID = "<guid it printed>"
node guide/capture.mjs d1-chargeback-totals d2-chargeback-units d3-chargeback-models
```

Set `AZURE_TENANT` before `auth.mjs` as well as before `capture.mjs`. Without
it the portal signs in to whichever directory the account defaults to, which
for an account in more than one tenant is rarely the one holding the gateway —
the capture then shows an empty blade rather than failing.

A workbook runs every tile's query when it opens, so the `d*` steps settle far
longer than a blade that only renders ARM properties, and `d2`/`d3` scroll the
portal's own pane — `window.scrollTo` moves nothing, because the portal renders
into a nested scroll container.

Steps that need a portal session are **skipped, not failed**, when the profile
is not signed in. A run with no session still produces the public-page
screenshots and reports which ones it skipped.

## Pending portal batch captures

When Conditional Access asks for a new sign-in on a resource or Entra blade,
stop portal capture. Do not retry, invoke `auth.mjs` unattended or reuse the
source profile concurrently. Other live captures that do not use the portal,
such as CLI transcripts and approved application/report views, can continue.

The documentation packet's declared portal steps are in
[`captures/docs-review.json`](captures/docs-review.json), using the version-1
object containing `steps`. Targets are discovered; no tenant, subscription or
deployment name is a default. The operator supplies `DOCS_RESOLVER_NAME_FILTER`,
`DOCS_PROJECTION_NAME_FILTER` and `DOCS_ENTITLEMENT_GROUP_FILTER` at runtime,
selecting real associated candidates. `selectionKey` reuses that choice across
steps. The private replacement map is supplied through
`PORTAL_REDACTIONS_FILE`; never commit it.

Each guide marks its final image path **pending batch capture (spec id)**.
Until capture, the path is inline code, not a broken image or a fake placeholder,
as required by the batch contract. Convert it to an image with meaningful alt
text only after its real output has been reviewed and committed.
The lead runs the batch immediately after an owner-authorised sign-in, reviews
redaction and populated blade contents, then commits the images. A loading shell
or a sign-in page is not a completed screenshot. Pending specs remain open in
the batch's status report; passing ordinary link/image checks does not mean a
declared pending capture was taken. Do not add an exception or fabricate a file.

The batch must remain read-only: an editor may be opened for a screenshot, but
the spec must not save a quota, assign a role, deploy or delete a resource.
Logical API names in click selectors come from this repository's template; if
an API was renamed, resolve its known API ID/path before capturing.

## What is not committed, and why

Captures partially mask email addresses in the DOM — first/last characters and
the domain can remain. **This is not anonymization and does not make an image
safe to publish.** Replace real names, addresses, tenant/resource/group IDs,
URLs, browser chrome and deployment names with Contoso placeholders before
committing. Review pixels as well as captions; automated masking can miss text.

**That is not enough for every blade**, and three were captured during this work
and deleted rather than committed:

| Blade | What was in the frame |
|---|---|
| Entra → Groups → All groups | directory-wide group names, mostly unrelated to this gateway |
| A group's Members list | display names and object ids beside the addresses |
| Application Insights overview | the instrumentation key and connection string |

Masking addresses does not cover a display name, an object id or a key. Those
blades are **taken against your own tenant** and kept locally — see
[`../docs/ONBOARDING.md`](../docs/ONBOARDING.md), which tells the reader to do
exactly that.

A second trap: a portal deep link often lands on the resource **Overview**
rather than the blade named in the URL. Several captures came back showing
Overview under a banner describing a policy or a role assignment, which is worse
than having no picture — it is a caption that does not match its image. Open
every new capture and check it shows what its banner claims before committing
it.

## Composing

```bash
node guide/compose.mjs
```

Reads the list in `compose.mjs`, applies banners, highlights, and redactions,
and writes to `docs/guide/`.

The source PNGs it expects are the raw, unannotated captures. They are not
shipped in this repo — only the finished images in `docs/guide/` are. Point the
`src` paths at your own captures, or use `capture.mjs` instead, which produces
its sources live.

## Writing a step

```js
{
  id: 'a3-apim-overview',
  url: () => portal(apimId + '/overview'),
  needsAuth: true,
  settle: 16000,                       // portal blades render slowly
  banner: { n: 3, title: '...', note: '...' },
  targets: [{ sel: '#someElement', n: 'a', pad: 6 }],
}
```

- `targets` are measured on the live page, so highlights survive layout changes.
  The first target is scrolled to centre before the capture.
- `banner` is drawn on canvas extended above the shot, never over the UI.
- Coordinates in `compose.mjs` are fractions of the image (`0`–`1`) so a spec
  stays correct if a source is recaptured at a different resolution.

## Redaction

`annotate()` masks the Azure portal's signed-in account block **by default**.
Pass `maskIdentity: false` only for pages that have no identity in them.

Anything else that must not be published — UPNs in terminal output,
subscription ids, browser tab strips — goes in `masks`, with replacement text:

```js
masks: [
  { x: 0.08, y: 0.28, w: 0.45, h: 0.033,
    text: 'dev@contoso.com / your-subscription', align: 'start' },
]
```

Review every generated image before publishing. Terminal captures in particular
tend to contain real UPNs, and browser captures pick up bookmark bars and tab
titles.

## Conditional access

`channel: 'msedge'` is set on the browser launch. A plain Chromium profile is
rejected with `AADSTS530033` on tenants that require device compliance; Edge
passes because it can present the device certificate.

## Verify and next steps

Open each image at readable resolution, confirm the caption describes the
actual blade, and add meaningful alt text in the consuming guide. Run
`tests/Test-Screenshots.ps1` and `tests/Test-DocReferences.ps1`; they detect
missing references, not all personal data in pixels. Have a separate reviewer
check redaction before publication.

Use [Reference](../docs/REFERENCE.md) for encoding and repository checks, and
[Releasing](../docs/RELEASING.md) before publishing a release.
