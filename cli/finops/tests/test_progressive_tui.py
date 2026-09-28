import asyncio
from copy import deepcopy
import threading

import pytest
from textual.widgets import DataTable, Static

from claude_finops.config import Config
from claude_finops.dashboard import DashboardPanel
from claude_finops.direct import DirectBackend
from claude_finops.engine import Engine
from claude_finops.errors import FinOpsError, http_error
from claude_finops.fake import FakeBackend
from claude_finops.tui import FinOpsApp


class DelayedBackend(FakeBackend):
    def __init__(self, *, direct=False, blocked=(), failures=None):
        super().__init__()
        self.identity_independent_reads = DirectBackend.identity_independent_reads if direct else frozenset()
        self.blocked = {key: threading.Event() for key in blocked}
        self.started = {key: threading.Event() for key in blocked}
        self.failures = failures or {}
        self.scope = None

    def read(self, resource, **params):
        if resource in self.blocked:
            self.started[resource].set()
            self.blocked[resource].wait(timeout=12)
        if resource in self.failures:
            raise self.failures[resource]
        result = super().read(resource, **params)
        if resource == "whoami":
            result["manager_scope"] = deepcopy(self.scope)
        return result

    def release(self):
        for event in self.blocked.values():
            event.set()


async def until(predicate, pilot):
    async def wait():
        while not predicate():
            await pilot.pause(.03)
    await asyncio.wait_for(wait(), timeout=5)


async def settle(app, pilot):
    await pilot.pause()
    await app.workers.wait_for_complete()
    await pilot.pause()


@pytest.mark.parametrize("size", [(80, 24), (160, 48)])
async def test_direct_first_data_does_not_wait_for_identity_and_waits_name_sources_and_estimates(size):
    backend = DelayedBackend(direct=True, blocked=("whoami", "trends"))
    app = FinOpsApp(Engine(backend, "2026-09"), Config(backend="fake"), first_run=False)
    async with app.run_test(size=size) as pilot:
        try:
            await until(lambda: "overview" in app.data and bool(app.data["overview"].get("overview")), pilot)
            assert not backend.blocked["whoami"].is_set()
            assert app.identity == {}
            assert "Tokens" in str(app.query_one("#dash-kpis", Static).render())
            trend = str(app.query_one("#dash-trend", Static).render())
            assert "Loading" in trend and "s" in trend
            status = str(app.query_one("#status", Static).render())
            assert "sign-in" in status.lower() and "estimate" in status.lower() and "elapsed" in status.lower()
            assert not app.check_action("edit", ()) and not app.check_action("apply", ())
            backend.blocked["whoami"].set()
            await until(lambda: bool(app.identity), pilot)
            assert app.data["overview"]["overview"]["totals"]["total_tokens"] > 0
            assert not backend.blocked["trends"].is_set()
        finally:
            backend.release()
        await settle(app, pilot)


async def test_ready_panels_render_while_one_independent_query_is_still_pending():
    backend = DelayedBackend(blocked=("trends",))
    app = FinOpsApp(Engine(backend, "2026-09"), Config(backend="fake"), first_run=False)
    async with app.run_test(size=(100, 30)) as pilot:
        try:
            await until(lambda: bool(app.data.get("overview", {}).get("ranking")), pilot)
            assert "U " in str(app.query_one("#dash-rank", Static).render())
            assert "Loading" in str(app.query_one("#dash-trend", Static).render())
            assert not backend.blocked["trends"].is_set()
        finally:
            backend.release()
        await settle(app, pilot)
        assert "Loading" not in str(app.query_one("#dash-trend", Static).render())


async def test_partial_kpi_keeps_arrived_budgets_and_does_not_guess_pending_catalog_modes():
    backend = DelayedBackend(blocked=("overview", "catalog"))
    app = FinOpsApp(Engine(backend, "2026-09"), Config(backend="fake"), first_run=False)
    async with app.run_test(size=(160, 48)) as pilot:
        try:
            await until(lambda: bool(app.data.get("overview", {}).get("ranking"))
                        and bool(app.data.get("overview", {}).get("budgets")), pilot)
            kpis = str(app.query_one("#dash-kpis", Static).render())
            assert "Loading" in kpis and "Allocated scopes" in kpis
            ranking = str(app.query_one("#dash-rank", Static).render())
            assert "[mode pending]" in ranking and "[STRICT]" not in ranking
        finally:
            backend.release()
        await settle(app, pilot)


