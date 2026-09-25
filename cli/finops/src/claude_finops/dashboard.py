"""A monitoring dashboard: scoped facts, compact gauges, and focusable detail panels."""

from textual.containers import Horizontal, Vertical
from textual.widgets import Static
from datetime import datetime, timezone

from .rules import human
from .rules import month_window
from .views import money


def budget_totals(rows):
    roots = [row for row in rows if row.get("scope_type") == "organization"]
    roots = roots or [row for row in rows if row.get("scope_type") == "department"]
    limited = [row for row in roots if (row.get("token_limit") or 0) > 0]
    return (None if any(row.get("used_tokens") is None for row in limited) else sum(row["used_tokens"] for row in limited),
            sum(row["token_limit"] for row in limited), len(limited))


def enforcement_badge(entity):
    attrs = entity.get("attributes") or {}
    mode = attrs.get("enforcement", "strict")
    if mode == "allowance":
        value = attrs.get("allowance_percent")
        return f"ALLOW +{value:g}%" if isinstance(value, (float, int)) and 0 <= value <= 100 else "ALLOW ?%"
    return {"strict": "STRICT", "notify": "NOTIFY"}.get(mode, "UNKNOWN")


def gauge(used, limit, width=18, ascii_only=False):
    if not limit:
        return "Budget not assigned"
    if used is None:
        return "Usage unknown"
    share = max(0, used / limit)
    filled = min(width, round(share * width))
    bar = ("#" if ascii_only else "━") * filled + ("." if ascii_only else "─") * (width - filled)
    return f"[{bar}] {share:.1%}"


def sparkline(values, width=40, ascii_only=False):
    if not values:
        return "No data"
    if all(value is None for value in values):
        return "Unknown"
    if len(values) > width:
        step = len(values) / width
        values = [values[min(len(values) - 1, int(i * step))] for i in range(width)]
    chars = ".:-=+*#@" if ascii_only else "▁▂▃▄▅▆▇█"
    maximum = max(value for value in values if value is not None) or 1
    return "".join("?" if value is None else chars[min(7, max(0, round(value / maximum * 7)))] for value in values)


def block_chart(values, width, height=4, ascii_only=False):
    values = values[-width:]
    if values and len(values) < width:
        values = [values[min(len(values) - 1, int(i * len(values) / width))] for i in range(width)]
    maximum = max((v for v in values if v is not None), default=0) or 1
    levels = [None if v is None else round(v / maximum * height) for v in values]
    return ["".join("?" if level is None else ("#" if ascii_only else "█") if level >= row else " "
                    for level in levels) for row in range(height, 0, -1)]


class DashboardPanel(Static, can_focus=True):
    def __init__(self, title, panel_id):
        super().__init__("Loading live facts...", id=panel_id, classes="dashboard-panel", markup=False)
        self.border_title = title
        self.detail = {}

    def on_key(self, event):
        if event.key in {"enter", "d"}:
            from .screens import DetailScreen
            if event.key == "enter" and self.id in {"dash-rank", "dash-risks", "dash-anomalies"}:
                from .dashboard_drill import DashboardRows
                self.app.push_screen(DashboardRows(self))
            else:
                self.app.push_screen(DetailScreen(str(self.border_title) + " | exact source values", self.detail))
            event.stop()


