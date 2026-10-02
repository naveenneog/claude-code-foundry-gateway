from __future__ import annotations

from datetime import datetime, timezone


PINNED_CLOCK_INSTANT = datetime(2026, 9, 24, 12, 0, 0, tzinfo=timezone.utc)
PINNED_MONTH = "2026-09"
_CLOCK_BASE = datetime.now(timezone.utc)


class PinnedDateTime(datetime):
    @classmethod
    def now(cls, tz=None):
        current = PINNED_CLOCK_INSTANT + (datetime.now(timezone.utc) - _CLOCK_BASE)
        if tz is None:
            return current.replace(tzinfo=None)
        return current.astimezone(tz)

    @classmethod
    def utcnow(cls):
        return cls.now(timezone.utc).replace(tzinfo=None)


