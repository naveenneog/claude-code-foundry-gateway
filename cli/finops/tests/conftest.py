from __future__ import annotations

import datetime as _datetime_module
import sys
from datetime import datetime as _real_datetime, timezone

import pytest


PINNED_CLOCK_INSTANT = _real_datetime(2026, 9, 24, 12, 0, 0, tzinfo=timezone.utc)
_CLOCK_BASE = _real_datetime.now(timezone.utc)


class _PinnedDateTime(_real_datetime):
    @classmethod
    def now(cls, tz=None):
        current = PINNED_CLOCK_INSTANT + (_real_datetime.now(timezone.utc) - _CLOCK_BASE)
        if tz is None:
            return current.replace(tzinfo=None)
        return current.astimezone(tz)

    @classmethod
    def utcnow(cls):
        return cls.now(timezone.utc).replace(tzinfo=None)


_datetime_module.datetime = _PinnedDateTime


def pytest_configure(config):
    config.addinivalue_line("markers", "real_clock: opt out of the AUM pinned UTC clock")


def _patch_datetime(target):
    for name, module in list(sys.modules.items()):
        if not module or not name.startswith(target):
            continue
        if getattr(module, "datetime", None) in {_real_datetime, _PinnedDateTime}:
            setattr(module, "datetime", _PinnedDateTime if target == "claude_finops" else _datetime_module.datetime)


@pytest.fixture(autouse=True)
def _pin_aum_clock(request):
    if request.node.get_closest_marker("real_clock"):
        changed = []
        _datetime_module.datetime = _real_datetime
        for name, module in list(sys.modules.items()):
            if module and (name.startswith("claude_finops") or name.startswith("test_") or name == "p85_fixtures"):
                if getattr(module, "datetime", None) is _PinnedDateTime:
                    changed.append(module)
                    setattr(module, "datetime", _real_datetime)
        yield
        _datetime_module.datetime = _PinnedDateTime
        for module in changed:
            setattr(module, "datetime", _PinnedDateTime)
        return

    _datetime_module.datetime = _PinnedDateTime
    _patch_datetime("claude_finops")
    for name, module in list(sys.modules.items()):
        if module and (name.startswith("test_") or name == "p85_fixtures"):
            if getattr(module, "datetime", None) in {_real_datetime, _PinnedDateTime}:
                setattr(module, "datetime", _PinnedDateTime)
    yield
