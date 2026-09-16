#!/usr/bin/env python3
"""Run a reproducible non-semantic baseline over the fixed synthetic test set.

This is deliberately simple: it groups tickets by the first obvious keyword
family. It is a quality reference, not a substitute for a human-time study.
"""

from __future__ import annotations

import json
import time
from collections import defaultdict
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
INPUT = ROOT / "data" / "evaluation-tickets.json"


def bucket(text: str) -> str:
    value = text.casefold().strip()
    if len(value) < 10:
        return "rejected_invalid"
    if "oauth" in value:
        return "oauth"
    if "reset" in value:
        return "password_reset"
    if "expired" in value:
        return "expired_card"
    if any(word in value for word in ("payment", "checkout", "safari")):
        return "payment_or_checkout"
    return "other"


def main() -> None:
    tickets = json.loads(INPUT.read_text(encoding="utf-8"))
    started = time.perf_counter()
    groups: dict[str, list[str]] = defaultdict(list)
    expected: dict[str, set[str]] = defaultdict(set)
    for ticket in tickets:
        group = bucket(str(ticket.get("text", "")))
        groups[group].append(ticket["case_id"])
        if ticket.get("expected_cluster"):
            expected[group].add(ticket["expected_cluster"])
    elapsed_ms = (time.perf_counter() - started) * 1000
    mixed_groups = {
        group: labels for group, labels in expected.items() if len(labels) > 1
    }
    print(
        json.dumps(
            {
                "baseline": "keyword-only, non-semantic proxy",
                "elapsed_ms": round(elapsed_ms, 3),
                "groups": dict(groups),
                "mixed_expected_groups": {k: sorted(v) for k, v in mixed_groups.items()},
                "note": "Use for quality comparison only; it is not a human-time baseline.",
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
