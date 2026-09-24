from copy import deepcopy
import json
from time import perf_counter

import pytest

from claude_finops.redaction import Redactor, privacy_problems

SENSITIVE = {
    "name": "Private Person", "email": "private.person@example.org",
    "tenant": "11111111-2222-3333-4444-555555555555",
    "url": "https://private-api.azurewebsites.net",
    "manager_scope": {"organizations": [{"id": "sales", "name": "Private Sales"}]},
    "items": [{"user_name": "Private Person", "actor": "private.person@example.org",
               "total_tokens": 123456, "estimated_cost": None, "scope_id": "sales",
               "description": "Private Person used the private service",
               "external_ref": "entra-group:Private Sales"}],
}


def test_redaction_is_deterministic_and_never_mutates_backend_data():
    original = deepcopy(SENSITIVE)
    first, second = Redactor(True), Redactor(True)
    rendered = first.present(SENSITIVE)
    assert rendered == second.present(SENSITIVE)
    assert SENSITIVE == original
    assert rendered["items"][0]["total_tokens"] == 123456
    assert rendered["items"][0]["estimated_cost"] is None
    encoded = json.dumps(rendered)
    assert "Private Person" not in encoded
    assert "Private Sales" not in encoded
    assert "example.org" not in encoded
    assert not privacy_problems(encoded)
    assert "contoso.com" in encoded


def test_redaction_masks_free_text_learned_names():
    redactor = Redactor(True)
    redactor.present(SENSITIVE)
    assert "Private Person" not in redactor.text("Activity by Private Person at private.person@example.org")


def test_redaction_off_mutation_is_caught():
    redactor = Redactor(True)
    assert not privacy_problems(json.dumps(redactor.present(SENSITIVE)))
    redactor.enabled = False
    leaked = json.dumps(redactor.present(SENSITIVE))
    assert privacy_problems(leaked), "The publication guard must catch disabled redaction."


@pytest.mark.parametrize("text", [
    "someone@fabrikam.com", "11111111-2222-3333-4444-555555555555",
    "https://private.azurewebsites.net", "private.azure-api.net",
])
def test_guard_rejects_identifiers_and_non_contoso_addresses(text):
    assert privacy_problems(text)
    assert not privacy_problems(Redactor(True).text(text))


def test_ids_and_names_are_redacted_consistently_in_nested_settings():
    data = {"user_id": "private.person@example.org", "user_name": "Private Person",
            "scope_id": "private-scope", "scope_name": "Private Business",
            "created_by": "private.person@example.org",
            "attributes": {"manager_group_id": "11111111-2222-3333-4444-555555555555"}}
    view = Redactor(True).present(data)
    assert view["user_id"] == view["created_by"]
    assert "Private" not in json.dumps(view)


def test_bounded_request_page_redaction_is_interactive():
    data = {"items": [{"request_id": f"request-{i:04}", "user_id": f"user-{i}@example.org",
                       "user_name": f"Private person {i}", "total_tokens": 1000} for i in range(200)]}
    redactor = Redactor(True)
    started = perf_counter()
    rendered = redactor.present(data)
    elapsed = perf_counter() - started
    assert not privacy_problems(json.dumps(rendered))
    assert elapsed < 2, f"Display redaction blocked a bounded request page for {elapsed:.2f}s"


def test_identity_strings_cannot_rewrite_schema_keys_or_status_enums():
    source = {"name": "status", "scope_name": "warning", "scope_id": "name",
              "scope_type": "organization", "status": "warning",
              "enforcement_modes": {"name": "notify"}}
    rendered = Redactor(True).present(source)
    assert set(rendered) == set(source)
    assert rendered["scope_type"] == "organization"
    assert rendered["status"] == "warning"
    assert rendered["enforcement_modes"][rendered["scope_id"]] == "notify"


def test_dynamic_identifier_keys_remain_private():
    source = {"attributes": {"11111111-2222-3333-4444-555555555555": "example"}}
    assert not privacy_problems(json.dumps(Redactor(True).present(source)))
