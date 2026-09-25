from pathlib import Path
from uuid import uuid4
from unittest.mock import patch

import pytest
from textual.widgets import Input, Select, Static

from claude_finops.config import Config
from claude_finops.engine import Engine
from claude_finops.fake import FakeBackend
from claude_finops.tui import FinOpsApp
from claude_finops.errors import FinOpsError


async def settle(app, pilot):
    await pilot.pause(.3)
    await app.workers.wait_for_complete()
    await pilot.pause(.3)


@pytest.mark.parametrize("preview,redact", [(True, False), (False, True)])
async def test_ask_cannot_write_in_preview_or_redacted_mode(preview, redact):
    backend = FakeBackend(features={"assistant": True})
    app = FinOpsApp(Engine(backend, "2026-09"), Config(backend="fake"), preview_only=preview, redact=redact)
    async with app.run_test(size=(100, 32)) as pilot:
        await settle(app, pilot)
        app.action_tab("ask")
        await settle(app, pilot)
        app.query_one("#ask-question", Input).value = "Show usage"
        await pilot.click("#ask-send")
        await settle(app, pilot)
        assert not backend.writes


async def test_bulk_file_change_invalidates_preview():
    path = Path(__file__).resolve().parents[3] / ".aum-evidence" / f"bulk-review-{uuid4().hex}.csv"
    path.parent.mkdir(exist_ok=True)
    try:
        path.write_text("team,person,tokens\nsales-emea,dev-001@contoso.com,200000\n", encoding="utf-8")
        backend = FakeBackend()
        app = FinOpsApp(Engine(backend, "2026-09"), Config(backend="fake"))
        async with app.run_test(size=(100, 32)) as pilot:
            await settle(app, pilot)
            app.action_bulk()
            await pilot.pause(.2)
            app.screen.query_one("#field-file", Input).value = str(path)
            await pilot.click("#action-preview")
            await settle(app, pilot)
            assert "200000" in str(app.screen.query_one("#action-status", Static).render())
            path.write_text("team,person,tokens\nsales-emea,dev-001@contoso.com,500000\n", encoding="utf-8")
            await pilot.click("#action-apply")
            await settle(app, pilot)
            assert not backend.writes
            assert "changed since preview" in str(app.screen.query_one("#action-status", Static).render())
    finally:
        path.unlink(missing_ok=True)


async def test_same_tab_saved_view_refreshes_real_query_and_controls():
    backend = FakeBackend()
    app = FinOpsApp(Engine(backend, "2026-09"), Config(backend="fake"))
    async with app.run_test(size=(100, 32)) as pilot:
        await settle(app, pilot)
        app.action_tab("usage")
        await settle(app, pilot)
        count = len(backend.reads)
        app.restore_view(dict(tab="usage", month="2026-08", dimension="model",
                              filters={"department_id": "sales-apac"}))
        await settle(app, pilot)
        calls = backend.reads[count:]
        assert any(op == "distribution" and args["month"] == "2026-08" and args["dimension"] == "model"
                   and args["department_id"] == "sales-apac" for op, args in calls)
        assert app.query_one("#dimension", Select).value == "model"


async def test_failed_profile_switch_retains_current_session():
    backend = FakeBackend()
    app = FinOpsApp(Engine(backend, "2026-09"), Config(backend="fake"))
    class Failed(FakeBackend):
        def read(self, resource, **params):
            raise FinOpsError("Profile unavailable", 7)
    async with app.run_test(size=(100, 32)) as pilot:
        await settle(app, pilot)
        with patch("claude_finops.ui_features.connect", return_value=Failed()):
            await app.activate_profile(Config(backend="fake"))
        assert app.engine.backend is backend
        assert app.is_running
