#!/usr/bin/env python3
"""Import source-backed observations without claiming an unmeasured release gate."""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Mapping
from uuid import UUID

if __package__:
    from .apple_latency_evidence import load_apple_journeys
else:
    from apple_latency_evidence import load_apple_journeys

SCHEMA_VERSION = 2
DEFAULT_CLIENTS = ("apple", "web", "flutter")
DEFAULT_CORPORA = ("epub", "selectable_text_pdf", "sideways_two_up_scanned_pdf")
DEFAULT_CACHE_STATES = ("cold", "relaunch_warm")
_POLICIES = ("normal", "reading_priority", "playback_priority", "resource_constrained")
# These require executable collectors/output checks, not user-supplied flags.
# Do not remove a requirement until its actual evidence adapter is implemented.
_PENDING_REQUIREMENTS = (
    "automated_collection_lifecycle",
    "representative_corpus_verification",
    "streaming_backend_correlation",
    "conversion_output_integrity_cli",
    "conversion_output_integrity_server",
    "web_profile_collection",
    "flutter_profile_collection",
)


class EvidenceError(ValueError):
    """Malformed or unsupported evidence; errors never echo content or paths."""


@dataclass(frozen=True)
class EvidenceSample:
    client: str
    runner: str
    execution_environment: str
    revision: str
    run_id: str
    source_sha256: str
    journey_ids: tuple[str, ...]
    corpus_kind: str
    corpus_sha256: str
    corpus_size_bytes: int
    corpus_page_count: int | None
    cache_state: str
    resource_policy: str
    boundaries_ms: Mapping[str, float]


@dataclass(frozen=True)
class EvidenceBundle:
    samples: tuple[EvidenceSample, ...]


def _object(value: object, fields: set[str], label: str) -> Mapping[str, Any]:
    if not isinstance(value, dict) or set(value) != fields:
        raise EvidenceError(f"{label} has missing or unsupported fields")
    return value


def _digest(value: object, size: int, label: str) -> str:
    if not isinstance(value, str) or not re.fullmatch(rf"[a-fA-F0-9]{{{size}}}", value):
        raise EvidenceError(f"{label} must be a hexadecimal digest")
    return value.lower()


def _positive_integer(value: object) -> int:
    if type(value) is not int or value <= 0:
        raise EvidenceError("corpus counts must be a positive integer")
    return value


def _identifier(value: object) -> str:
    try:
        if not isinstance(value, str) or str(UUID(value)) != value.lower():
            raise ValueError
        return str(UUID(value))
    except ValueError:
        raise EvidenceError("run and journey identifiers must be canonical UUIDs") from None


def _choice(value: object, allowed: tuple[str, ...], label: str) -> str:
    if not isinstance(value, str) or value not in allowed:
        raise EvidenceError(f"unsupported {label}")
    return value


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise EvidenceError("duplicate manifest field")
        result[key] = value
    return result


def _load_capture(value: object, root: Path) -> EvidenceSample:
    sample = _object(
        value,
        {
            "client",
            "runner",
            "execution_environment",
            "revision",
            "run_id",
            "source_sha256",
            "journeys",
            "corpus",
            "cache_state",
            "resource_policy",
        },
        "capture",
    )
    client = _choice(sample["client"], DEFAULT_CLIENTS, "client")
    if client != "apple":
        raise EvidenceError(
            "web and Flutter profile collectors are not available; leave their evidence pending"
        )
    environment = _choice(
        sample["execution_environment"],
        ("physical_device", "apple_ci"),
        "Apple environment: use a physical device or compatible Apple CI runner",
    )
    runner = sample["runner"]
    if not isinstance(runner, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}", runner):
        raise EvidenceError("runner must be a bounded technical model label, without paths or URLs")
    corpus = sample["corpus"]
    if not isinstance(corpus, dict) or not {"kind", "sha256", "size_bytes"} <= set(corpus) <= {
        "kind",
        "sha256",
        "size_bytes",
        "page_count",
    }:
        raise EvidenceError("corpus has missing or unsupported fields")
    kind = _choice(corpus["kind"], DEFAULT_CORPORA, "corpus kind")
    corpus_hash = _digest(corpus["sha256"], 64, "corpus sha256")
    size = _positive_integer(corpus["size_bytes"])
    pages = _positive_integer(corpus["page_count"]) if "page_count" in corpus else None
    if kind != "epub" and pages is None:
        raise EvidenceError("PDF corpus page_count is required")
    cache = _choice(sample["cache_state"], DEFAULT_CACHE_STATES, "cache state")
    policy = _choice(sample["resource_policy"], _POLICIES, "resource policy")
    revision = _digest(sample["revision"], 40, "revision")
    run_id = _identifier(sample["run_id"])
    digest = _digest(sample["source_sha256"], 64, "source sha256")
    journeys = _object(sample["journeys"], {"open", "play", "seek"}, "journeys")
    ids = {name: _identifier(identifier) for name, identifier in journeys.items()}
    try:
        boundaries = load_apple_journeys(
            root / "artifacts" / f"{digest}.json", digest, ids, corpus_kind=kind, cache_state=cache
        )
    except ValueError as error:
        raise EvidenceError(str(error)) from None
    return EvidenceSample(
        client,
        runner,
        environment,
        revision,
        run_id,
        digest,
        tuple(ids.values()),
        kind,
        corpus_hash,
        size,
        pages,
        cache,
        policy,
        boundaries,
    )


