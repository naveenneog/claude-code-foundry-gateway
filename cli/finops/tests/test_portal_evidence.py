from pathlib import Path
import json
from unittest.mock import patch

from claude_finops.publication import validate_portal_manifest


def test_portal_images_have_live_redacted_text_and_hash_provenance():
    folder = Path(__file__).resolve().parents[3] / "docs" / "images" / "aum-portal"
    assert not validate_portal_manifest(folder)


def test_portal_redaction_off_mutation_is_caught():
    folder = Path(__file__).resolve().parents[3] / "docs" / "images" / "aum-portal"
    data = json.loads((folder / "manifest.json").read_text(encoding="utf-8"))
    data["images"][0]["redaction"] = False
    data["auth_blocked"] = False
    original = Path.read_text
    def changed(path, *args, **kwargs):
        return json.dumps(data) if path == folder / "manifest.json" else original(path, *args, **kwargs)
    with patch.object(Path, "read_text", changed):
        assert any("must be live and redacted" in issue for issue in validate_portal_manifest(folder))


def test_clearing_auth_flag_does_not_accept_missing_required_portal_flow():
    folder = Path(__file__).resolve().parents[3] / "docs" / "images" / "aum-portal"
    data = json.loads((folder / "manifest.json").read_text(encoding="utf-8"))
    data["auth_blocked"] = False
    data["images"] = [entry for entry in data["images"] if entry["file"] != "workspace-logs.png"]
    original = Path.read_text
    def changed(path, *args, **kwargs):
        return json.dumps(data) if path == folder / "manifest.json" else original(path, *args, **kwargs)
    with patch.object(Path, "read_text", changed):
        assert any("required portal flow missing: workspace-logs.png" in issue
                   for issue in validate_portal_manifest(folder))


def test_log_editor_without_verified_query_results_is_not_evidence():
    folder = Path(__file__).resolve().parents[3] / "docs" / "images" / "aum-portal"
    data = json.loads((folder / "manifest.json").read_text(encoding="utf-8"))
    entry = dict(data["images"][0], file="workspace-logs.png", query_verified=False, query_rows=0)
    data["images"] = [row for row in data["images"] if row["file"] != "workspace-logs.png"] + [entry]
    original = Path.read_text
    with patch.object(Path, "read_text", lambda path, *args, **kwargs:
                      json.dumps(data) if path == folder / "manifest.json" else original(path, *args, **kwargs)):
        assert any("query result not verified" in issue for issue in validate_portal_manifest(folder))


def test_app_service_onboarding_overlay_is_not_completed_blade_evidence():
    folder = Path(__file__).resolve().parents[3] / "docs" / "images" / "aum-portal"
    original = Path.read_text
    with patch.object(Path, "read_text", lambda path, *args, **kwargs:
                      "Welcome to the App Service preview" if path.name == "turnstile-overview.txt"
                      else original(path, *args, **kwargs)):
        assert any("onboarding obscures" in issue for issue in validate_portal_manifest(folder))
