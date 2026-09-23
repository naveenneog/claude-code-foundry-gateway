"""Runs exported events through Turnstile's own ingest code.

    python tests/turnstile/check_contract.py <turnstile-checkout> <events.jsonl>

Imports turnstile_core from a Turnstile checkout and calls
UsageProcessor.process() on every event - the call that
functions/telemetry/function_app.py makes for each Event Hub message - with an
in-memory repository in place of PostgreSQL. It reports what Turnstile would
have stored.

It also runs controls: deliberately wrong events that exercise each Turnstile
rule the exporter is designed around. If Turnstile changes one of those rules,
a control changes result, and the design in docs/TURNSTILE.md needs revisiting
rather than the export quietly going wrong.

Needs Turnstile's Python dependencies (pydantic, psycopg). No database, no
Azure. Exit 0 only if every exported event is accepted exactly and every
control behaves as the design assumes.
"""
from __future__ import annotations

import copy
import json
import subprocess
import sys
from collections import Counter
from decimal import Decimal


class InMemoryRepository:
    """The four calls UsageProcessor makes, with no registry prices."""

    def __init__(self) -> None:
        self.records = []

    def model_prices(self):
        return {}

    def model_identities(self):
        return {}

    def gateway_application_attribution_map(self, gateway_profile_id):
        return []

    def write_token_usage(self, record, attribution):
        self.records.append(record)


def run(processor_cls, resolver_cls, events):
    repo = InMemoryRepository()
    processor = processor_cls(repo, resolver_cls({}))
    accepted = [processor.process(e) for e in events]
    return accepted, repo.records


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    checkout, events_path = sys.argv[1], sys.argv[2]
    sys.path.insert(0, checkout)
    from turnstile_core.ingestion.processor import CoefficientResolver, UsageProcessor

    commit = subprocess.run(
        ["git", "-C", checkout, "rev-parse", "--short", "HEAD"],
        capture_output=True, text=True, check=False,
    ).stdout.strip() or "unknown"

    with open(events_path, encoding="utf-8") as f:
        events = [json.loads(line) for line in f if line.strip()]
    if not events:
        print("No events to check.")
        return 2

    accepted, records = run(UsageProcessor, CoefficientResolver, events)
    by_id = {r.id: r for r in records}
    sent_cost = sum(Decimal(str(e.get("estimated_cost", 0))) for e in events)
    stored_cost = sum(Decimal(str(r.estimated_cost)) for r in records)

    # A stored row must carry exactly what was sent: same tokens, same cost,
    # not estimated. Anything else means Turnstile rewrote it.
    altered = []
    for e in events:
        r = by_id.get(e["id"])
        if r is None:
            continue
        if (r.input_tokens, r.output_tokens, r.cached_tokens) != (
            e["input_tokens"], e["output_tokens"], e["cached_tokens"]
        ) or r.estimated or Decimal(str(r.estimated_cost)) != Decimal(str(e.get("estimated_cost", 0))):
            altered.append(e["id"])

    # Controls, each on a copy of the first exported request event.
    base = next(e for e in events if not e["id"].startswith("claude-cache:"))
    controls = {}

    extra = copy.deepcopy(base)
    extra["id"] = extra["request_id"] = extra["correlation_id"] = "control-extra-field"
    extra["tier"] = "standard"
    ok, _ = run(UsageProcessor, CoefficientResolver, [extra])
    controls["unknown field is skipped"] = ok == [False]

    nulled = copy.deepcopy(base)
    nulled["id"] = nulled["request_id"] = nulled["correlation_id"] = "control-null-cache"
    nulled["cached_tokens"] = None
    ok, recs = run(UsageProcessor, CoefficientResolver, [nulled])
    controls["null cache zeroes the row and marks it estimated"] = (
        ok == [True] and recs[0].input_tokens == 0 and recs[0].output_tokens == 0 and recs[0].estimated
    )

    unpriced = copy.deepcopy(base)
    unpriced["id"] = unpriced["request_id"] = unpriced["correlation_id"] = "control-no-cost"
    unpriced.pop("estimated_cost", None)
    ok, recs = run(UsageProcessor, CoefficientResolver, [unpriced])
    controls["no cost and no registry price stores zero"] = ok == [True] and recs[0].estimated_cost == 0

    flagged = copy.deepcopy(base)
    ok, recs = run(UsageProcessor, CoefficientResolver, [flagged])
    controls["the cache-unmeasured flag survives ingest"] = (
        ok == [True] and recs[0].ingest_error == "stream_cache_usage_unavailable" and not recs[0].estimated
    )

    summary = {
        "turnstile_commit": commit,
        "sent": len(events),
        "accepted": sum(1 for a in accepted if a),
        "skipped": sum(1 for a in accepted if not a),
        "altered_on_ingest": len(altered),
        "estimated_rows": sum(1 for r in records if r.estimated),
        "input_tokens": sum(r.input_tokens for r in records),
        "output_tokens": sum(r.output_tokens for r in records),
        "cached_tokens": sum(r.cached_tokens for r in records),
        "cost_sent_usd": str(round(sent_cost, 6)),
        "cost_stored_usd": str(round(stored_cost, 6)),
        "ingest_sources": dict(Counter(r.ingest_source for r in records)),
        "ingest_errors": dict(Counter(r.ingest_error for r in records)),
        "usage_domains": dict(Counter(r.usage_domain for r in records)),
        "controls": controls,
    }
    print(json.dumps(summary, indent=2))
    exact = summary["skipped"] == 0 and summary["altered_on_ingest"] == 0 and sent_cost == stored_cost
    return 0 if exact and all(controls.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
