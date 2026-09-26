import pytest
from claude_finops.config import Config
from claude_finops.engine import Engine
from claude_finops.fake import FakeBackend
from claude_finops.errors import FinOpsError
from claude_finops.group_actions import publish_as_signed_in_admin


def test_delegated_preview_has_no_writer_calls(monkeypatch):
    backend = FakeBackend()
    backend.name = "Turnstile"
    monkeypatch.setattr("claude_finops.direct.DirectBackend._bridge",
                        lambda *_args, **_kwargs: (_ for _ in ()).throw(AssertionError("No publication before Apply")))
    plan = publish_as_signed_in_admin(Engine(backend), Config())
    assert plan["preview"] and not backend.writes
    assert "Distinct" in plan["effect"]


def test_viewer_cannot_invoke_delegated_admin_publication():
    backend = FakeBackend(role="member")
    backend.name = "Turnstile"
    with pytest.raises(FinOpsError):
        publish_as_signed_in_admin(Engine(backend), Config(), apply=True)
