from claude_finops.config import Config
from claude_finops.gateway_probe import tiny_request


def test_probe_preview_does_not_obtain_tokens_or_send_requests(monkeypatch):
    monkeypatch.setattr("claude_finops.gateway_probe.az", lambda *_: (_ for _ in ()).throw(AssertionError("No token before Apply")))
    result = tiny_request(Config())
    assert result["preview"]
    assert "real model tokens" in result["effect"]
