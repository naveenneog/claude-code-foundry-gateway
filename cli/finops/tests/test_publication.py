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