async def test_unavailable_optional_panel_keeps_other_current_facts_and_names_its_failure():
    backend = DelayedBackend(failures={"trends": FinOpsError("Trend query unavailable", 7)})
    app = FinOpsApp(Engine(backend, "2026-09"), Config(backend="fake"), first_run=False)
    async with app.run_test(size=(100, 30)) as pilot:
        await settle(app, pilot)
        assert app.data["overview"]["overview"]["totals"]["total_tokens"] > 0
        assert "Trend query unavailable" in str(app.query_one("#dash-trend", Static).render())
        assert "failed" in str(app.query_one("#status", Static).render()).lower()


async def test_direct_identity_failure_does_not_discard_azure_authorized_data_or_enable_writes():
    backend = DelayedBackend(direct=True, failures={"whoami": FinOpsError("Identity lookup unavailable", 3)})
    app = FinOpsApp(Engine(backend, "2026-09"), Config(backend="fake"), first_run=False)
    async with app.run_test(size=(100, 30)) as pilot:
        await settle(app, pilot)
        assert app.data["overview"]["overview"]["totals"]["total_tokens"] > 0
        assert not app.editable
        assert "Identity lookup unavailable" in str(app.query_one("#status", Static).render())


async def test_http_scope_check_still_precedes_any_scoped_data():
    backend = DelayedBackend(blocked=("whoami",))
    backend.scope = {"organizations": [], "departments": [], "writable_department_ids": []}
    app = FinOpsApp(Engine(backend, "2026-09"), Config(backend="fake"), first_run=False)
    async with app.run_test(size=(100, 30)) as pilot:
        try:
            await until(lambda: backend.started["whoami"].is_set(), pilot)
            assert not app.data.get("overview")
            assert not any(name in {"budgets", "overview", "distribution"} for name, _ in backend.reads)
        finally:
            backend.release()
        await settle(app, pilot)
        assert app.active == "settings" and "overview" not in app.data
        assert not any(name in {"budgets", "overview", "distribution"} for name, _ in backend.reads)


async def test_settings_are_visible_without_waiting_for_backend_identity():
    backend = DelayedBackend(blocked=("whoami",))
    app = FinOpsApp(Engine(backend, "2026-09"), Config(backend="fake"), first_run=False)
    async with app.run_test(size=(100, 30)) as pilot:
        try:
            await until(lambda: backend.started["whoami"].is_set(), pilot)
            app.action_tab("settings")
            await until(lambda: app.query_one("#table-settings", DataTable).row_count > 0, pilot)
            assert not backend.blocked["whoami"].is_set()
            assert app.active == "settings"
        finally:
            backend.release()
        await settle(app, pilot)


async def test_superseded_read_cannot_repopulate_revoked_scope():
    backend = DelayedBackend()
    app = FinOpsApp(Engine(backend, "2026-09"), Config(backend="fake"), first_run=False)
    async with app.run_test(size=(100, 30)) as pilot:
        await settle(app, pilot)
        prior = app._refresh_serial
        backend.blocked["trends"] = threading.Event()
        backend.started["trends"] = threading.Event()
        app.action_refresh()
        try:
            await until(lambda: backend.started["trends"].is_set(), pilot)
            backend.scope = {"organizations": [], "departments": [], "writable_department_ids": []}
            app.action_refresh()
            await until(lambda: app.active == "settings", pilot)
        finally:
            backend.release()
        await settle(app, pilot)
        assert "overview" not in app.data
        assert app.query_one("#table-overview", DataTable).row_count == 0
        assert app._current_refresh(app._refresh_serial, "settings")
        assert not app._current_refresh(prior, "settings")
        assert not app._current_refresh(app._refresh_serial, "overview")


