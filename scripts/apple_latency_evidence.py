"""Derive timings from an explicitly selected, local Apple diagnostic export.

Artifact hashes establish byte identity, not authenticity or proof of relaunch.
Those properties belong to the collection harness and its execution evidence.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any, Mapping
from uuid import UUID

_DOCUMENT_KINDS = {
    "epub": "epub",
    "selectable_text_pdf": "selectable_text_pdf",
    "sideways_two_up_scanned_pdf": "normalized_scanned_pdf",
}
_KINDS = {
    "book_open": {
        "open_requested",
        "readable_content",
        "controls_usable",
        "first_pdf_page",
        "cancelled",
    },
    "progressive_playback": {"play_requested", "audio_queued", "audio_audible", "cancelled"},
    "seek": {"seek_requested", "seek_target_reached", "cancelled"},
}


def _object(value: object, fields: set[str]) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != fields:
        raise ValueError("Invalid Apple diagnostic fields")
    return value


def _uuid(value: object) -> str:
    if not isinstance(value, str):
        raise ValueError("Invalid Apple journey identifier")
    try:
        parsed = UUID(value)
    except ValueError:
        raise ValueError("Invalid Apple journey identifier") from None
    if str(parsed) != value.lower():
        raise ValueError("Invalid Apple journey identifier")
    return str(parsed)


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate Apple diagnostic field")
        result[key] = value
    return result


def _validate_journey(value: object) -> dict[str, Any]:
    journey = _object(value, {"id", "kind", "context", "records"})
    _uuid(journey["id"])
    kind = journey["kind"]
    if not isinstance(kind, str) or kind not in _KINDS:
        raise ValueError("Unsupported Apple journey kind")
    context = _object(journey["context"], {"documentKind", "cacheClass"})
    if context["documentKind"] not in tuple(_DOCUMENT_KINDS.values()):
        raise ValueError("Unsupported Apple document kind")
    if context["cacheClass"] not in ("unknown", "cold", "prepared_disk", "in_memory_warm"):
        raise ValueError("Unsupported Apple cache class")
    records = journey["records"]
    if not isinstance(records, list) or not records:
        raise ValueError("Missing Apple journey records")
    previous = 0
    for value in records:
        record = _object(value, {"transition", "elapsedNanoseconds"})
        transition = record["transition"]
        elapsed = record["elapsedNanoseconds"]
        if not isinstance(transition, str) or transition not in _KINDS[kind]:
            raise ValueError("Unsupported Apple journey transition")
        if type(elapsed) is not int or not previous <= elapsed <= 2**64 - 1:
            raise ValueError("Invalid Apple monotonic timing")
        previous = elapsed
    return journey


def _timings(journey: dict[str, Any], initial: str, required: tuple[str, ...]) -> dict[str, float]:
    records = journey["records"]
    if records[0] != {"transition": initial, "elapsedNanoseconds": 0}:
        raise ValueError("Missing Apple initial boundary")
    first: dict[str, float] = {}
    for index, record in enumerate(records):
        transition = record["transition"]
        if transition == "cancelled" or (index > 0 and transition == initial):
            raise ValueError("Selected Apple journey is cancelled or invalid")
        if transition == "audio_audible" and "audio_queued" not in first:
            raise ValueError("Apple audible boundary precedes queue readiness")
        if (
            transition in ("audio_queued", "audio_audible", "seek_target_reached")
            and transition in first
        ):
            raise ValueError("Duplicate Apple playback boundary")
        first.setdefault(transition, record["elapsedNanoseconds"] / 1_000_000)
    if any(boundary not in first for boundary in required):
        raise ValueError("Selected Apple journey is incomplete")
    return {boundary: first[boundary] for boundary in required}


def load_apple_journeys(
    artifact_path: Path,
    expected_sha256: str,
    journey_ids: Mapping[str, str],
    *,
    corpus_kind: str,
    cache_state: str,
) -> dict[str, float]:
    """Validate selected raw journeys and return their observed milliseconds."""
    if (
        not isinstance(expected_sha256, str)
        or len(expected_sha256) != 64
        or any(char not in "0123456789abcdef" for char in expected_sha256.lower())
    ):
        raise ValueError("Invalid Apple artifact digest")
    if not isinstance(journey_ids, Mapping) or set(journey_ids) != {"open", "play", "seek"}:
        raise ValueError("Apple evidence requires open, play and seek identifiers")
    ids = {name: _uuid(value) for name, value in journey_ids.items()}
    if len(set(ids.values())) != 3:
        raise ValueError("Apple journey identifiers must be distinct")
    if corpus_kind not in _DOCUMENT_KINDS or cache_state not in ("cold", "relaunch_warm"):
        raise ValueError("Unsupported Apple evidence context")
    try:
        raw = artifact_path.read_bytes()
    except OSError:
        raise ValueError("Could not read Apple diagnostic artifact") from None
    if hashlib.sha256(raw).hexdigest() != expected_sha256.lower():
        raise ValueError("Apple diagnostic artifact digest mismatch")
    try:
        payload = json.loads(raw, object_pairs_hook=_unique_object)
    except (UnicodeError, json.JSONDecodeError, RecursionError):
        raise ValueError("Invalid Apple diagnostic JSON") from None
    if not isinstance(payload, list):
        raise ValueError("Apple diagnostic export must be an array")
    journeys: dict[str, dict[str, Any]] = {}
    for value in payload:
        journey = _validate_journey(value)
        identifier = _uuid(journey["id"])
        if identifier in journeys:
            raise ValueError("Duplicate Apple journey identifier")
        journeys[identifier] = journey
    selected = {}
    for name, kind in (("open", "book_open"), ("play", "progressive_playback"), ("seek", "seek")):
        journey = journeys.get(ids[name])
        if journey is None or journey["kind"] != kind:
            raise ValueError("Selected Apple journey is missing or has the wrong kind")
        selected[name] = journey
    context = selected["open"]["context"]
    expected_cache = "cold" if cache_state == "cold" else "prepared_disk"
    if context != {"documentKind": _DOCUMENT_KINDS[corpus_kind], "cacheClass": expected_cache}:
        raise ValueError("Apple open context does not match the collection")
    open_boundaries = ("readable_content", "controls_usable")
    if corpus_kind != "epub":
        open_boundaries += ("first_pdf_page",)
    result = _timings(selected["open"], "open_requested", open_boundaries)
    result["reader_usable"] = max(result.values())
    result.update(_timings(selected["play"], "play_requested", ("audio_queued", "audio_audible")))
    result.update(_timings(selected["seek"], "seek_requested", ("seek_target_reached",)))
    return result
