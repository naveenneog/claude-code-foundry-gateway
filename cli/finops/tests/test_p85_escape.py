from contextlib import contextmanager
from pathlib import Path
import subprocess
import threading

import httpx
import pytest
from textual.widgets import Static
from textual.worker import WorkerFailed

from claude_finops.config import Config
from claude_finops.dashboard import DashboardPanel
from claude_finops.dashboard_drill import DashboardRows
from claude_finops.engine import Engine
from claude_finops.errors import FinOpsError, http_error
from claude_finops.feature_screens import ActionForm, TourScreen
from claude_finops.palette import FinOpsCommands
from claude_finops.tui import FinOpsApp
from test_progressive_tui import DelayedBackend, settle, until


BURSTS = [1, 2, 5, 10]
CAE = ("Continuous access evaluation resulted in challenge with result: "
       "InteractionRequired and code: LocationConditionEvaluationSatisfied")
MODALS = ["main", "detail", "month", "lookup", "change", "export", "action",
          "filters", "tour", "groups", "developers", "dashboard", "palette"]


@pytest.fixture
def app_factory(monkeypatch, tmp_path):
    monkeypatch.setattr(Path, "home", lambda: tmp_path)

    def create(backend=None):
        return FinOpsApp(Engine(backend or DelayedBackend(), "2026-09"),
                         Config(backend="fake"), first_run=False)
    return create


async def open_modal(app, pilot, name):
    if name == "main":
        return
    if name == "change":
        app.action_tab("budgets")
        await settle(app, pilot)
        app.action_edit()
    elif name == "action":
        app.push_screen(ActionForm("Offline preview", [],
                                   lambda values, apply: {"action": "Offline", "preview": not apply}))
    elif name == "tour":
        app.push_screen(TourScreen())
    elif name == "dashboard":
        app.push_screen(DashboardRows(app.query_one("#dash-rank", DashboardPanel)))
    elif name == "palette":
        await pilot.press(":")
    else:
        actions = dict(detail=app.action_help, month=app.action_month, lookup=app.action_lookup,
                       export=app.action_export, filters=app.action_scope_filters,
                       groups=app.action_add, developers=app.action_add_developer)
        actions[name]()
    await settle(app, pilot)
    assert len(app.screen_stack) == 2


@pytest.mark.parametrize("presses", BURSTS)
@pytest.mark.parametrize("modal", MODALS)
async def test_escape_bursts_main_and_every_modal_stay_running(app_factory, modal, presses):
    app = app_factory()
    async with app.run_test(size=(80, 24)) as pilot:
        await settle(app, pilot)
        await open_modal(app, pilot, modal)
        await pilot.press(*(["escape"] * presses))
        await settle(app, pilot)
        assert app.is_running
        assert len(app.screen_stack) == 1
        assert not app.engine.backend.writes


@pytest.mark.parametrize("presses", BURSTS)
async def test_escape_bursts_during_slow_refresh_stay_running(app_factory, presses):
    backend = DelayedBackend(direct=True, blocked=("trends",))
    app = app_factory(backend)
    async with app.run_test(size=(80, 24)) as pilot:
        try:
            await until(lambda: backend.started["trends"].is_set(), pilot)
            await pilot.press(*(["escape"] * presses))
            assert app.is_running
            assert not backend.blocked["trends"].is_set()
        finally:
            backend.release()
        await settle(app, pilot)
        assert app.is_running and "overview" in app.data


def read_failure(kind):
    if kind == "network":
        return httpx.ConnectError("private-transport-marker")
    if kind == "io":
        return OSError("private-transport-marker")
    if kind == "cae":
        return FinOpsError(CAE, 3)
    if kind.startswith("raw"):
        code = int(kind[3:])
        request = httpx.Request("GET", "https://offline.contoso.com")
        return httpx.HTTPStatusError("private-transport-marker", request=request,
                                    response=httpx.Response(code, request=request))
    return http_error(int(kind))


@pytest.mark.parametrize("presses", BURSTS)
@pytest.mark.parametrize("failure,expected", [
    ("network", "network"), ("io", "I/O"), ("401", "Sign-in expired"),
    ("403", "not permitted"), ("raw401", "Sign-in expired"),
    ("raw403", "not permitted"), ("cae", "IP"),
])
async def test_escape_triggered_refresh_errors_are_visible_not_fatal(app_factory, presses, failure, expected):
    backend = DelayedBackend()
    app = app_factory(backend)
    async with app.run_test(size=(80, 24)) as pilot:
        await settle(app, pilot)
        app.action_tab("budgets")
        await settle(app, pilot)
        await pilot.press("enter")
        await settle(app, pilot)
        assert app.breadcrumbs
        backend.failures["budgets"] = read_failure(failure)
        await pilot.press(*(["escape"] * presses))
        await settle(app, pilot)
        assert app.is_running
        status = str(app.query_one("#status", Static).render())
        assert expected.casefold() in status.casefold()
        assert "private-transport-marker" not in status
        if failure == "cae":
            rendered = "\n".join(strip.text for strip in app.screen._compositor.render_strips())
            for phrase in ("VPN", "IPv6", "named location", "exclusion"):
                assert phrase in rendered
        assert "budgets" not in app.data
        assert not backend.writes
        backend.failures.clear()
        app.action_refresh()
        await settle(app, pilot)
        assert app.is_running and app.data["budgets"]["items"]


