from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[3]
SERVER = "contoso-e8f7782d"
GROUP = "contoso-534a5930"


def section(text, heading):
    found = re.search(r"(?ms)^## " + re.escape(heading) + r"\b.*?(?=^## |\Z)", text)
    assert found, heading
    return found[0]


def deployment_names(text):
    return re.findall(r"\b(?:pg|rg|apim)-[a-z0-9-]+\b", text, re.IGNORECASE)


def test_p71_and_u32_public_text_use_the_inspected_capture_aliases():
    # The full heading: other sections, such as a follow-up, may also start with "P71".
    status = section((ROOT / "docs" / "STATUS.md").read_text(encoding="utf-8"),
                     "P71 AUM answers fast and says why it cannot")
    unknowns = (ROOT / "docs" / "UNKNOWNS.md").read_text(encoding="utf-8")
    row = next(line for line in unknowns.splitlines() if line.startswith("| U32 |"))
    detail = section(unknowns, "U32")
    for text in (status, row, detail):
        assert SERVER in text and GROUP in text
        assert deployment_names(text) == [], "Public P71 evidence uses capture aliases, not deployment names."


def test_p71_assumption_has_its_own_unknown_number():
    unknowns = (ROOT / "docs" / "UNKNOWNS.md").read_text(encoding="utf-8")
    row = next(line for line in unknowns.splitlines() if "Can the client identify the Turnstile database" in line)
    assert row.startswith("| U37 | ASSUMED |")
    assert "**U37**" in (ROOT / "docs" / "AUM.md").read_text(encoding="utf-8")
    assert "U37 records" in (ROOT / "docs" / "adr" / "0035-aum-bounded-readiness-and-progressive-reads.md").read_text(encoding="utf-8")
    assert "U37 deployment assumption" in (ROOT / "docs" / "architecture" / "15-aum-readiness.json").read_text(encoding="utf-8")


def test_public_name_detector_rejects_synthetic_private_resource_examples():
    assert deployment_names("PostgreSQL pg-private-example in rg-private-example") == [
        "pg-private-example", "rg-private-example"]
    assert deployment_names(f"PostgreSQL {SERVER} in {GROUP}") == []
