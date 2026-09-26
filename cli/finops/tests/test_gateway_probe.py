from claude_finops.config import Config
from claude_finops.gateway_probe import tiny_request


def test_probe_preview_does_not_obtain_tokens_or_send_requests(monkeypatch):
    monkeypatch.setattr("claude_finops.gateway_probe.az", lambda *_: (_ for _ in ()).throw(AssertionError("No token before Apply")))
    result = tiny_request(Config())
    assert result["preview"]
    assert "real model tokens" in result["effect"]


def test_example_backend_cannot_send_real_requests_even_with_address_fields(monkeypatch):
    import pytest
    from claude_finops.errors import FinOpsError
    calls = []
    monkeypatch.setattr("claude_finops.gateway_probe.az", lambda *args: calls.append(args) or "{}")
    with pytest.raises(FinOpsError, match="Example"):
        tiny_request(Config(backend="fake", resource_group="rg-contoso", apim_name="apim-contoso"), apply=True)
    assert not calls


def test_shared_probe_action_rechecks_owner_before_model_request(monkeypatch):
    import pytest
    from claude_finops.engine import Engine
    from claude_finops.fake import FakeBackend
    from claude_finops.errors import FinOpsError
    from claude_finops.group_actions import probe_gateway
    calls = []
    monkeypatch.setattr("claude_finops.gateway_probe.tiny_request", lambda *_args, **_kwargs: calls.append("model"))
    with pytest.raises(FinOpsError):
        probe_gateway(Engine(FakeBackend(role="member")), Config(backend="fake"), apply=True)
    assert not calls
