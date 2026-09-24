import pytest

from claude_finops.rules import allocation_left, can_edit, month_window, parse_tokens, validate_budget
from claude_finops.errors import FinOpsError


@pytest.mark.parametrize("text,expected", [("2M", 2000000), ("1.5k", 1500), ("1,234", 1234)])
def test_token_amount(text, expected):
    assert parse_tokens(text) == expected


@pytest.mark.parametrize("text", ["0", "-1", "NaN", "inf", "0.1", "2usd", "1e25"])
def test_bad_token_amount(text):
    with pytest.raises(FinOpsError):
        parse_tokens(text)


@pytest.mark.parametrize("role,expected", [("owner", True), ("member", False), ("manager", False), ("admin", False), ("", False)])
def test_role_fails_closed(role, expected):
    assert can_edit({"role": role, "managed_units": ["sales"]}) is expected


def test_month_boundary():
    assert month_window("2026-12") == ("2026-12-01T00:00:00Z", "2027-01-01T00:00:00Z")
    with pytest.raises(FinOpsError):
        month_window("2026-13")


def test_headroom_excludes_edited_child():
    rows = [
        {"scope_type": "organization", "scope_id": "sales", "token_limit": 20},
        {"scope_type": "department", "scope_id": "sales-emea", "parent_scope_id": "sales", "token_limit": 8},
        {"scope_type": "department", "scope_id": "sales-apac", "parent_scope_id": "sales", "token_limit": 9},
    ]
    assert allocation_left(rows, rows[1], 10) == 1
    validate_budget(rows, rows[1], 10)
    with pytest.raises(FinOpsError, match="headroom"):
        validate_budget(rows, rows[1], 12)
    with pytest.raises(FinOpsError, match="allocated"):
        validate_budget(rows, rows[0], 16)


def test_unknown_parent_is_not_zero_headroom():
    row = {"scope_type": "organization", "scope_id": "sales", "token_limit": None}
    assert allocation_left([row], row, 10) is None

