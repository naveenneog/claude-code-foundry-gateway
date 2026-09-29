from copy import deepcopy

import pytest
from textual.widgets import Static

from p85_fixtures import EMAIL, USER, fill, management_app, select_developer, settle


ADDED_GROUP = "00000000-0000-0000-0000-000000000096"


async def removal_preview(app, pilot):
    await settle(app, pilot)
    await pilot.press("3")
    await settle(app, pilot)
    await pilot.press("h")
    await select_developer(app, pilot)
    await fill(app, pilot, "#field-confirm", EMAIL)
    await pilot.click("#action-preview")
    await settle(app, pilot)
    assert app.screen.preview is not None
    return deepcopy(app.screen.preview)


def change_state(state, drift, monkeypatch):
    if drift == "catalog":
        state.fake.catalog["organizations"].append({
            "id": "late-unit", "name": "Late unit", "attributes": {},
            "external_ref": f"entra-group:{ADDED_GROUP}",
        })
    elif drift == "tier":
        state.fake.tiers[0]["entra_group"] = ADDED_GROUP
    else:
        original = state.directory.resolve_exact
        resolved = 0

        def resolve(*args, **kwargs):
            nonlocal resolved
            resolved += 1
            person = original(*args, **kwargs)
            return person if resolved == 1 else dict(person, id="00000000-0000-0000-0000-000000000097")

        monkeypatch.setattr(state.directory, "resolve_exact", resolve)
    state.directory.direct.add(ADDED_GROUP)
    state.directory.group_members[ADDED_GROUP] = {USER}


@pytest.mark.parametrize("kind", ["direct", "turnstile"])
@pytest.mark.parametrize("drift", ["catalog", "tier", "identity"])
async def test_remove_rejects_drift_after_apply_repreview_before_write(monkeypatch, tmp_path, kind, drift):
    app, state = management_app(monkeypatch, tmp_path, kind)
    async with app.run_test(size=(100, 36)) as pilot:
        reviewed = await removal_preview(app, pilot)
        original = state.bridge
        reads = []

        def bridge(action, body=None, **params):
            snapshot = original(action, body, **params)
            if action == "read":
                reads.append(deepcopy(snapshot))
                if len(reads) == 1:
                    change_state(state, drift, monkeypatch)
            return snapshot

        monkeypatch.setattr(state, "bridge", bridge)
        await pilot.click("#action-apply")
        await settle(app, pilot)
        assert len(reads) == 2
        assert not state.directory.writes, "An unreviewed engine snapshot reached the Graph writer."
        assert not state.calls, "An unreviewed plan reached gateway publication."
        assert state.directory.group_members[ADDED_GROUP] == {USER}
        assert "changed since preview" in str(app.screen.query_one("#action-status", Static).render()).lower()
        assert app.screen.preview == reviewed


@pytest.mark.parametrize("kind", ["direct", "turnstile"])
async def test_remove_early_drift_has_domain_error_not_profile_transaction_error(monkeypatch, tmp_path, kind):
    app, state = management_app(monkeypatch, tmp_path, kind)
    async with app.run_test(size=(100, 36)) as pilot:
        await removal_preview(app, pilot)
        change_state(state, "catalog", monkeypatch)
        await pilot.click("#action-apply")
        await settle(app, pilot)
        assert app.is_running
        assert "changed since preview" in str(app.screen.query_one("#action-status", Static).render()).lower()
        assert not state.directory.writes and not state.calls
