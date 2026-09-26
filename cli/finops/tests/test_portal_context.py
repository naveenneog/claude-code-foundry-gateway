import importlib.util
import json
from pathlib import Path

from claude_finops.config import Config
from claude_finops.errors import FinOpsError


def test_portal_context_reads_own_display_name_without_graph_subscription_argument(monkeypatch):
    path = Path(__file__).resolve().parents[1] / "tools" / "portal_context.py"
    spec = importlib.util.spec_from_file_location("portal_context_test", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    config = Config(resource_group="rg-contoso", apim_name="apim-contoso",
                    subscription="00000000-0000-0000-0000-000000000001")
    monkeypatch.setattr(module, "load_config", lambda _: config)
    monkeypatch.setattr(module, "discover", lambda **_: {"config": config.public(), "portal": {}})
    monkeypatch.setattr(module, "DirectBackend", lambda _: type("Backend", (), {
        "read": lambda *_: {"organizations": [], "departments": []}})())
    def az(*args):
        if args[:2] == ("account", "show"):
            return json.dumps({"name": "Contoso subscription"})
        if args[:3] == ("ad", "signed-in-user", "show"):
            assert "--subscription" not in args
            return json.dumps({"displayName": "Example owner"})
        raise FinOpsError("Not configured")
    monkeypatch.setattr(module, "az", az)
    result = module.context("unused")
    assert result["replacements"]["Example owner"] == "Contoso administrator"