def _validate_identity(samples: Iterable[EvidenceSample]) -> tuple[EvidenceSample, ...]:
    samples = tuple(samples)
    runs: set[str] = set()
    journeys: set[str] = set()
    corpora: dict[str, tuple[str, int, int | None]] = {}
    for sample in samples:
        if sample.run_id in runs or journeys.intersection(sample.journey_ids):
            raise EvidenceError("run or journey identity was reused across captures")
        runs.add(sample.run_id)
        journeys.update(sample.journey_ids)
        metadata = (sample.corpus_kind, sample.corpus_size_bytes, sample.corpus_page_count)
        if corpora.setdefault(sample.corpus_sha256, metadata) != metadata:
            raise EvidenceError("the same corpus digest has conflicting metadata")
    return samples


def load_evidence(path: Path) -> EvidenceBundle:
    """Import an explicit local manifest and its content-addressed Apple exports."""
    try:
        payload = json.loads(path.read_bytes(), object_pairs_hook=_unique_object)
    except (OSError, UnicodeError, json.JSONDecodeError, RecursionError):
        raise EvidenceError("could not read evidence manifest") from None
    if not isinstance(payload, dict) or payload.get("schema_version") != SCHEMA_VERSION:
        raise EvidenceError(
            f"evidence schema_version must be {SCHEMA_VERSION}; manual summaries are not evidence"
        )
    payload = _object(payload, {"schema_version", "captures"}, "manifest")
    if not isinstance(payload["captures"], list):
        raise EvidenceError("captures must be an array")
    return EvidenceBundle(
        _validate_identity(_load_capture(value, path.parent) for value in payload["captures"])
    )


def percentile(values: Iterable[float], fraction: float) -> float:
    ordered = sorted(values)
    if not ordered or not 0 <= fraction <= 1:
        raise EvidenceError("percentile requires observations and a fraction between zero and one")
    offset = (len(ordered) - 1) * fraction
    lower, upper = math.floor(offset), math.ceil(offset)
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (offset - lower)


def _selection(values: Iterable[str], allowed: tuple[str, ...]) -> tuple[str, ...]:
    values = tuple(values)
    if (
        not values
        or any(value not in allowed for value in values)
        or len(values) != len(set(values))
    ):
        raise EvidenceError("required selections must be non-empty, supported and unique")
    return values


