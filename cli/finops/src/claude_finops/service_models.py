"""Normalize P55 OpenAPI 1.x without assuming Turnstile response fields or authority."""


def capabilities(document):
    flags = document.get("capabilities", {}) if document.get("schema_version") == 1 else {}
    if not isinstance(flags, dict):
        flags = {}
    yes = lambda key: flags.get(key) is True
    feature = lambda active, actions: dict(enabled=active, actions=actions if active else [])
    writes = [name for name, flag in (("budget", "budget_write"), ("catalog", "catalog_write"),
              ("tiers", "tiers_write"), ("mode", "modes_write")) if yes(flag)]
    approvals = ["read"] if yes("budget_requests") or yes("approvals") else []
    if yes("budget_requests"):
        approvals.append("request")
    if yes("approvals"):
        approvals += ["approve", "reject", "escalate"]
    views = ["settings", "governance"]
    if yes("usage_read"):
        views += ["overview", "people", "trends", "requests"]
    if yes("budgets_read"):
        views.append("budgets")
    usd_actions = []
    if yes("usd_budgets_read"):
        usd_actions.append("read")
    if yes("usd_budget_write"):
        usd_actions.append("write")
    if yes("usd_budget_reconcile"):
        usd_actions.append("reconcile")
    if yes("usd_price_book_write"):
        usd_actions.append("price_book_write")
    return dict(schema_version=1, advertised=True, backend="aum-service", features={
        "native_writes": feature(bool(writes), writes),
        "supported_views": feature(True, views),
        "trend_intervals": feature(yes("usage_read"), ["day"]),
        "filter_fields": feature(yes("usage_read"), ["organization_id", "department_id", "user_id", "from", "to"]),
        "usage_breakdown": feature(False, []), "anomaly_findings": feature(False, []),
        "budget_modes": feature(yes("budgets_read"), ["read"] + (["write"] if yes("modes_write") else [])),
        "person_daily_budget": feature(yes("budgets_read"), ["read"] + (["write"] if yes("budget_write") else [])),
        "bulk_budget": feature(False, []),
        "approvals": feature(bool(approvals), approvals),
        "boosts": feature(yes("budgets_read"), ["read"] + (["create"] if yes("boosts") else [])),
        "notifications": feature(yes("notifications"), ["read"]),
        "audit_read": feature(yes("audit_read"), ["read"]),
        "request_cursor": feature(yes("usage_read"), ["read"]),
        "people_cursor": feature(yes("usage_read"), ["read"]),
        "conditional_writes": feature(bool(writes), ["write"]),
        "request_expiry": feature(False, []),
        "assistant": feature(False, []), "advanced": feature(False, []),
        "usd_budgets": feature(bool(usd_actions), usd_actions),
    }, limits=document.get("limits", {}))


def totals(row):
    prompt, completion = row.get("prompt_tokens"), row.get("completion_tokens")
    return dict(total_tokens=prompt + completion if prompt is not None and completion is not None else None,
        total_requests=row.get("requests"), input_tokens=prompt, output_tokens=completion,
        cache_read_tokens=row.get("cache_read_tokens"), cache_write_tokens=None,
        estimated_cost=None if row.get("unpriced_rows", 0) else row.get("usd"),
        unpriced_rows=row.get("unpriced_rows"), counter_basis="prompt_completion_only")


def page(document, items=None):
    cursor = document.get("next_cursor")
    return dict(items=document.get("items", []) if items is None else items,
                page=dict(next_cursor=cursor, has_more=bool(cursor)))


def request_record(row, identity):
    own = row.get("requester") == identity.get("id")
    actions = []
    if row.get("state") == "pending":
        if not own:
            # The service only returns another person's record to its approver or Admin.
            actions += ["approve", "reject"]
        if row.get("approver_scope") is not None:
            actions.append("escalate")
    return dict(row, requester_id=row.get("requester"), revision=str(row.get("version", "")), allowed_actions=actions)
