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
    original = Path.read_text
    def changed(path, *args, **kwargs):
        return json.dumps(data) if path == folder / "manifest.json" else original(path, *args, **kwargs)
    with patch.object(Path, "read_text", changed):
        assert validate_portal_manifest(folder)
