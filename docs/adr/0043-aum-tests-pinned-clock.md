# ADR-0043: AUM tests run under an advancing pinned UTC clock

## Status

Accepted for P88.

## Context

AUM fixtures use September 2026 data. The product deliberately treats only the
UTC wall-clock month as current: Direct budget writes compare the requested
month with `datetime.now(timezone.utc).strftime("%Y-%m")`
(`cli/finops/src/claude_finops/direct.py:424`), AUM service budget writes do the
same (`cli/finops/src/claude_finops/service_writes.py:13`), and `Engine`
defaults to the current UTC month (`cli/finops/src/claude_finops/engine.py:22`).
When main ran after 2026-10-01T00:00Z, September fixture tests no longer ran in
the product's current month.

The tests need deterministic fixture time without changing product behaviour.
The clock must keep advancing so durations, worker deadlines and timeout tests
remain meaningful. Some tests also compute fixture months at module import time,
so a per-test monkeypatch after collection is too late.

## Decision

`cli/finops/tests/conftest.py` patches the Python `datetime` module during test
collection so AUM tests import an advancing subclass whose base instant is
`2026-09-24T12:00:00Z`. The fixture then repatches loaded `claude_finops` and
test helper modules before each test so modules that imported `datetime` before
collection also see the pinned clock. The pinned clock adds real elapsed UTC time
to the base instant.

Tests that need the real workstation clock opt out with `@pytest.mark.real_clock`.
The fixture does not shift `time.time()`: JWT token expiry is epoch-based
(`cli/finops/src/claude_finops/config.py:116`), and the P88 failures were all
month comparisons through `datetime.now(timezone.utc)`.

## Consequences

- AUM tests using September fixtures remain in the product's current UTC month
  regardless of the date the suite runs.
- Timeout and duration tests keep advancing because the pinned clock is an
  offset clock, not a frozen instant.
- Module-level fixture constants such as `test_direct_speed.MONTH` are computed
  from the pinned clock during collection.
- New `claude_finops` modules that call `datetime.now(` are covered by a guard
  test that imports those modules and asserts they see the pinned hour.
