#!/usr/bin/env python3
"""Compare a recovered study data snapshot with unchanged live snapshots.

Only aggregate PASS/FAIL status is printed. No response content, comments,
participant identifiers, locations, or row digests are displayed.
"""
import json
import sys
from pathlib import Path


def snapshot(path):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8").strip())
    except (ValueError, OSError) as exc:
        raise SystemExit(f"FAIL: unreadable snapshot file ({Path(path).name})") from exc


def verify(before, after, recovered):
    tables = ("studies", "participants", "assignments", "responses")
    for table in tables:
        for report in (before, after, recovered):
            assert isinstance(report[table]["rows"], int), "Missing row count"
            assert report[table]["rows"] >= 0, "Invalid row count"
            assert len(report[table]["digest"]) == 32, "Missing row fingerprint"

        # A snapshot taken during pg_dump may capture a few additional inserts.
        # If rows changed while the dump ran, we cannot establish a strict
        # same-snapshot digest comparison; fail rather than overclaiming.
        if before[table] != after[table]:
            raise ValueError(
                f"{table}: live database changed during backup; "
                "repeat verification during a quiet period"
            )
        if recovered[table] != before[table]:
            raise ValueError(
                f"{table}: recovered counts or content differ from live snapshot"
            )

    r = recovered["responses"]
    if r["descriptions_present"] != r["rows"]:
        raise ValueError("responses: missing saved feeling descriptions")
    if r["notes_present"] > r["rows"]:
        raise ValueError("responses: impossible comment count")
    if r["note_characters"] < r["notes_present"]:
        raise ValueError("responses: inconsistent saved comment lengths")
    return r["rows"], r["notes_present"]


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit("Usage: compare-snapshots.py before.json after.json recovered.json")
    try:
        observations, notes = verify(*(snapshot(p) for p in sys.argv[1:]))
    except (ValueError, KeyError, TypeError, AssertionError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1) from None

    print(
        "PASS: restored study, memberships, original/current assignments, "
        "and all response fields match the live database row-for-row."
    )
    print(
        "PASS: saved feeling descriptions and optional free-text comments "
        "match the backup exactly. No blinded content was displayed."
    )
