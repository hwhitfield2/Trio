"""Versioned schema shared with the Swift exporter (BaseMLDataExporter).

The Swift side stamps `schemaVersion` into the export header; this module is
the single Python-side source of truth for what that version means. Golden-file
parity tests on both sides keep train/serve skew impossible.
"""

from __future__ import annotations

EXPORT_SCHEMA_VERSION = 1

# Event line types emitted by the exporter, in file order.
EVENT_TYPES = ("header", "glucose", "carbs", "pump", "determination")

# Training frame grid.
FRAME_INTERVAL_MINUTES = 5
HISTORY_MINUTES = 6 * 60           # model input window
HORIZON_MINUTES = 6 * 60           # prediction horizon; must cover max(LABEL_HORIZONS_MINUTES)
LABEL_HORIZONS_MINUTES = (30, 60, 120, 240, 360)  # backtest/gate evaluation points

# Physiological bounds used for sanity filtering, mg/dL.
GLUCOSE_MIN = 20
GLUCOSE_MAX = 500

# Low-glucose region for gate metrics, mg/dL.
LOW_REGION_THRESHOLD = 80


class SchemaError(ValueError):
    """Raised on any schema mismatch — never silently skipped."""


def validate_header(header: dict) -> None:
    if header.get("type") != "header":
        raise SchemaError(f"first line is not a header: {header!r}")
    version = header.get("schemaVersion")
    if version != EXPORT_SCHEMA_VERSION:
        raise SchemaError(
            f"export schemaVersion {version} != expected {EXPORT_SCHEMA_VERSION}; "
            "update trioml or re-export from the app"
        )
