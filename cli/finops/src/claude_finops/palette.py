from functools import partial

from textual.command import DiscoveryHit, Hit, Provider

from .views import TABS


class FinOpsCommands(Provider):
    def commands(self):
        commands = [(f"Open {label[2:]}", partial(self.app.action_tab, key), "Switch view") for key, label in TABS]
        commands += [
            ("Find scope, person, model or request", self.app.action_lookup, "Bounded server search"),
            ("Change month", self.app.action_month, "YYYY-MM"),
            ("Refresh current view", self.app.action_refresh, "Read the latest server state"),
            ("Help and key map", self.app.action_help, "Learn this screen"),
            ("Export complete chargeback CSV", self.app.action_export, "All visible catalog units, not the top 100"),
        ]
        if self.app.editable:
            commands += [
                ("Edit selected budget or governance row", self.app.action_edit, "Preview, then apply"),
                ("Add unit or team", self.app.action_add, "Author gateway catalog"),
                ("Apply governance now", self.app.action_apply, "Retry the configured gateway job"),
                ("Remove selected budget or scope", self.app.action_remove, "Type the identifier to confirm"),
            ]
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
