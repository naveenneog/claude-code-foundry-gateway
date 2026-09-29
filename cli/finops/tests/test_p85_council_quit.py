import asyncio
import threading

import pytest
from textual.widgets import Button, Static, TextArea

from claude_finops.config import Config
from claude_finops.engine import Engine
from claude_finops.errors import FinOpsError
from claude_finops.fake import FakeBackend
from claude_finops.feature_screens import ActionForm
from claude_finops.palette import FinOpsCommands
from claude_finops.tui import FinOpsApp
from p85_fixtures import fill, settle
from test_progressive_tui import until


class PendingWrite(FakeBackend):
    def __init__(self, resource="budget", features=None):
        super().__init__(features=features)
        self.resource = resource
        self.started, self.release, self.completed = (threading.Event() for _ in range(3))

    def write(self, resource, body=None, **params):
        assert resource == self.resource
        self.started.set()
        if not self.release.wait(timeout=20):
            raise AssertionError("The offline writer was not released.")
        result = super().write(resource, body, **params)
        self.completed.set()
        return result


async def start_write(app, pilot, form):
    await settle(app, pilot)
    app.action_tab("budgets")
    await settle(app, pilot)
    if form == "action":
        app.push_screen(ActionForm("Offline budget save", [],
            lambda values, apply: app.engine.budget_change("unit", "sales", "21M", apply=apply)))
        await pilot.pause()
        await pilot.click("#action-preview")
        await settle(app, pilot)
        screen = app.screen
        worker = screen.apply_action()
    else:
        app.action_edit()
        await pilot.pause()
        await fill(app, pilot, "#amount", "21M")
        await pilot.click("#preview")
        await settle(app, pilot)
        screen = app.screen
        worker = screen.apply_change()
    await until(app.engine.backend.started.is_set, pilot)
    return screen, worker


def saving(screen, form):
    return screen.busy if form == "action" else screen.applying


@pytest.mark.parametrize("form", ["action", "change"])
@pytest.mark.parametrize("route", ["ctrl+q", "ctrl+c", "palette", "exit"])
async def test_all_quit_routes_wait_for_write_and_keep_receipt(monkeypatch, form, route):
    backend = PendingWrite()
    app = FinOpsApp(Engine(backend, "2026-09"), Config(backend="fake"), first_run=False)
    async with app.run_test(size=(80, 24)) as pilot:
        screen, _ = await start_write(app, pilot, form)
        try:
            if route == "palette":
                next(callback for name, callback, _ in FinOpsCommands(app.screen).commands()
                     if name == "Quit AUM")()
            elif route == "exit":
                app.exit()
            elif route == "ctrl+c":
                await pilot.press("ctrl+c")
                assert app.is_running and not backend.completed.is_set()
                app.action_help_quit()
            else:
                await pilot.press(route)
            await pilot.pause()
            assert app.is_running, "A quit route stopped AUM before the writer completed."
            assert app.screen.query_one("#quit-confirm", Button).disabled
            assert "Saving; wait for the result" in str(app.screen.query_one("#quit-message", Static).render())
            rendered = "\n".join(strip.text for strip in app.screen._compositor.render_strips())
            assert "Saving; wait for the result" in rendered
            original_exit = app.exit
            attempts = []

            def exit_request(*args, **kwargs):
                attempts.append(True)
                return original_exit(*args, **kwargs)

            monkeypatch.setattr(app, "exit", exit_request)
            await pilot.press("q", "enter")
            assert attempts == [], "Disabled confirmation issued an exit request."
            app.exit()
            await pilot.pause()
            assert app.is_running and not backend.completed.is_set()
            assert len(app.screen_stack) == 3
        finally:
            backend.release.set()
            assert await asyncio.to_thread(backend.completed.wait, 5)
        await until(lambda: not saving(screen, form), pilot)
        await settle(app, pilot)
        assert app.is_running
        assert len(backend.writes) == 1 and backend.writes[0][2]["token_limit"] == 21000000
        assert not app.screen.query_one("#quit-confirm", Button).disabled
        await pilot.press("escape")
        await pilot.pause()
        assert app.screen is screen
        result = str(screen.query_one("#action-status" if form == "action" else "#form-status", Static).render())
        assert "Apply succeeded" in result
        assert str(screen.query_one("#action-cancel" if form == "action" else "#cancel-change", Button).label) == "Done"


@pytest.mark.parametrize("form", ["action", "change"])
async def test_cancelled_modal_worker_does_not_end_mutation_lifetime(form):
    backend = PendingWrite()
    app = FinOpsApp(Engine(backend, "2026-09"), Config(backend="fake"), first_run=False)
    async with app.run_test(size=(80, 24)) as pilot:
        screen, worker = await start_write(app, pilot, form)
        try:
            worker.cancel()
            await pilot.pause()
            app.action_quit()
            await pilot.pause()
            assert app.screen.query_one("#quit-confirm", Button).disabled
            await pilot.press("q")
            assert app.is_running and not backend.completed.is_set()
        finally:
            backend.release.set()
            assert await asyncio.to_thread(backend.completed.wait, 5)
        await until(lambda: not saving(screen, form), pilot)
        await settle(app, pilot)
        assert app.is_running
        await pilot.press("escape")
        await pilot.pause()
        assert app.screen is screen
        assert "Apply succeeded" in str(screen.query_one(
            "#action-status" if form == "action" else "#form-status", Static).render())


@pytest.mark.parametrize("form", ["action", "change"])
async def test_plain_q_and_escape_do_not_cancel_pending_write(form):
    backend = PendingWrite()
    app = FinOpsApp(Engine(backend, "2026-09"), Config(backend="fake"), first_run=False)
    async with app.run_test(size=(80, 24)) as pilot:
        screen, _ = await start_write(app, pilot, form)
        try:
            await pilot.press("q", "q", "escape", "escape")
            assert app.is_running and not backend.completed.is_set()
        finally:
            backend.release.set()
            assert await asyncio.to_thread(backend.completed.wait, 5)
        await until(lambda: not saving(screen, form), pilot)
        await settle(app, pilot)
        assert app.is_running and len(backend.writes) == 1