async def test_scope_denial_discards_every_partial_panel_not_only_the_failed_one():
    backend = DelayedBackend(failures={"trends": http_error(403)})
    app = FinOpsApp(Engine(backend, "2026-09"), Config(backend="fake"), first_run=False)
    async with app.run_test(size=(100, 30)) as pilot:
        await settle(app, pilot)
        assert "overview" not in app.data
        assert app.query_one("#table-overview", DataTable).row_count == 0
        assert "Not in your scope" in str(app.query_one("#note-overview", Static).render())


@pytest.mark.parametrize("redact", [False, True])
async def test_stopped_database_reason_and_manual_command_are_visible_and_redactable(redact):
    server, group = "pg-private-estate", "rg-private-estate"
    error = FinOpsError(
        f"PostgreSQL server {server} in {group} is Stopped. "
        f"Start manually: az postgres flexible-server start -g {group} -n {server}.", 9)
    error.details = {"server_name": server, "resource_group": group}
    backend = DelayedBackend(failures={"whoami": error})
    app = FinOpsApp(Engine(backend, "2026-09"), Config(backend="fake"), first_run=False, redact=redact)
    async with app.run_test(size=(80, 24)) as pilot:
        await settle(app, pilot)
        rendered = "\n".join(strip.text for strip in app.screen._compositor.render_strips())
        assert "Stopped" in rendered
        assert "az postgres flexible-server start" in rendered
        assert (server in rendered) is not redact
        assert (group in rendered) is not redact
        assert "No current data" not in rendered
        assert "Signing in" not in rendered


async def test_quit_and_help_remain_responsive_while_data_is_pending():
    backend = DelayedBackend(direct=True, blocked=("trends",))
    app = FinOpsApp(Engine(backend, "2026-09"), Config(backend="fake"), first_run=False)
    async with app.run_test(size=(100, 30)) as pilot:
        try:
            await until(lambda: backend.started["trends"].is_set(), pilot)
            await pilot.press("?")
            assert len(app.screen_stack) == 2
            await pilot.press("escape", "q")
            assert not app.is_running
        finally:
            backend.release()


async def test_navigation_immediately_after_worker_completion_cannot_restore_old_pane():
    app = FinOpsApp(Engine(FakeBackend(), "2026-09"), Config(backend="fake"), first_run=False)
    async with app.run_test(size=(80, 24)) as pilot:
        await pilot.pause(.25)
        await app.workers.wait_for_complete()
        for tab in ("budgets", "people", "governance", "usage", "trends", "requests", "settings"):
            app.action_tab(tab)
            await pilot.pause(.2)
            await app.workers.wait_for_complete()
            assert app.active == tab and tab in app.data


async def test_worker_completion_cannot_queue_focus_past_its_generation(monkeypatch):
    app = FinOpsApp(Engine(FakeBackend(), "2026-09"), Config(backend="fake"), first_run=False)
    async with app.run_test(size=(80, 24)) as pilot:
        await settle(app, pilot)
        queued = []
        monkeypatch.setattr(DashboardPanel, "focus", lambda widget, *args, **kwargs: queued.append(widget.id))
        app.action_refresh()
        await settle(app, pilot)
        assert queued == [], "Worker completion must set focus now, not enqueue an old-pane callback."
        assert app.focused.id == "dash-kpis"


@pytest.mark.parametrize("metadata", ["whoami", "capabilities"])
async def test_fatal_data_failure_is_rendered_before_pending_metadata_finishes(metadata):
    backend = DelayedBackend(direct=True, blocked=(metadata, "trends"))
    app = FinOpsApp(Engine(backend, "2026-09"), Config(backend="fake"), first_run=False)
    async with app.run_test(size=(100, 30)) as pilot:
        try:
            await until(lambda: backend.started[metadata].is_set()
                        and bool(app.data.get("overview", {}).get("overview")), pilot)
            backend.failures["trends"] = http_error(403)
            backend.blocked["trends"].set()
            await until(lambda: "Not in your scope" in str(app.query_one("#note-overview", Static).render()), pilot)
            assert not backend.blocked[metadata].is_set(), "A fatal data error cannot wait for metadata."
            assert "overview" not in app.data
            assert app.query_one("#table-overview", DataTable).row_count == 0
            assert "Waiting" not in str(app.query_one("#status", Static).render())
            assert not app.editable
        finally:
            backend.release()
        await settle(app, pilot)
        assert "overview" not in app.data
