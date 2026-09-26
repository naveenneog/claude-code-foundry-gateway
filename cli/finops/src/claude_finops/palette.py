from functools import partial

from textual.command import DiscoveryHit, Hit, Provider

from .views import TABS
from .ui_features import EXTRA_TABS
from .capabilities import enabled


class FinOpsCommands(Provider):
    def commands(self):
        commands = [(f"Open {label if key == 'advanced' else label[2:]}", partial(self.app.action_tab, key), "Switch view")
                    for key, label in TABS + EXTRA_TABS if key in self.app.allowed_tabs]
        commands += [
            ("Find scope, person, model or request", self.app.action_lookup, "Bounded server search"),
            ("Filter the current view", self.app.action_filter, "Visible rows only; Esc clears"),
            ("Change month", self.app.action_month, "YYYY-MM"),
            ("Refresh current view", self.app.action_refresh, "Read the latest server state"),
            ("Help and key map", self.app.action_help, "Learn this screen"),
            ("Exact selected values", self.app.action_exact_detail, "Full precision and request-based person details"),
            ("Set server filter chips", self.app.action_scope_filters, "Unit, team, person, model, surface and tier"),
            ("Save current view", self.app.action_save_view, "Private to this identity and profile"),
            ("Open saved view", self.app.action_load_view, "Restore month and filters"),
            ("Remove saved view", self.app.action_remove_view, "Only this identity/profile"),
            ("Budget audit history", self.app.action_budget_history, "Server-scoped changes and actors"),
            ("Compare trend periods", self.app.action_compare, "Compare actual month buckets"),
            ("Switch profile or backend", self.app.action_profile, "Verify the new identity before switching"),
            ("Sign out", self.app.action_sign_out, "Preview clearing the Azure CLI session"),
        ]
        if self.app.active == "people" and not self.app.redactor.enabled:
            commands.append(("Open team membership in Entra", self.app.action_membership, "Directory rights are enforced by Entra"))
        if self.app.engine.backend.name == "Direct":
            commands += [("Usage: request-time attribution", self.app.action_request_time_usage, "Stamped team at request time; no invented cost"),
                         ("Usage: current priced membership", self.app.action_priced_usage, "Published workspace price/membership function")]
        if self.app.active == "requests" and not self.app.redactor.enabled:
            commands += [("Copy request id", self.app.action_copy_request, "Terminal clipboard"),
                         ("Open request in ledger", self.app.action_open_ledger, "Discovered Log Analytics resource")]
        ranking = self.app.feature_caps.get("features", {}).get("usage_breakdown")
        if ranking is None or enabled(self.app.feature_caps, "usage_breakdown"):
            for dimension in ("organization", "department", "user", "model", "runtime", "tier"):
                commands.append((f"Overview ranking: {dimension}", partial(self.app.action_overview_rank, dimension), "Scoped server ranking"))
        if self.app.check_action("export", ()):
            commands.append(("Export complete chargeback CSV", self.app.action_export, "All managed scopes, not the top 100"))
        if self.app.identity.get("role") == "owner" and not self.app.redactor.enabled:
            commands += [
                ("Find or create Entra security group", self.app.action_group_lookup, "Owned by this sign-in; no consent grants"),
                ("Probe gateway budget enforcement", self.app.action_gateway_probe, "One tiny real model request after Preview/Apply"),
            ]
        if self.app.editable:
            commands += [
                ("Edit selected budget or governance row", self.app.action_edit, "Preview, then apply"),
                ("Add unit or team", self.app.action_add, "Author gateway catalog"),
                ("Remove selected budget or scope", self.app.action_remove, "Type the identifier to confirm"),
                ("Generate reconciled chargeback report (P50)", self.app.action_report_generate, "Activates when the merged generator is present"),
            ]
            if not self.app.engine.backend.immediate_writes:
                commands.append(("Apply governance now", self.app.action_apply, "Retry the configured gateway job"))
            if self.app.engine.backend.name == "Turnstile":
                commands.append(("Publish Turnstile as signed-in admin", self.app.action_publish_as_admin, "Explicit delegated Graph and Azure RBAC; no new consent"))
                commands.append(("Refresh recent Turnstile usage", self.app.action_refresh_usage, "One existing exporter execution; no schedule or governance changes"))
            if self.app.engine.backend.name in {"Direct", "Turnstile"}:
                commands.append(("Refresh selected group membership", self.app.action_refresh_membership, "Delegated Graph; preserves unrelated mappings"))
            if enabled(self.app.feature_caps, "bulk_budget", "write"):
                commands.append(("Import person budgets from CSV", self.app.action_bulk, "Preview full parent allocation"))
            if enabled(self.app.feature_caps, "budget_modes", "write"):
                commands.append(("Set budget enforcement mode", self.app.action_mode, "Strict, allowance or notify"))
            if enabled(self.app.feature_caps, "usd_budgets", "write"):
                commands.append(("Edit selected USD budget", self.app.action_usd_edit, "Preview, then save; reconciliation is separate"))
            if enabled(self.app.feature_caps, "usd_budgets", "reconcile"):
                commands.append(("Reconcile USD budgets now", self.app.action_usd_reconcile, "Runs the advertised gateway reconciler"))
        elif self.app.check_action("edit", ()):
            commands.append(("Edit selected delegated budget", self.app.action_edit, "Within the server's writable scope"))
        caps = self.app.feature_caps
        for feature, action, name, callback in [
            ("approvals", "request", "Request budget / request the difference", self.app.action_request_budget),
            ("approvals", "approve", "Approve budget request", partial(self.app.action_decide, "approve")),
            ("approvals", "reject", "Reject budget request", partial(self.app.action_decide, "reject")),
            ("approvals", "escalate", "Escalate budget request", partial(self.app.action_decide, "escalate")),
            ("boosts", "create", "Boost person with expiry", self.app.action_boost),
            ("boosts", "read", "Show active and expired boosts", self.app.action_show_boosts),
            ("boosts", "revoke", "Revoke boost", self.app.action_revoke_boost),
            ("notifications", "mark_read", "Mark notification read", self.app.action_read_notification),
            ("notifications", "read", "Open notifications", self.app.action_notifications),
            ("anomaly_dispositions", "acknowledge", "Acknowledge anomaly", partial(self.app.action_disposition, "acknowledged")),
            ("anomaly_dispositions", "false_positive", "Mark anomaly false positive", partial(self.app.action_disposition, "false_positive")),
            ("assistant", "read", "Assistant conversation history", self.app.action_assistant_history),
            ("assistant", "read", "View pinned charts", self.app.action_assistant_pins),
            ("assistant", "pin", "Pin assistant chart", self.app.action_pin_chart),
            ("assistant", "configure", "Configure assistant model and cost", self.app.action_assistant_configure),
        ]:
            if enabled(caps, feature, action):
                commands.append((name, callback, "Available in the connected server's capability contract"))
        if enabled(caps, "advanced"):
            for view in ("models", "pools", "releases", "subscriptions"):
                commands.append((f"Advanced: {view}", partial(self.app.action_advanced, view), "Read-only model gateway"))
        return commands

    async def discover(self):
        for name, callback, help_text in self.commands():
            yield DiscoveryHit(name, callback, help=help_text)

    async def search(self, query):
        matcher = self.matcher(query)
        for name, callback, help_text in self.commands():
            score = matcher.match(name)
            if score:
                yield Hit(score, matcher.highlight(name), callback, help=help_text)
