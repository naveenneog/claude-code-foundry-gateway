# Screenshot tooling

Generates the annotated images in [`../docs/UI-GUIDE.md`](../docs/UI-GUIDE.md).

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

```bash
npm install
```

The capture launches your installed **Microsoft Edge** (`channel: 'msedge'`),
so no browser download is needed. If Edge is not present, run
`npx playwright install chromium` and drop the `channel` option.

## Capturing

```powershell
# One-time sign-in. Approve the Authenticator prompt when it appears; the
# session is stored in ../.pw-profile and reused by later runs.
node guide/auth.mjs

$env:AZURE_SUB    = "<subscription-id>"
$env:AZURE_TENANT = "<tenant-id>"
$env:APIM_NAME    = "<apim-name>"
$env:GATEWAY_RG   = "<resource-group>"
$env:FOUNDRY_RESOURCE = "<foundry-account>"

# only needed for the "add a member" capture:
$env:STANDARD_GROUP_ID = (az ad group show --group claude-code-standard --query id -o tsv)

node guide/capture.mjs              # everything
node guide/capture.mjs a3-apim-overview   # one step
```

Step ids:

| id | Backs |
|----|-------|
| `a1`–`a8`, `b1`–`b5` | [UI guide](../docs/UI-GUIDE.md) |
| `c2-entra-groups`, `c3-group-members`, `c4-tier-budget` | [Onboarding guide](../docs/ONBOARDING.md) |
| `c5-metrics` | [Monitoring guide](../docs/MONITORING.md) |

Steps that need a portal session are **skipped, not failed**, when the profile
is not signed in. A run with no session still produces the public-page
screenshots and reports which ones it skipped.

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
