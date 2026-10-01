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

`cli/finops/tests/aum_clock.py` owns the pinned clock contract: the pinned instant is
`2026-09-24T12:00:00Z`, the pinned month is `2026-09`, and `PinnedDateTime`
returns that instant plus real elapsed UTC time. It does not assign to
`datetime.datetime` in the stdlib module.

`cli/finops/tests/conftest.py` imports every `claude_finops` submodule once in a
session-scoped fixture. Any import failure is a test error naming the module. For
each normal test, an autouse fixture uses a local `pytest.MonkeyPatch` to set
`datetime` to `PinnedDateTime` on product modules and test/helper modules whose
`datetime` attribute is the stdlib class. It also installs a per-test import hook
scoped to `claude_finops`, `test_*` and `p85_fixtures` so local
`from datetime import datetime` statements in those modules receive
`PinnedDateTime`. The hook is restored after the test. Third-party modules and the
stdlib datetime module are not changed by the committed fixture.

Tests that need the workstation clock use `@pytest.mark.real_clock`; those tests
receive no AUM clock patch. Collection-time constants use `PINNED_MONTH` from the
helper instead of reading the clock at import. The fixture does not shift
`time.time()`: JWT token expiry is epoch-based
(`cli/finops/src/claude_finops/config.py:116`), and the P88 failures were month
comparisons through `datetime.now(timezone.utc)`.

## Consequences

- AUM tests using September fixtures remain in the product's current UTC month
  regardless of the date the suite runs.
- Timeout and duration tests keep advancing because the pinned clock is an
  offset clock, not a frozen instant.
- Module-level fixture constants such as `test_direct_speed.MONTH` are set from
  the helper's pinned month.
- New `claude_finops` modules that call `datetime.now(` are covered by a guard
  test that imports those modules, fails on import errors and verifies the pinned
  month within a bounded one-day window.
- `@pytest.mark.real_clock` tests and third-party modules see the real stdlib
  datetime module in normal committed runs.
