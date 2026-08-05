"""Merging event streams from multiple sources into one deduplicated corpus.

The long-term training corpus is built from periodic in-app exports (the phone
only retains 90 days) plus Nightscout history. Sources overlap; this module
merges them with deterministic deduplication so re-running the merge is
idempotent.

Dedup key: (type, date, primary value) — two documents describing the same
physical event (a reading, a carb entry, a bolus, a temp basal) collapse to
one, with the *first* source in the argument order winning (pass the richer
source first, i.e. app exports before Nightscout).
"""

from __future__ import annotations


def _key(event: dict) -> tuple:
    kind = event["type"]
    if kind == "glucose":
        return (kind, event["date"], event.get("glucose"))
    if kind == "carbs":
        return (kind, event["date"], event.get("carbs"))
    if kind == "pump":
        return (kind, event["date"], event.get("bolusAmount"), event.get("tempBasalRate"))
    if kind == "determination":
        return (kind, event["date"])
    return (kind, event["date"])


def merge_events(*sources: list[dict]) -> list[dict]:
    """Concatenates sources, dedupes on `_key`, returns date-sorted events."""
    seen: set[tuple] = set()
    merged: list[dict] = []
    for source in sources:
        for event in source:
            key = _key(event)
            if key in seen:
                continue
            seen.add(key)
            merged.append(event)
    merged.sort(key=lambda e: (e["date"], e["type"]))
    return merged
