from .rules import human, apply_state

TABS = [("overview", "1 Overview"), ("budgets", "2 Budgets"), ("people", "3 People"),
        ("governance", "4 Governance"), ("usage", "5 Usage"), ("trends", "6 Trends"),
        ("requests", "7 Requests"), ("anomalies", "8 Anomalies"), ("settings", "0 Settings")]
DIMENSIONS = [("Units", "organization"), ("Teams", "department"), ("People", "user"),
              ("Models", "model"), ("Surfaces", "runtime")]


def view_rows(tab, data, *, ascii_only=False):
    """Return columns, display cells, exact row records and a context line."""
    rows, records = [], []
    note = data.get("note", "")
    if tab == "overview":
        columns = ["Metric / scope", "Current month", "Context"]
        totals = data["overview"].get("totals", {})
        units = [r for r in data["budgets"].get("items", []) if r["scope_type"] == "organization"]
        limit = sum(r.get("token_limit") or 0 for r in units)
        forecast = sum(r.get("forecast_tokens") or 0 for r in units)
        if limit:
            rows.append(("Allocated unit budgets", human(limit), "tokens; not org ceiling"))
            records.append({"allocated_unit_tokens": limit})
        if forecast:
            rows.append(("Forecast month-end", human(forecast), "tokens; server forecast"))
            records.append({"forecast_tokens": forecast})
        for key, value in totals.items():
            rows.append((key.replace("_", " "), human(value), "estimated USD" if key == "estimated_cost" else ""))
            records.append({key: value})
        for item in data.get("ranking", {}).get("items", []):
            rows.append((item["name"], human(item["total_tokens"]), "unit tokens"))
            records.append(item)
        note = "Estimated cost, not an invoice. Enter: exact values. 2: budgets; 5: rankings."
    elif tab in {"budgets", "people"}:
        columns = ["Scope", "Used", "Budget", "Remaining", "Status"]
        if tab == "budgets":
            columns.insert(4, "Unallocated")
            columns.append("Mode")
        items = data.get("items", [])
        if tab == "budgets":
            units = [r for r in items if r["scope_type"] == "organization"]
            ordered = []
            for unit in units:
                ordered.append(unit)
                ordered += [r for r in items if r["scope_type"] == "department" and r.get("parent_scope_id") == unit["scope_id"]]
            items = ordered + [r for r in items if r not in ordered]
        for item in items:
            prefix = "  > " if tab == "budgets" and item["scope_type"] == "department" else ""
            cells = [prefix + item["scope_id"], human(item["used_tokens"]), human(item.get("token_limit")),
                     human(item.get("remaining_tokens")), item.get("status", "unknown")]
            if tab == "budgets":
                children = [r for r in items if r.get("parent_scope_id") == item["scope_id"]
                            and r["scope_type"] != item["scope_type"]]
                free = (item["token_limit"] - sum(r.get("token_limit") or 0 for r in children)
                        if item.get("token_limit") is not None and item["scope_type"] == "organization" else None)
                cells.insert(4, human(free) if item["scope_type"] == "organization" else "see People")
                cells.append(data.get("enforcement_modes", {}).get(item["scope_id"], "STRICT"))
            rows.append(tuple(cells))
            records.append(item)
        if tab == "budgets":
            note = note or "Organization > unit > team. Remaining = budget minus usage; edit shows allocation."
        else:
            total = data.get("total")
            note = f"Server search | {data.get('offset', 0) + 1}-{data.get('offset', 0) + len(items)} of {total if total is not None else 'unknown'} | Parent free: {human(data.get('department_available_tokens'))}"
    elif tab == "governance":
        from .dashboard import enforcement_badge
        columns = ["Kind / scope", "Parent / group", "Limits / models"]
        catalog = data["catalog"]
        for kind, collection in (("Unit", "organizations"), ("Team", "departments")):
            for item in catalog[collection]:
                label = "Parent context" if item.get("scope_context") else kind
                rows.append((f"{label}: {item['id']}", item.get("parent_id") or item.get("external_ref") or "-",
                             (item.get("external_ref") or "no member group") + " [" + enforcement_badge(item) + "]"))
                records.append(dict(item, kind=kind.lower()))
        for item in data["tiers"]["items"]:
            rows.append((f"Tier: {item['id']}", f"{human(item['tokens_per_minute'])}/min {human(item['tokens_per_day'])}/day",
                         ", ".join(item["models"]) or "all models"))
            records.append(dict(item, kind="tier"))
        note = apply_state(data["apply"]) + " | Enter: all groups and details."
    elif tab == "usage":
        columns = ["Scope / model", "Tokens", "Cache read", "Requests", "Est. USD"]
        for item in data.get("items", []):
            rows.append((item["name"], human(item["total_tokens"]), human(item.get("cache_read_tokens")),
                         human(item["total_requests"]), money(item.get("estimated_cost"))))
            records.append(item)
        note = note or "Top 100 server-ranked rows. Estimates, not invoice costs. Enter: complete metrics."
    elif tab == "trends":
        columns = ["Bucket (UTC)", "Tokens", "Volume", "Est. USD"]
        points = data.get("points", [])
        maximum = max((p["totals"]["total_tokens"] for p in points), default=1) or 1
        for item in points:
            total = item["totals"]
            bar = ("#" if ascii_only else "█") * max(1, round(total["total_tokens"] / maximum * 16))
            rows.append((item["bucket_start"][:16].replace("T", " "), human(total["total_tokens"]), bar,
                         money(total.get("estimated_cost"))))
            records.append(item)
        note = note or "UTC buckets. Bar length compares token volume within this window."
    elif tab == "requests":
        columns = ["Request id", "Time (UTC)", "Person", "Model", "Tokens", "HTTP"]
        for item in data.get("items", []):
            rows.append((item["request_id"], item.get("timestamp", "")[11:19], item.get("user_name") or item.get("user_id", ""),
                         item.get("model_name", ""), human(item.get("total_tokens")), str(item.get("status_code") or "?")))
            records.append(item)
        note = data.get("note") or "Bounded server window; n/p page locally. Enter opens the complete request."
    elif tab == "anomalies":
        columns = ["Severity", "Finding", "Scope", "Detected (UTC)"]
        for item in data.get("items", []):
            rows.append((item["severity"], item["title"], item.get("dimension_name", ""), item["detected_at"][:16]))
            records.append(item)
        note = note or "Computed findings are read-only. This API has no acknowledge or false-positive action."
    else:
        columns = ["Setting", "Value"]
        for key, value in data.items():
            rows.append((key, str(value)))
            records.append({key: value})
        note = "Config stores addresses only. Sign in/out with az login / az logout outside this app."
    if not rows:
        rows = [("No results. Adjust the month or filter.", *("" for _ in columns[1:]))]
        records = [{}]
    return columns, rows, records, note


def money(value):
    return "unknown" if value is None else f"${value:,.4f}"
