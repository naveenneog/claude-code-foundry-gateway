import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]


def prose(text):
    return re.sub(r"```.*?```", "", text, flags=re.S)


def test_aum_guide_has_one_installation_first_reading_order():
    text = (ROOT / "docs" / "AUM.md").read_text(encoding="utf-8")
    assert re.findall(r"^## (.+)$", text, re.M) == [
        "Install", "Connect", "First run and screen tour", "How-to", "Reference", "Troubleshooting"]
    install = text.split("## Install\n", 1)[1].split("## Connect\n", 1)[0]
    assert "Install-ClaudeAum.ps1" in install
    assert "Python 3.12" in install
    assert ".venv-finops/bin/activate" in install
    assert "PowerShell 7" in install


def test_aum_prose_describes_actions_rather_than_instructing_the_reader():
    text = prose((ROOT / "docs" / "AUM.md").read_text(encoding="utf-8"))
    paragraphs = []
    for paragraph in text.split("\n\n"):
        if not paragraph.strip() or paragraph.lstrip().startswith(("#", "|", "---")):
            continue
        paragraph = re.sub(r"(?m)^\s*(?:>\s*|\d+\.\s*|-\s*)", "", paragraph)
        paragraphs.append(" ".join(paragraph.split()))
    imperative = re.compile(
        r"(?:^|[.!?]\s+)(?:Then\s+)?(?:Run|Install|Choose|Use|Select|Click|Open|Read|Enter|"
        r"Check|Verify|Inspect|Copy|Keep|Preserve|Record|Wait|Allow|Publish|Follow|Put|"
        r"Set|Refresh|Reopen|Append|Start|Close|Turn|Do not|Never print)\b")
    offenders = [match.group() for paragraph in paragraphs for match in imperative.finditer(paragraph)]
    assert offenders == [], offenders


def test_aum_retains_dated_evidence_and_authority_references():
    text = (ROOT / "docs" / "AUM.md").read_text(encoding="utf-8")
    for evidence in (
        "4,096", "80.289", "26.498", "130.632", "321.264", "794.006", "160.156",
        "14 memberships", "2026-09-25T09:45:44Z",
        "guide/aum-p71-captures.json", "images/aum/manifest.json",
        "images/aum/turnstile-e2e-final-state-equal-restored.svg",
        "images/aum-portal/workspace-logs.png", "images/aum-portal/group-owners.png",
        "adr/0026-usd-budget-reconciliation.md", "adr/0035-aum-bounded-readiness-and-progressive-reads.md",
        "https://learn.microsoft.com/graph/api/group-post-members",
        "https://learn.microsoft.com/entra/identity-platform/access-tokens",
    ):
        assert evidence in text, evidence
    assert "snapshots/manifest.json" in text
    assert "historical" in text.lower() and "example" in text.lower()


def test_finops_guides_link_to_aum_instead_of_repeating_connection_steps():
    for name in ("FINOPS-TOOLS.md", "FINOPS.md", "CLI-FINOPS.md"):
        text = (ROOT / "docs" / name).read_text(encoding="utf-8")
        assert "AUM.md#install" in text, name
        assert "AUM.md#connect" in text, name
    tools = (ROOT / "docs" / "FINOPS-TOOLS.md").read_text(encoding="utf-8")
    direct_flow = tools.split("### Flow 3:", 1)[1].split("### Flow 4:", 1)[0]
    assert '"backend": "direct"' not in direct_flow
    assert "az login" not in direct_flow
