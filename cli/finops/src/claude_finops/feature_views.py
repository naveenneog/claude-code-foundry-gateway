from .rules import human


def feature_rows(tab, data):
    items = data.get("items", [])
    if tab == "trends" and "comparison" in data:
        current, previous = data["current"].get("points", []), data["comparison"].get("points", [])
        def key(row):
            return row["bucket_start"][8:16], row.get("key", "")
        one, two = {key(row): row for row in current}, {key(row): row for row in previous}
        records, rows = [], []
        for bucket in sorted(one.keys() | two.keys()):
            first, second = one.get(bucket), two.get(bucket)
            a = first["totals"].get("total_tokens") if first else None
            b = second["totals"].get("total_tokens") if second else None
            records.append(dict(bucket=bucket[0], current=first, comparison=second,
                                delta=None if a is None or b is None else a-b))
            rows.append((bucket[0], human(a), human(b), human(None if a is None or b is None else a-b)))
        return (["Day / time", data["current_period"], data["comparison_period"], "Token delta"],
                rows or [("No buckets returned", "", "", "")], records or [{}], data["basis"])
    if tab == "approvals":
        columns = ["Id", "Scope / title", "Amount / severity", "State", "Reason"]
        rows = [(r.get("id", ""), r.get("scope_id", r.get("title", "")),
                 human(r.get("token_limit", r.get("severity"))), r.get("state", "notice"),
                 r.get("reason", r.get("body", ""))) for r in items]
    elif tab == "advanced":
        columns = ["Id", "Name / model", "State", "Enabled"]
        rows = [(r.get("id", r.get("backend_id", "")), r.get("display_name", r.get("name", r.get("model_key", ""))),
                 r.get("status", r.get("state", "")), str(r.get("enabled", ""))) for r in items]
    else:
        columns = ["Setting", "Value"]
        rows = [(str(r.get("setting", "")), str(r.get("value", ""))) for r in items]
    if not rows:
        rows = [("No records in your scope.", *("" for _ in columns[1:]))]
        items = [{}]
    return columns, rows, items, data.get("note", "Enter exact detail. Actions are shown only when advertised and permitted.")
