"""Textual refresh lifecycle: bounded sources, progressive panels and stale-result isolation."""

import asyncio
from datetime import datetime
import time

from textual import work
from textual.widgets import DataTable, Static

from .dashboard import Dashboard, DashboardPanel
from .errors import FinOpsError
from .output import safe_text
from .scope import scope_label


SOURCES = {
    "identity": ("Azure sign-in", 4),
    "capabilities": ("backend capabilities", 5),
    "overview": ("month usage", 3),
    "budgets": ("gateway budgets", 5),
    "ranking": ("usage ranking", 3),
    "teams": ("team usage", 3),
    "trends": ("daily trends", 3),
    "anomalies": ("anomalies", 5),
    "catalog": ("gateway catalog", 5),
}


class ProgressiveRefresh:
    def _current_refresh(self, serial, tab):
        return (self.is_running and self._refresh_serial == serial
                and bool(self.query("#main-tabs")) and self.active == tab)

    def _show_wait(self):
        if not self._waiting or not self.is_running or not self.query("#status"):
            return
        labels = [SOURCES.get(key, (key.replace("_", " "), 5))[0] for key in self._waiting]
        estimate = max(SOURCES.get(key, ("", 5))[1] for key in self._waiting)
        elapsed = time.monotonic() - self._refresh_started
        names = ", ".join(labels[:3]) + (f" +{len(labels) - 3} sources" if len(labels) > 3 else "")
        timing = f"Estimate ~{estimate} s; elapsed {elapsed:.1f} s"
        if elapsed > estimate:
            timing += " (longer than estimated)"
        self.query_one("#status", Static).update(f"Waiting for {names}\n{timing}. q quits; r retries.")

    async def _tracked_read(self, key, operation, serial, tab):
        if self._current_refresh(serial, tab):
            self._waiting.add(key)
            self._show_wait()
        try:
            return await operation
        finally:
            if self._current_refresh(serial, tab):
                self._waiting.discard(key)
                self._show_wait()

    async def _metadata_or_data_error(self, operation, data_task):
        async def run():
            return await operation()

        metadata = asyncio.create_task(run())
        try:
            if data_task is not None:
                completed, _ = await asyncio.wait((metadata, data_task), return_when=asyncio.FIRST_COMPLETED)
                if data_task in completed:
                    data_task.result()
            return await metadata
        finally:
            if not metadata.done():
                metadata.cancel()
            await asyncio.gather(metadata, return_exceptions=True)

    def _error_text(self, error):
        self.present(getattr(error, "details", {}))
        return safe_text(self.redactor.text(str(error)))

    def _show_identity(self):
        stamp = ("12:00 +00:00 example" if self.engine.backend.name == "Example"
                 else datetime.now().astimezone().strftime("%H:%M:%S %z"))
        display_identity = self.present(self.identity)
        who = display_identity.get("email", display_identity.get("name", "caller"))
        scope = scope_label(display_identity)
        prefix = f"{self.engine.month} | {self.engine.backend.name} | {self.identity.get('role', 'unknown')} | "
        suffix = f" | @ {stamp}"
        available = max(8, self.size.width - len(prefix) - len(suffix) - 2)
        if len(who) > available:
            who = who[:available - 3] + "..."
        line = prefix + who + suffix
        if scope:
            line += " | " + scope
        self.query_one("#identity", Static).update(safe_text(line))
        self.update_brand()

    def _show_read_error(self, tab, error):
        self.editable = False
        self.data.pop(tab, None)
        self.records.pop(tab, None)
        self.query_one(f"#table-{tab}", DataTable).clear(columns=True)
        if tab == "overview":
            self.query_one(Dashboard).clear()
            self.query_one(Dashboard).display = False
        note = self.query_one(f"#note-{tab}", Static)
        note.add_class("read-error")
        note.update(self._error_text(error))
        self.query_one("#identity", Static).update(f"{self.engine.backend.name} | Read failed (exit {error.code})")
        self.update_brand()
        fix = "Check managed scope in Settings; r refreshes." if error.code == 4 else (
            "No resource started. r retries; 0 opens Settings." if error.code == 9 else "r retries; ? explains sign-in.")
        self.query_one("#status", Static).update(f"Read failed (exit {error.code}). {fix}")

    @work(exclusive=True, group="view")
    async def action_refresh(self):
        self._refresh_serial += 1
        serial, tab = self._refresh_serial, self.active
        self._refresh_started = time.monotonic()
        self._waiting = set()
        self.verifying_identity = True
        self.editable = False
        self.refresh_bindings()
        self.data.pop(tab, None)
        self.records.pop(tab, None)
        self.query_one(f"#table-{tab}", DataTable).clear(columns=True)
        note = self.query_one(f"#note-{tab}", Static)
        note.remove_class("read-error")
        note.update("Loading current data (estimate 3-5 s); sources appear as they arrive.")
        if tab == "overview":
            self.query_one(Dashboard).display = True
            self.query_one(Dashboard).begin_load()
        if tab == "settings":
            local = await self.load_tab(tab)
            local["access_note"] = "Local settings; sign-in and authority verification pending."
            if "governance_authority" in local:
                local["governance_authority"] = "not yet verified"
            self.render_tab(tab, local)
        timer = self.set_interval(.25, self._show_wait)
        data_task = None
        identity_error = ""
        independent = bool(self.engine.backend.identity_independent_reads)
        try:
            with self.engine.backend.read_cycle():
                if independent and tab not in {"settings", "ask", "approvals", "advanced"}:
                    data_task = asyncio.create_task(self.load_tab(tab))
                try:
                    identity = await self._metadata_or_data_error(lambda: self._tracked_read(
                        "identity", asyncio.to_thread(self.engine.read, "whoami"), serial, tab), data_task)
                except FinOpsError as error:
                    if data_task is not None and data_task.done():
                        data_task.result()
                    if not independent or data_task is None:
                        raise
                    identity_error = self._error_text(error)
                    self.identity = {}
                    self.feature_caps = {}
                    self.query_one("#identity", Static).update("Direct | identity unavailable; read-only data")
                    self.update_brand()
                else:
                    if not self._current_refresh(serial, tab):
                        return
                    self.update_access(identity, preserve_current=independent and not self.identity)
                    self._show_identity()
                    if tab not in self.allowed_tabs:
                        return
                    await self._metadata_or_data_error(
                        lambda: self._tracked_read("capabilities", self.refresh_features(), serial, tab), data_task)
                if not self._current_refresh(serial, tab):
                    return
                self.verifying_identity = False
                if data_task is None:
                    data_task = asyncio.create_task(self.load_tab(tab))
                data = await self._tracked_read(tab + "_view", data_task, serial, tab)
                if not self._current_refresh(serial, tab):
                    return
                self.data[tab] = data
                self.render_tab(tab, data)
                mode = "[redacted/read-only] " if self.redactor.enabled else ""
                if identity_error:
                    status = identity_error + " | Current data is Azure-authorized; edits are disabled."
                elif data.get("_errors"):
                    status = f"{len(data['_errors'])} panel read(s) failed; other current data is shown. r retries."
                else:
                    status = mode + "<Enter> details <Tab> panel </> lookup <r> refresh"
                self.query_one("#status", Static).update(status)
                if len(self.screen_stack) == 1:
                    self.set_focus(self.query_one("#dash-kpis", DashboardPanel) if tab == "overview"
                                   else self.query_one(f"#table-{tab}", DataTable))
                self.maybe_tour()
        except FinOpsError as error:
            if self._current_refresh(serial, tab):
                self._show_read_error(tab, error)
        finally:
            timer.stop()
            if data_task is not None:
                if not data_task.done():
                    data_task.cancel()
                await asyncio.gather(data_task, return_exceptions=True)
            if self._refresh_serial == serial:
                self._waiting.clear()
                self.verifying_identity = False
                if self.is_running and self.query("#main-tabs"):
                    self.refresh_bindings()
                    self.update_key_hints()

    async def load_overview(self):
        serial, tab = self._refresh_serial, "overview"
        read = self.engine.read
        operations = {
            "overview": asyncio.to_thread(read, "overview", **self.scope_filters),
            "budgets": asyncio.to_thread(read, "budgets"),
            "ranking": self.optional_dashboard_read("usage_breakdown", "distribution",
                dimension=self.ranking_dimension, limit=10, **self.scope_filters),
            "teams": self.optional_dashboard_read("usage_breakdown", "distribution",
                dimension="department", limit=10, **self.scope_filters),
            "trends": asyncio.to_thread(read, "trends", interval="day", group_by="none", **self.scope_filters),
            "anomalies": self.optional_dashboard_read("anomaly_findings", "anomalies", limit=10, **self.scope_filters),
            "catalog": asyncio.to_thread(read, "catalog"),
        }
        data = {key: {} for key in operations}
        data["_pending"] = list(operations)
        data["_errors"] = {}

        async def fetch(key, operation):
            try:
                return key, await self._tracked_read(key, operation, serial, tab), None
            except FinOpsError as error:
                if error.code in {3, 4, 9}:
                    raise
                return key, None, self._error_text(error)

        tasks = [asyncio.create_task(fetch(key, operation)) for key, operation in operations.items()]
        try:
            for completed in asyncio.as_completed(tasks):
                key, result, error = await completed
                data["_pending"].remove(key)
                if error:
                    data["_errors"][key] = error
                else:
                    data[key] = result
                if self._current_refresh(serial, tab):
                    self.data[tab] = data
                    self.render_tab(tab, data)
                    self._show_wait()
            data.pop("_pending")
            if not data["_errors"]:
                data.pop("_errors")
            return data
        finally:
            for task in tasks:
                if not task.done():
                    task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
