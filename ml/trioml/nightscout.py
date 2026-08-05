"""Nightscout → export-schema converter (deep-history data source).

Trio uploads glucose (`entries`), carbs and boluses (`treatments`), and
determinations (`devicestatus`) to Nightscout, so a long-running Nightscout
site holds far more history than the phone's 90-day CoreData retention. This
module converts Nightscout API documents into the exact event dicts the in-app
`MLDataExporter` emits, so `dataset.build_frames` and everything downstream
work identically on either source.

Two ways in:

- offline: download `entries.json` / `treatments.json` yourself (or use an
  existing backup) and call `events_from_entries` / `events_from_treatments`.
- online: `fetch_events(base_url, days_back, token=...)` pages through the API
  with urllib. Read-only; a read token is sufficient.
"""

from __future__ import annotations

import json
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

PAGE_COUNT = 1000

# Nightscout eventTypes carrying carbs or boluses that Trio writes.
_CARB_EVENT_TYPES = {"Meal Bolus", "Carb Correction", "Snack Bolus", "Carbs"}


def _iso(document: dict, *keys: str) -> str | None:
    for key in keys:
        value = document.get(key)
        if value:
            return value
    return None


def events_from_entries(entries: list[dict]) -> list[dict]:
    """`/api/v1/entries` documents (sgv) → glucose events."""
    events = []
    for entry in entries:
        if entry.get("type") not in (None, "sgv"):
            continue
        sgv = entry.get("sgv")
        date_string = _iso(entry, "dateString", "sysTime")
        if sgv is None or not date_string:
            continue
        events.append({
            "type": "glucose",
            "date": date_string,
            "glucose": int(sgv),
            "direction": entry.get("direction"),
            "isManual": False,
        })
    return events


def events_from_treatments(treatments: list[dict]) -> list[dict]:
    """`/api/v1/treatments` documents → carbs + pump events."""
    events: list[dict] = []
    for treatment in treatments:
        created = _iso(treatment, "created_at", "timestamp")
        if not created:
            continue

        carbs = treatment.get("carbs")
        if carbs and (treatment.get("eventType") in _CARB_EVENT_TYPES or treatment.get("eventType") is None):
            events.append({
                "type": "carbs",
                "date": created,
                "carbs": float(carbs),
                "fat": float(treatment.get("fat") or 0),
                "protein": float(treatment.get("protein") or 0),
                "isFPU": bool(treatment.get("isFPU") or False),
            })

        insulin = treatment.get("insulin")
        if insulin:
            events.append({
                "type": "pump",
                "date": created,
                "eventType": "Bolus",
                "bolusAmount": float(insulin),
                "isSMB": treatment.get("eventType") == "SMB" or bool(treatment.get("isSMB") or False),
                "isExternal": bool(treatment.get("isExternal") or False),
                "tempBasalRate": None,
                "tempBasalDurationMinutes": None,
            })

        if treatment.get("eventType") == "Temp Basal" and treatment.get("rate") is not None:
            events.append({
                "type": "pump",
                "date": created,
                "eventType": "TempBasal",
                "bolusAmount": None,
                "isSMB": None,
                "isExternal": None,
                "tempBasalRate": float(treatment["rate"]),
                "tempBasalDurationMinutes": int(float(treatment.get("duration") or 0)),
            })
    return events


def fetch_events(
    base_url: str,
    days_back: int,
    token: str | None = None,
    now: datetime | None = None,
) -> list[dict]:
    """Pages entries + treatments out of a Nightscout site, newest→oldest."""
    now = now or datetime.now(timezone.utc)
    start = now - timedelta(days=days_back)
    events: list[dict] = []

    entries = _fetch_paged(
        base_url,
        "/api/v1/entries/sgv.json",
        {"find[dateString][$gte]": start.isoformat()},
        token,
    )
    events += events_from_entries(entries)

    treatments = _fetch_paged(
        base_url,
        "/api/v1/treatments.json",
        {"find[created_at][$gte]": start.isoformat()},
        token,
    )
    events += events_from_treatments(treatments)

    events.sort(key=lambda e: e["date"])
    return events


def _fetch_paged(base_url: str, path: str, find: dict, token: str | None) -> list[dict]:
    documents: list[dict] = []
    skip = 0
    while True:
        params = dict(find)
        params["count"] = str(PAGE_COUNT)
        params["skip"] = str(skip)
        if token:
            params["token"] = token
        url = base_url.rstrip("/") + path + "?" + urllib.parse.urlencode(params)
        with urllib.request.urlopen(url, timeout=60) as response:
            page = json.load(response)
        documents += page
        if len(page) < PAGE_COUNT:
            return documents
        skip += PAGE_COUNT
