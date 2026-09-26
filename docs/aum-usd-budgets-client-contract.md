# AUM client contract: USD budgets (P21/P59)

This is an additive AUM **service** contract. No terminal-client code changes
are included in this branch. Existing `/budgets`, requests and boosts still
operate in tokens; never relabel those values as dollars.

`GET capabilities` exposes `usd_budgets_read`, `usd_budget_write`,
`usd_budget_reconcile` and `usd_price_book_write`. Unknown flags default false.
Write flags require the two gateway USD named values to be installed and are
narrowed by identity/authority. They do not waive allocation or revision checks.

## Transport and authorization

Use the existing service base URL, delegated Entra bearer token (`AUM.Access`
and an assigned AUM role), error envelope and `Cache-Control: no-store`.
All paths below begin `/api/v1/`. GET accepts no body or query parameters.
PUT/DELETE accepts JSON and requires `If-Match` from a fresh `/budgets` or
`/usd-budgets` response. Revisions cover authored USD definitions, not routine
reconciler refreshes. A 409 requires a fresh read and a new user decision.
Do not automatically replay a mutation after an uncertain 503 or read-back error.

Scope names reuse the existing API:

| API type | UI label | Period / writer |
|---|---|---|
| `organization` | Business unit | `month`; Admin only |
| `department` | Team | `month`; Admin or its parent unit's manager |
| `user` | Person, Entra object id | `day` or `month`; Admin or manager of the person's unit/team |

Viewer is read-only. A team-only manager cannot change its own team allocation.
Reads and reconcile-status items are filtered on the server. Do not use a
parent displayed as context as evidence of permission. Turnstile ownership
refuses writes and reconciliation with `other_authority`.

## Read definitions

`GET usd-budgets` returns:

```json
{
  "schema_version": 1,
  "currency": "USD",
  "revision": "<opaque>",
  "price_book_date": "2026-09-16",
  "items": [
    {
      "scope_type": "department",
      "scope_id": "payroll",
      "amount_usd": "25.000001",
      "period": "month",
      "price_book_date": "2026-09-16",
      "writable": true
    }
  ]
}
```

Money is a **decimal string**, never binary floating point. Accept up to nine
fractional digits, nonnegative values below one trillion. A zero API budget
is a real zero-dollar stop, not unlimited. `DELETE` clears the USD control.
Do not present `amount_usd` as a token conversion or an Azure-invoice cap.

## Set or clear a definition

`PUT usd-budgets/{scope_type}/{scope_id}`:

```json
{
  "amount_usd": "30.00",
  "period": "month",
  "price_book_date": "2026-09-16",
  "reason": "Approved monthly allocation"
}
```

`DELETE` at the same path takes `{"reason":"Allocation removed"}`. No extra
fields are accepted. The successful response has `audit_id`, `revision` and
`result` containing only the selected scope's definition (or `cleared: true`);
it does not return the entire underlying named value.

Dollar allocation checks are independent of the token allocation. Daily
person limits reserve 31 days against a monthly parent. A finite parent must
fit its explicitly allocated children. A USD edit does not raise a token
guard: either guard can refuse independently. Existing dollar-input scripts
also maintain their approximate token quota for backward compatibility.

After a write, show **Saved; awaiting reconciliation**, not **Enforced now**.
An old state does not match the new configuration, and enforced scopes can
temporarily return 503 until the next reconciliation.

## Price book

`GET usd-price-book` returns `{price_book, revision}`. `price_book` is null
until initialized. Admin-only `PUT usd-price-book` requires If-Match and:

```json
{
  "reason": "Initialize the approved list-price tariff",
  "price_book": {
    "date": "2026-09-16",
    "models": {
      "claude-sonnet-5": {
        "inputPerM": "2",
        "outputPerM": "10",
        "cacheReadPerM": "0.2",
        "cacheWrite5mPerM": "2.5",
        "cacheWrite1hPerM": "4"
      }
    }
  }
}
```

Keys identify actual deployment names. Missing optional cache rates derive
from input at 0.1, 1.25 and 2 respectively. Explicit null/invalid rates fail;
unknown deployments are never $0. Existing active budgets pin their book:
replacing it requires explicitly clearing them first. The API returns
`usd_price_book_pinned` rather than silently repricing history.

## Reconciler status and on-demand execution

`GET usd-budget-status` returns:

- `enabled`, `fresh`, `reconcile_interval_seconds` (300),
  `state_max_age_seconds` (900);
- when available: `schema_version`, `source_revision`, `policy_revision`,
  `reconciled_at`, `valid_until`;
- `items`, a scope-filtered object keyed by `scope_type:scope_id`.

Each item contains `scope_type`, `scope_id`, `period`, exclusive `period_start`
and `period_end` (UTC), `budget_usd`, `effective_budget_usd`, nullable
`spent_usd`, `enforcement`, `price_book_date`, `status`, `exact`,
`cache_read_known`, `cache_write_known`, and `unpriced_models`.

The gateway stores a compact internal row format to fit its named-value limit.
Clients must use the expanded HTTP contract, not decode or edit those rows.

| Status | Display |
|---|---|
| `allow` | Observed subtotal below limit |
| `notice` | Notify/allowance advisory, or incomplete observed categories |
| `stop` | Gateway USD stop requested; verify propagation |
| `unpriced` | Enforced scope stopped because usage cannot be priced |

`exact` means the **observed rows' categorized arithmetic is complete**.
It does not assert that every event has been ingested or that the Azure invoice
agrees. Streaming cache writes remain unknown; cache-read metrics can be
limited by cardinality. Always display incompleteness next to spend. Null is
**unpriced**, never zero.

Admin-only `POST usd-budget-reconcile` accepts `{}` and returns the resulting
state (or `{"enabled":false}`). It invokes the same engine as the five-minute
service timer. Managers must not see an Apply button that invokes this route.
The timer uses the existing service identity, audit and writer lease; no
provider key or new inference hop is introduced.

## Developer-facing errors and notices

The gateway returns an Anthropic-shaped `{"type":"error","error":{...}}`:

- **403 `usd_budget_exceeded`**: scope, nominal/effective budget, observed spend,
  UTC window and `reconciled_at`; request an approved increase, then reconcile.
- **403 `usd_budget_unpriced`**: missing/invalid model pricing or attribution;
  administrators must fix the tariff/telemetry. Do not recommend blind retry.
- **503 `usd_budget_state_stale`**: missing, expired or mismatched state.
  Show a reconciliation/dependency problem, not revoked entitlement.
- Successful advisory responses use `x-claude-usd-budget-notice`, a JSON array
  limited to the caller's matching scopes. Claude client display is not promised.

The existing strict/allowance/notify modes remain in `bu-modes`; the dollar API
does not create another mode authority. Other scopes and the original token
guards still apply. Raising a USD budget lifts its stop only after a successful
reconcile and APIM propagation. UTC rollover likewise needs the new snapshot.

## Client acceptance checks

1. Hide unsupported dollar actions on older services rather than falling back
   to token writes. A 404 is not success.
2. Unit/team/person reads are scoped; replaying an outside id is refused.
3. Preserve decimal text, the tariff date and UTC/exclusive window boundaries.
4. Distinguish saved, awaiting reconciliation, stale, unpriced and stopped.
5. Never expose a manager-only Apply or price-book editor.
6. Existing token requests/boosts remain token workflows until a separate
   dollar workflow is implemented. No automatic token-to-dollar translation.