def evaluate(
    samples: Iterable[EvidenceSample],
    *,
    clients=DEFAULT_CLIENTS,
    corpora=DEFAULT_CORPORA,
    cache_states=DEFAULT_CACHE_STATES,
    required_samples=20,
    warm_budget_ms=200,
    cold_budget_ms=1000,
) -> dict[str, Any]:
    """Report comparable observation cohorts, separately from release readiness."""
    if type(required_samples) is not int or required_samples < 20:
        raise EvidenceError("required_samples must be an integer of at least 20")
    for budget in (warm_budget_ms, cold_budget_ms):
        if (
            isinstance(budget, bool)
            or not isinstance(budget, (int, float))
            or not math.isfinite(budget)
            or budget <= 0
        ):
            raise EvidenceError("budgets must be positive finite numbers")
    clients = _selection(clients, DEFAULT_CLIENTS)
    corpora = _selection(corpora, DEFAULT_CORPORA)
    cache_states = _selection(cache_states, DEFAULT_CACHE_STATES)
    grouped = defaultdict(list)
    references = {}
    for sample in _validate_identity(samples):
        key = (sample.client, sample.corpus_kind, sample.cache_state)
        cohort = (
            sample.corpus_sha256,
            sample.runner,
            sample.execution_environment,
            sample.revision,
            sample.resource_policy,
        )
        grouped[key, cohort].append(sample)
        references[(sample.client, sample.corpus_kind, cohort)] = sample
    buckets, missing, exceeded = [], [], []
    for client in clients:
        for corpus in corpora:
            conditions = [
                condition for c, kind, condition in references if (c, kind) == (client, corpus)
            ] or [None]
            for cache in cache_states:
                for condition in conditions:
                    values = grouped.get(((client, corpus, cache), condition), [])
                    summary = {
                        "client": client,
                        "corpus": corpus,
                        "cache_state": cache,
                        "sample_count": len(values),
                    }
                    if condition is not None:
                        first = references[(client, corpus, condition)]
                        summary.update(
                            {
                                name: getattr(first, name)
                                for name in (
                                    "corpus_sha256",
                                    "corpus_size_bytes",
                                    "corpus_page_count",
                                    "runner",
                                    "execution_environment",
                                    "revision",
                                    "resource_policy",
                                )
                            }
                        )
                    if values:
                        first = values[0]
                        summary["sources"] = sorted({sample.source_sha256 for sample in values})
                        summary["run_ids"] = [sample.run_id for sample in values]
                        summary["boundaries"] = {
                            boundary: {
                                "sample_count": len(values),
                                "p50_ms": round(
                                    percentile((s.boundaries_ms[boundary] for s in values), 0.5), 3
                                ),
                                "p95_ms": round(
                                    percentile((s.boundaries_ms[boundary] for s in values), 0.95), 3
                                ),
                            }
                            for boundary in first.boundaries_ms
                        }
                    if len(values) < required_samples:
                        missing.append({**summary, "required_sample_count": required_samples})
                    else:
                        budget = warm_budget_ms if cache == "relaunch_warm" else cold_budget_ms
                        summary["budget_ms"] = budget
                        summary["within_budget"] = True
                        for boundary in ("reader_usable", "audio_audible"):
                            latency = percentile(
                                (sample.boundaries_ms[boundary] for sample in values), 0.95
                            )
                            if latency > budget:
                                summary["within_budget"] = False
                                exceeded.append(
                                    {
                                        **{
                                            k: v
                                            for k, v in summary.items()
                                            if k not in ("boundaries", "sources", "run_ids")
                                        },
                                        "boundary": boundary,
                                        "p95_ms": latency,
                                    }
                                )
                    buckets.append(summary)
    observations_status = "failed" if exceeded else "pending" if missing else "passed"
    return {
        "schema_version": SCHEMA_VERSION,
        "status": "failed" if exceeded else "pending",
        "observations_status": observations_status,
        "evidence_class": "imported_diagnostics_not_verified_collection",
        "requirements": {
            "clients": list(clients),
            "corpora": list(corpora),
            "cache_states": list(cache_states),
            "samples_per_bucket": required_samples,
            "warm_budget_ms": warm_budget_ms,
            "cold_budget_ms": cold_budget_ms,
        },
        "buckets": buckets,
        "missing": missing,
        "budget_exceeded": exceeded,
        "pending_requirements": list(_PENDING_REQUIREMENTS),
        "optimization_queue": sorted(
            exceeded, key=lambda item: item["p95_ms"] / item["budget_ms"], reverse=True
        ),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--clients", default=",".join(DEFAULT_CLIENTS))
    parser.add_argument("--corpora", default=",".join(DEFAULT_CORPORA))
    parser.add_argument("--cache-states", default=",".join(DEFAULT_CACHE_STATES))
    parser.add_argument("--samples", type=int, default=20)
    parser.add_argument(
        "--strict", action="store_true", help="Fail until release evidence is complete"
    )
    args = parser.parse_args(argv)
    try:
        report = evaluate(
            load_evidence(args.evidence).samples,
            clients=args.clients.split(","),
            corpora=args.corpora.split(","),
            cache_states=args.cache_states.split(","),
            required_samples=args.samples,
        )
        output = json.dumps(report, indent=2, sort_keys=True)
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(output + "\n", encoding="utf-8")
    except (EvidenceError, OSError) as error:
        message = str(error) if isinstance(error, EvidenceError) else "could not write report"
        print(f"performance_evidence_gate: {message}", file=sys.stderr)
        return 2
    print(output)
    return 1 if args.strict or report["status"] == "failed" else 0


if __name__ == "__main__":
    raise SystemExit(main())
