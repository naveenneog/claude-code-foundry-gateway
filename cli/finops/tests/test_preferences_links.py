from pathlib import Path
import gzip
import base64
from urllib.parse import unquote
from uuid import uuid4

import pytest

from claude_finops.preferences import Preferences
from claude_finops.ledger import ledger_url
from claude_finops.errors import FinOpsError


def test_saved_views_are_per_identity_and_profile():
    root = Path(__file__).resolve().parents[3] / ".aum-evidence" / ("prefs-" + uuid4().hex)
    try:
        one = Preferences("person-one", "profile-one", root)
        two = Preferences("person-two", "profile-one", root)
        other = Preferences("person-one", "profile-two", root)
        one.save_view("Sales", {"tab": "usage", "month": "2026-09", "filters": {"organization_id": "sales"}})
        assert one.views()["Sales"]["filters"]["organization_id"] == "sales"
        assert two.views() == {} and other.views() == {}
        one.mark_toured()
        assert one.toured
        assert not two.toured
    finally:
        for file in root.glob("*"):
            file.unlink()
        root.rmdir()


def test_saved_views_reject_unknown_filters_and_unsafe_names():
    prefs = Preferences("person", "profile", memory=True)
    with pytest.raises(FinOpsError):
        prefs.save_view("../bad", {"tab": "usage"})
    with pytest.raises(FinOpsError):
        prefs.save_view("bad", {"filters": {"authorization": "not-a-token"}})


def test_ledger_link_uses_discovered_resource_and_exact_request_filter():
    resource = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-contoso/providers/Microsoft.OperationalInsights/workspaces/log-contoso"
    link = ledger_url(resource, "00000000-0000-0000-0000-000000000002", "request-123", "2026-09")
    assert unquote(resource) in unquote(link)
    encoded = link.split("/q/")[1].split("/timespan/")[0]
    query = gzip.decompress(base64.b64decode(unquote(unquote(encoded)))).decode()
    assert 'request_id == "request-123"' in query
    assert "2026-09-01" in query and "2026-10-01" in query
    with pytest.raises(FinOpsError):
        ledger_url("", "", "request-123", "2026-09")