class Dashboard(Vertical):
    def compose(self):
        yield DashboardPanel("Budget and month-to-date usage", "dash-kpis")
        with Horizontal(id="dash-main"):
            with Vertical(id="dash-left"):
                yield DashboardPanel("Daily tokens / estimated cost", "dash-trend")
                yield DashboardPanel("Top units and teams", "dash-rank")
            with Vertical(id="dash-right"):
                yield DashboardPanel("Budget risks", "dash-risks")
                yield DashboardPanel("Recent anomalies", "dash-anomalies")

    def clear(self):
        for panel in self.query(DashboardPanel):
            panel.update("No current data. Refresh an authorized view.")
            panel.detail = {}

    def update_data(self, data, raw=None, query=""):
        raw = raw or data
        ascii_only = self.app.config.ascii
        totals = data.get("overview", {}).get("totals", {})
        budgets = data.get("budgets", {}).get("items", [])
        used, limit, scopes = budget_totals(budgets)
        kpis = self.query_one("#dash-kpis", DashboardPanel)
        kpis.detail = raw
        quality = ""
        if self.size.width >= 120:
            quality = f"   Cache read {human(totals.get('cache_read_tokens'))}   P95 {human(totals.get('p95_latency_ms'))} ms"
        kpis.update(
            f"Tokens {human(totals.get('total_tokens'))}   Cost {money(totals.get('estimated_cost'))} est   Requests {human(totals.get('total_requests'))}{quality}\n"
            + (f"Allocated scopes {gauge(used, limit, 16, ascii_only)}  {human(used)} / {human(limit)}"
               if scopes else "Budget use unavailable: no allocated scope limit returned.")
        )
        self._trends(data, raw, ascii_only)
        self._rankings(data, raw, query, ascii_only)
        self._risks(data, raw, query)
        self._anomalies(data, raw, query)

    def _trends(self, data, raw, ascii_only):
        panel = self.query_one("#dash-trend", DashboardPanel)
        panel.detail = {"trends": raw.get("trends"), "budgets": raw.get("budgets")}
        points = data.get("trends", {}).get("points", [])
        tokens = [point["totals"].get("total_tokens") for point in points]
        costs = [point["totals"].get("estimated_cost") for point in points]
        width = max(12, panel.size.width - 13)
        lines = [f"Tokens {sparkline(tokens, width, ascii_only)}",
                 f"Cost   {sparkline(costs, width, ascii_only)}"]
        if panel.size.height >= 12 and tokens:
            lines = [f"Tokens peak {human(max((v for v in tokens if v is not None), default=0))}"] + block_chart(
                tokens, width, height=4, ascii_only=ascii_only) + lines
        rows = data.get("budgets", {}).get("items", [])
        roots = [r for r in rows if r.get("scope_type") == "organization"] or [
            r for r in rows if r.get("scope_type") == "department"]
        known = [r.get("forecast_tokens") for r in roots]
        forecast = human(sum(known)) if known and all(isinstance(v, (int, float)) for v in known) else "unknown"
        lines.append(f"Forecast {forecast} tokens (server)")
        start, end = month_window(self.app.engine.month)
        first = datetime.fromisoformat(start.replace("Z", "+00:00"))
        last = datetime.fromisoformat(end.replace("Z", "+00:00"))
        as_of = data.get("overview", {}).get("generated_at")
        now = datetime.fromisoformat(as_of.replace("Z", "+00:00")) if as_of else datetime.now(timezone.utc)
        elapsed = max(1, (min(last, now) - first).total_seconds() / 86400)
        total = data.get("overview", {}).get("totals", {}).get("total_tokens")
        if total is not None:
            burn = human(round(total / elapsed))
            if panel.size.height < 10:
                lines[-1] = f"Forecast {forecast}; pace {burn}/day"
            else:
                lines.append(f"Burn {burn} tokens/day (calendar pace)")
        if panel.size.height >= 10:
            lines.append("UTC daily buckets | cost is not an invoice")
            if data.get("trends", {}).get("note"):
                lines.append(data["trends"]["note"])
        panel.update("\n".join(lines))

    def _rankings(self, data, raw, query, ascii_only):
        panel = self.query_one("#dash-rank", DashboardPanel)
        panel.detail = {"units": raw.get("ranking"), "teams": raw.get("teams"), "catalog": raw.get("catalog")}
        catalog = data.get("catalog", {})
        modes = {r["id"]: enforcement_badge(r) for key in ("organizations", "departments") for r in catalog.get(key, [])}
        dimension = data.get("ranking", {}).get("dimension", "organization")
        kind = {"organization": "U", "department": "T", "user": "P", "model": "M", "runtime": "S",
                "tier": "Q", "project": "Q"}.get(dimension, "U")
        label = {"organization": "units", "department": "teams", "user": "people", "runtime": "surfaces",
                 "model": "models", "tier": "tiers", "project": "tiers"}.get(dimension, dimension)
        panel.border_title = f"Top {label}" + (" / teams" if dimension != "department" else "")
        ranked = [(kind, row) for row in data.get("ranking", {}).get("items", [])]
        teams = [("T", row) for row in data.get("teams", {}).get("items", [])] if dimension != "department" else []
        if query:
            ranked = [(kind, row) for kind, row in ranked if query.casefold() in str(row).casefold()]
            teams = [(kind, row) for kind, row in teams if query.casefold() in str(row).casefold()]
        items = ranked + teams
        maximum = max((row.get("total_tokens", 0) for _, row in items), default=1) or 1
        lines = []
        available = max(2, panel.size.height - 2)
        units = ranked[:max(1, available // 2)] if teams else ranked[:available]
        teams = teams[:max(1, available - len(units))]
        for kind, row in units + teams:
            amount = row.get("total_tokens", 0)
            bar = ("#" if ascii_only else "━") * max(1, round(amount / maximum * 8))
            name = row.get("name", row["id"])[:20]
            mode = modes.get(row["id"], "STRICT")
            line = f"{kind} {name:<20} {bar:<8} {human(amount):>7}"
            if panel.size.width >= 64:
                line += f" [{mode}]"
            lines.append(line)
        panel.update("\n".join(lines) or data.get("ranking", {}).get("note") or "No ranked usage in this window.")

    def _risks(self, data, raw, query):
        panel = self.query_one("#dash-risks", DashboardPanel)
        budget = data.get("budgets", {})
        items = budget.get("risk_items") or [r for r in budget.get("items", []) if r.get("status") in {"warning", "exceeded"}]
        if query:
            items = [r for r in items if query.casefold() in str(r).casefold()]
        panel.detail = raw.get("budgets", {})
        lines = []
        for row in items[:max(1, (panel.size.height - 2) // 2)]:
            lines += [f"[{str(row.get('status', 'risk')).upper()}] {row.get('scope_name', row.get('scope_id', 'scope'))}",
                      f"Used {row.get('usage_percent', '?')}% | forecast {row.get('forecast_percent', '?')}%"]
        count = budget.get("risk_count")
        empty = f"{count} risk(s) reported; details unavailable." if count else budget.get("note") or "No budget warnings returned."
        panel.update("\n".join(lines) or empty)

    def _anomalies(self, data, raw, query):
        panel = self.query_one("#dash-anomalies", DashboardPanel)
        response = data.get("anomalies", {})
        items = response.get("items", [])
        if query:
            items = [r for r in items if query.casefold() in str(r).casefold()]
        panel.detail = raw.get("anomalies", {})
        lines = []
        for row in items[:max(1, (panel.size.height - 2) // 3)]:
            lines += [f"[{row.get('severity', 'finding').upper()}] {row.get('dimension_name', '')}",
                      row.get("title", "Usage finding"), str(row.get("detected_at", ""))[:16] + " UTC"]
        panel.update("\n".join(lines) or response.get("note") or "No anomalies returned for this window.")