async def test_read_only_action_does_not_block_deliberate_quit():
    app = FinOpsApp(Engine(FakeBackend(), "2026-09"), Config(backend="fake"), first_run=False)
    started, release = threading.Event(), threading.Event()

    def operation(values, apply):
        if apply:
            started.set()
            release.wait(timeout=10)
        return {"action": "Read only", "preview": not apply}

    async with app.run_test(size=(80, 24)) as pilot:
        await settle(app, pilot)
        app.push_screen(ActionForm("Read only", [], operation, mutation=False))
        await pilot.pause()
        await pilot.click("#action-preview")
        await settle(app, pilot)
        app.screen.apply_action()
        try:
            await until(started.is_set, pilot)
            await pilot.press("ctrl+q")
            assert not app.screen.query_one("#quit-confirm", Button).disabled
            await pilot.press("q")
            assert not app.is_running
        finally:
            release.set()


@pytest.mark.parametrize("cancel_worker", [False, True])
async def test_signout_exits_only_after_its_completed_mutation(cancel_worker):
    app = FinOpsApp(Engine(FakeBackend(), "2026-09"), Config(backend="fake"), first_run=False)
    started, release = threading.Event(), threading.Event()
    effects = []

    def operation(values, apply):
        if apply:
            started.set()
            if not release.wait(timeout=10):
                raise AssertionError("Sign-out was not released.")
            effects.append("signed out")
            return {"ui_action": "signout"}
        return {"action": "Sign out"}

    async with app.run_test(size=(80, 24)) as pilot:
        await settle(app, pilot)
        app.push_screen(ActionForm("Sign out", [], operation))
        await pilot.pause()
        await pilot.click("#action-preview")
        await settle(app, pilot)
        screen = app.screen
        worker = screen.apply_action()
        try:
            await until(started.is_set, pilot)
            if cancel_worker:
                worker.cancel()
            await pilot.press("ctrl+q", "q")
            assert app.is_running and not effects
        finally:
            release.set()
        await until(lambda: not app.saving, pilot)
        await pilot.pause()
        assert not app.is_running, str(screen.query_one("#action-status", Static).render())
        assert effects == ["signed out"]


async def test_cancelled_failed_signout_stays_running_without_stale_progress():
    app = FinOpsApp(Engine(FakeBackend(), "2026-09"), Config(backend="fake"), first_run=False)
    started, release = threading.Event(), threading.Event()

    def operation(values, apply):
        if apply:
            started.set()
            release.wait(timeout=10)
            raise FinOpsError("Offline sign-out failed.", 7)
        return {"action": "Sign out"}

    async with app.run_test(size=(80, 24)) as pilot:
        await settle(app, pilot)
        app.push_screen(ActionForm("Sign out", [], operation))
        await pilot.pause()
        await pilot.click("#action-preview")
        await settle(app, pilot)
        screen = app.screen
        worker = screen.apply_action()
        try:
            await until(started.is_set, pilot)
            worker.cancel()
        finally:
            release.set()
        await until(lambda: not app.saving, pilot)
        assert app.is_running and not screen.busy
        assert "Offline sign-out failed" in str(screen.query_one("#action-status", Static).render())


async def test_successful_signout_waits_for_other_mutation_then_exits():
    app = FinOpsApp(Engine(FakeBackend(), "2026-09"), Config(backend="fake"), first_run=False)
    other_release = asyncio.Event()
    closed = []

    async def other_write():
        await other_release.wait()
        closed.append("other")

    def signout(values, apply):
        if apply:
            closed.append("signout")
            return {"ui_action": "signout"}
        return {"action": "Sign out"}

    async with app.run_test(size=(80, 24)) as pilot:
        await settle(app, pilot)
        app.run_worker(app.run_mutation(other_write()))
        await until(lambda: app.saving, pilot)
        app.push_screen(ActionForm("Sign out", [], signout))
        await pilot.pause()
        await pilot.click("#action-preview")
        await pilot.pause()
        screen = app.screen
        await until(lambda: screen.preview is not None, pilot)
        screen.apply_action()
        try:
            await until(lambda: "signout" in closed and not screen.busy, pilot)
            assert app.is_running and closed == ["signout"]
            message = str(screen.query_one("#action-status", Static).render())
            assert "Signed out" in message and "Saving once" not in message
        finally:
            other_release.set()
        await until(lambda: not app.saving, pilot)
        await pilot.pause()
        assert closed == ["signout", "other"] and not app.is_running


async def test_assistant_request_is_also_a_tracked_mutation():
    backend = PendingWrite("assistant_ask", {"assistant": True})
    app = FinOpsApp(Engine(backend, "2026-09"), Config(backend="fake"), first_run=False)
    async with app.run_test(size=(100, 36)) as pilot:
        await settle(app, pilot)
        app.action_tab("ask")
        await settle(app, pilot)
        await fill(app, pilot, "#ask-question", "Show token usage")
        await pilot.click("#ask-send")
        try:
            await until(backend.started.is_set, pilot)
            await pilot.press("ctrl+q", "q")
            assert app.is_running
            assert app.screen.query_one("#quit-confirm", Button).disabled
        finally:
            backend.release.set()
            assert await asyncio.to_thread(backend.completed.wait, 5)
        await settle(app, pilot)
        await pilot.press("escape")
        await pilot.pause()
        assert app.is_running and "Sales" in app.query_one("#ask-answer", TextArea).text