@pytest.mark.parametrize("presses", BURSTS)
async def test_escape_after_publication_refusal_stays_running(app_factory, presses):
    app = app_factory()
    async with app.run_test(size=(80, 24)) as pilot:
        await settle(app, pilot)

        @contextmanager
        def stale():
            raise FinOpsError("The sign-in changed. This cached read is obsolete.", 3)
            yield

        app._data_guards["overview"] = (app.data["overview"], stale)
        await pilot.press(*(["escape"] * presses))
        await settle(app, pilot)
        assert app.is_running
        assert "sign-in changed" in str(app.query_one("#status", Static).render()).lower()
        assert "overview" not in app.data


@pytest.mark.parametrize("presses", BURSTS)
@pytest.mark.parametrize("form", ["action", "change"])
async def test_escape_dismisses_pending_preview_without_late_failure(app_factory, form, presses):
    app = app_factory()
    started, released = threading.Event(), threading.Event()

    def pending_preview(values, apply):
        started.set()
        released.wait(timeout=5)
        raise httpx.ConnectError("private-transport-marker")

    async with app.run_test(size=(80, 24)) as pilot:
        await settle(app, pilot)
        if form == "action":
            app.push_screen(ActionForm("Offline pending preview", [], pending_preview))
            await pilot.pause()
            app.screen.show_preview()
        else:
            await open_modal(app, pilot, "change")
            app.engine.backend.blocked["budgets"] = released
            app.engine.backend.started["budgets"] = started
            app.engine.backend.failures["budgets"] = httpx.ConnectError("private-transport-marker")
            app.screen.preview()
        try:
            await until(started.is_set, pilot)
            await pilot.press(*(["escape"] * presses))
            assert app.is_running
        finally:
            released.set()
        await settle(app, pilot)
        assert app.is_running
        assert len(app.screen_stack) == 1
        assert not app.engine.backend.writes


@pytest.mark.parametrize("presses", BURSTS)
async def test_quit_requires_confirmation_and_escape_cancels_it(app_factory, presses):
    app = app_factory()
    async with app.run_test(size=(80, 24)) as pilot:
        await settle(app, pilot)
        await pilot.press("q")
        assert app.is_running
        assert "Esc" in str(app.screen.query_one("#quit-message", Static).render())
        await pilot.press(*(["escape"] * presses))
        await settle(app, pilot)
        assert app.is_running and len(app.screen_stack) == 1


@pytest.mark.parametrize("confirmation", ["q", "enter"])
async def test_quit_explicit_second_key_exits(app_factory, confirmation):
    app = app_factory()
    async with app.run_test(size=(80, 24)) as pilot:
        await settle(app, pilot)
        await pilot.press("q")
        assert app.is_running
        await pilot.press(confirmation)
        assert not app.is_running


@pytest.mark.parametrize("view,paging", [("overview", False), ("people", True)])
async def test_palette_reaches_quit_escape_and_paging_actions(app_factory, view, paging):
    app = app_factory()
    async with app.run_test(size=(80, 24)) as pilot:
        await settle(app, pilot)
        app.action_tab(view)
        await settle(app, pilot)
        callbacks = {getattr(callback, "__name__", "") for _, callback, _ in FinOpsCommands(app.screen).commands()}
        assert {"action_quit", "action_clear_filter"} <= callbacks
        assert ("action_next_page" in callbacks) is paging
        assert ("action_previous_page" in callbacks) is paging
        assert not app.engine.backend.writes


@pytest.mark.parametrize("stderr", [CAE, CAE.upper()])
def test_azure_cli_preserves_actionable_cae_location_reason(monkeypatch, tmp_path, stderr):
    from claude_finops import config
    monkeypatch.setattr(config.shutil, "which", lambda _: str(tmp_path / "az.exe"))
    monkeypatch.setattr(config.subprocess, "run",
                        lambda *args, **kwargs: subprocess.CompletedProcess([], 1, "", stderr + " private-transport-marker"))
    with pytest.raises(FinOpsError) as caught:
        config.az("account", "get-access-token")
    assert caught.value.code == 3
    for phrase in ("IP", "VPN", "IPv6", "named location", "exclusion"):
        assert phrase in str(caught.value)
    assert "private-transport-marker" not in str(caught.value)


@pytest.mark.parametrize("stderr", ["InteractionRequired", "LocationConditionEvaluationSatisfied", "AADSTS50105"])
def test_other_azure_cli_errors_are_not_labelled_cae(monkeypatch, tmp_path, stderr):
    from claude_finops import config
    monkeypatch.setattr(config.shutil, "which", lambda _: str(tmp_path / "az.exe"))
    monkeypatch.setattr(config.subprocess, "run",
                        lambda *args, **kwargs: subprocess.CompletedProcess([], 1, "", stderr))
    with pytest.raises(FinOpsError) as caught:
        config.az("account", "get-access-token")
    assert "VPN" not in str(caught.value)
    assert caught.value.code == (4 if stderr == "AADSTS50105" else 3)


async def test_unexpected_programming_failure_is_not_disguised_as_a_read_error(app_factory):
    backend = DelayedBackend()
    app = app_factory(backend)
    with pytest.raises(WorkerFailed, match="programming-defect-marker"):
        async with app.run_test(size=(80, 24)) as pilot:
            await settle(app, pilot)
            backend.failures["budgets"] = ValueError("programming-defect-marker")
            app.action_tab("budgets")
            await settle(app, pilot)


def test_read_error_normalizer_rejects_programming_errors():
    from claude_finops.errors import read_error
    with pytest.raises(TypeError, match="expected backend read failures"):
        read_error(ValueError("programming-defect-marker"))
