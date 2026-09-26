import json
from pathlib import Path

import pytest

from claude_finops.publication import validate_capture, validate_manifest
from claude_finops.redaction import Redactor


def entry(**updates):
    value = dict(file="turnstile-overview-80x24.svg", source="live", backend="Turnstile",
                 captured_at="2026-09-24T17:00:00Z", redaction=True, commit="a" * 40,
                 size=[80, 24], tab="overview", phase="after")
    value.update(updates)
    return value


@pytest.mark.parametrize("update", [{"redaction": False}, {"commit": ""}, {"captured_at": ""},
                                   {"source": "unknown"}, {"file": "..\\outside.svg"}])
def test_capture_manifest_rejects_false_or_incomplete_provenance(update):
    assert validate_capture("<svg><text>Contoso</text></svg>", entry(**update))


def test_disabled_redaction_mutation_cannot_be_published():
    redactor = Redactor(True)
    raw = {"email": "private@example.org"}
    assert not validate_capture(f"<svg><text>{redactor.present(raw)['email']}</text></svg>", entry())
    redactor.enabled = False
    assert validate_capture(f"<svg><text>{redactor.present(raw)['email']}</text></svg>", entry())


def test_docs_images_all_have_guarded_manifest_entries():
    folder = Path(__file__).resolve().parents[3] / "docs" / "images" / "aum"
    assert not validate_manifest(folder)


def test_every_required_live_tab_and_direct_overview_was_captured():
    from claude_finops.views import TABS
    folder = Path(__file__).resolve().parents[3] / "docs" / "images" / "aum"
    entries = json.loads((folder / "manifest.json").read_text(encoding="utf-8"))["images"]
    actual = {(e["backend"], e["tab"], tuple(e["size"])) for e in entries
              if e["source"] == "live" and e["redaction"] is True and e["phase"] == "after"}
    expected = {("Turnstile", tab, size) for tab, _ in TABS for size in ((80, 24), (160, 48))}
    expected |= {("Direct", "overview", size) for size in ((80, 24), (160, 48))}
    assert expected <= actual


def test_missing_manifest_entry_mutation_is_caught():
    from unittest.mock import patch
    folder = Path(__file__).resolve().parents[3] / "docs" / "images" / "aum"
    document = json.loads((folder / "manifest.json").read_text(encoding="utf-8"))
    document["images"].pop()
    original = Path.read_text
    def altered(path, *args, **kwargs):
        return json.dumps(document) if path == folder / "manifest.json" else original(path, *args, **kwargs)
    with patch.object(Path, "read_text", altered):
        assert any("no manifest" in problem for problem in validate_manifest(folder))
def test_capture_manifest_lock_rejects_overlapping_publishers():
    from claude_finops.publication import capture_lock
    from uuid import uuid4
    import pytest
    folder = Path(__file__).resolve().parents[3] / ".aum-evidence" / ("capture-lock-test-" + uuid4().hex)
    try:
        with capture_lock(folder):
            with pytest.raises(RuntimeError, match="capture"):
                with capture_lock(folder):
                    raise AssertionError("A second publisher must not acquire the manifest.")
        with capture_lock(folder):
            pass
    finally:
        folder.rmdir()


def test_independent_backends_have_live_redacted_tab_evidence():
    folder = Path(__file__).resolve().parents[3] / "docs" / "images" / "aum"
    entries = json.loads((folder / "manifest.json").read_text(encoding="utf-8"))["images"]
    actual = {(row["backend"], row.get("tab"), tuple(row.get("size", []))) for row in entries
              if row.get("source") == "live" and row.get("redaction") is True and row.get("phase") == "after"}
    from claude_finops.views import TABS
    expected = {("Direct", tab, size) for tab, _ in TABS for size in ((80, 24), (160, 48))}
    expected |= {("AUM service", tab, size) for tab in
        ("overview", "budgets", "people", "governance", "trends", "requests", "settings", "approvals")
        for size in ((80, 24), (160, 48))}
    assert expected <= actual
