#!/usr/bin/env python3
"""Validate cross-client latency evidence without inventing missing measurements.

The gate intentionally accepts only recorded observations.  It reports
``pending`` when the required physical/browser/profile evidence is absent and
only reports ``passed`` after every requested client/corpus/cache-state bucket
contains the requested number of samples.  This keeps synthetic unit results
from being mistaken for product-latency evidence.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Mapping

SCHEMA_VERSION = 1
DEFAULT_CLIENTS = ("apple", "web", "flutter")
DEFAULT_CORPORA = ("epub", "selectable_text_pdf", "sideways_two_up_scanned_pdf")
DEFAULT_CACHE_STATES = ("cold", "relaunch_warm")
_ALLOWED_CLIENTS = frozenset(DEFAULT_CLIENTS)
_ALLOWED_CORPORA = frozenset(DEFAULT_CORPORA)
_ALLOWED_CACHE_STATES = frozenset(DEFAULT_CACHE_STATES)
_ALLOWED_RESOURCE_POLICIES = frozenset(
    {"normal", "reading_priority", "playback_priority", "resource_constrained"}
)
_APPLE_EXECUTION_ENVIRONMENTS = frozenset({"physical_device", "apple_ci"})


class EvidenceError(ValueError):
    """Raised when an evidence bundle is malformed or unsafe to summarize."""


@dataclass(frozen=True)
class EvidenceSample:
    """One redacted, recorded listener-visible journey sample."""

    client: str
    runner: str
    execution_environment: str
    corpus_kind: str
    corpus_sha256: str
    corpus_size_bytes: int
    corpus_page_count: int | None
    cache_state: str
    resource_policy: str
    boundaries_ms: Mapping[str, float]


@dataclass(frozen=True)
class EvidenceBundle:
    """All client samples plus the two required conversion-integrity checks."""

    samples: tuple[EvidenceSample, ...]
    conversion_integrity: Mapping[str, bool]


def _require_mapping(value: object, label: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise EvidenceError(f"{label} must be an object")
    return value


def _require_string(value: object, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise EvidenceError(f"{label} must be a non-empty string")
    return value.strip()


def _require_positive_number(value: object, label: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise EvidenceError(f"{label} must be a positive number")
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise EvidenceError(f"{label} must be a positive number")
    return number


def _normalize_sample(value: object, index: int) -> EvidenceSample:
    sample = _require_mapping(value, f"samples[{index}]")
    client = _require_string(sample.get("client"), f"samples[{index}].client")
    if client not in _ALLOWED_CLIENTS:
        raise EvidenceError(f"samples[{index}].client is unsupported: {client}")
    runner = _require_string(sample.get("runner"), f"samples[{index}].runner")
    execution_environment = _require_string(
        sample.get("execution_environment"), f"samples[{index}].execution_environment"
    )
    if client == "apple" and execution_environment not in _APPLE_EXECUTION_ENVIRONMENTS:
        raise EvidenceError("Apple evidence must come from a physical device or compatible Apple CI runner")

    corpus = _require_mapping(sample.get("corpus"), f"samples[{index}].corpus")
    corpus_kind = _require_string(corpus.get("kind"), f"samples[{index}].corpus.kind")
    if corpus_kind not in _ALLOWED_CORPORA:
        raise EvidenceError(f"samples[{index}].corpus.kind is unsupported: {corpus_kind}")
    corpus_sha256 = _require_string(corpus.get("sha256"), f"samples[{index}].corpus.sha256").lower()
    if len(corpus_sha256) != 64 or any(character not in "0123456789abcdef" for character in corpus_sha256):
        raise EvidenceError(f"samples[{index}].corpus.sha256 must be a SHA-256 hex digest")
    corpus_size_bytes = int(_require_positive_number(corpus.get("size_bytes"), f"samples[{index}].corpus.size_bytes"))
    page_count_value = corpus.get("page_count")
    corpus_page_count = (
        int(_require_positive_number(page_count_value, f"samples[{index}].corpus.page_count"))
        if page_count_value is not None
        else None
    )

    cache_state = _require_string(sample.get("cache_state"), f"samples[{index}].cache_state")
    if cache_state not in _ALLOWED_CACHE_STATES:
        raise EvidenceError(f"samples[{index}].cache_state is unsupported: {cache_state}")
    resource_policy = _require_string(sample.get("resource_policy"), f"samples[{index}].resource_policy")
    if resource_policy not in _ALLOWED_RESOURCE_POLICIES:
        raise EvidenceError(f"samples[{index}].resource_policy is unsupported: {resource_policy}")

    boundaries = _require_mapping(sample.get("boundaries_ms"), f"samples[{index}].boundaries_ms")
    normalized_boundaries = {
        _require_string(name, f"samples[{index}].boundaries_ms key"): _require_positive_number(
            elapsed, f"samples[{index}].boundaries_ms.{name}"
        )
        for name, elapsed in boundaries.items()
    }
    if "reader_usable" not in normalized_boundaries:
        raise EvidenceError(f"samples[{index}].boundaries_ms.reader_usable is required")
    if "audio_audible" not in normalized_boundaries:
        raise EvidenceError(f"samples[{index}].boundaries_ms.audio_audible is required")
    return EvidenceSample(
        client=client,
        runner=runner,
        execution_environment=execution_environment,
        corpus_kind=corpus_kind,
        corpus_sha256=corpus_sha256,
        corpus_size_bytes=corpus_size_bytes,
        corpus_page_count=corpus_page_count,
        cache_state=cache_state,
        resource_policy=resource_policy,
        boundaries_ms=normalized_boundaries,
    )


def load_evidence(path: Path) -> EvidenceBundle:
    """Load one privacy-safe evidence bundle."""
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise EvidenceError(f"could not read evidence bundle {path}: {error}") from error
    bundle = _require_mapping(payload, "evidence bundle")
    if bundle.get("schema_version") != SCHEMA_VERSION:
        raise EvidenceError(f"evidence bundle schema_version must be {SCHEMA_VERSION}")
    samples = bundle.get("samples")
    if not isinstance(samples, list):
        raise EvidenceError("evidence bundle samples must be an array")
    integrity = _require_mapping(bundle.get("conversion_integrity", {}), "evidence bundle conversion_integrity")
    normalized_integrity: dict[str, bool] = {}
    for path_name in ("cli", "server"):
        value = integrity.get(path_name)
        if value is not None and not isinstance(value, bool):
            raise EvidenceError(f"evidence bundle conversion_integrity.{path_name} must be a boolean")
        if isinstance(value, bool):
            normalized_integrity[path_name] = value
    return EvidenceBundle(
        samples=tuple(_normalize_sample(sample, index) for index, sample in enumerate(samples)),
        conversion_integrity=normalized_integrity,
    )


def percentile(values: Iterable[float], fraction: float) -> float:
    """Return an interpolated percentile for a non-empty numeric series."""
    ordered = sorted(values)
    if not ordered:
        raise EvidenceError("cannot calculate a percentile with no samples")
    if not 0 <= fraction <= 1:
        raise EvidenceError("percentile fraction must be between zero and one")
    offset = (len(ordered) - 1) * fraction
    lower = math.floor(offset)
    upper = math.ceil(offset)
    if lower == upper:
        return ordered[lower]
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (offset - lower)


def evaluate(
    samples: Iterable[EvidenceSample],
    *,
    clients: Iterable[str] = DEFAULT_CLIENTS,
    corpora: Iterable[str] = DEFAULT_CORPORA,
    cache_states: Iterable[str] = DEFAULT_CACHE_STATES,
    required_samples: int = 20,
    warm_budget_ms: float = 200,
    cold_budget_ms: float = 1000,
    conversion_integrity: Mapping[str, bool] | None = None,
) -> dict[str, Any]:
    """Summarize evidence and report missing buckets or exceeded budgets."""
    if required_samples <= 0:
        raise EvidenceError("required_samples must be positive")
    required_clients = tuple(clients)
    required_corpora = tuple(corpora)
    required_cache_states = tuple(cache_states)
    if not set(required_clients).issubset(_ALLOWED_CLIENTS):
        raise EvidenceError("required clients contain an unsupported client")
    if not set(required_corpora).issubset(_ALLOWED_CORPORA):
        raise EvidenceError("required corpora contain an unsupported corpus")
    if not set(required_cache_states).issubset(_ALLOWED_CACHE_STATES):
        raise EvidenceError("required cache states contain an unsupported cache state")

    grouped: dict[tuple[str, str, str], list[EvidenceSample]] = defaultdict(list)
    for sample in samples:
        grouped[(sample.client, sample.corpus_kind, sample.cache_state)].append(sample)

    buckets: list[dict[str, Any]] = []
    missing: list[dict[str, Any]] = []
    exceeded: list[dict[str, Any]] = []
    for client in required_clients:
        for corpus in required_corpora:
            for cache_state in required_cache_states:
                bucket_samples = grouped[(client, corpus, cache_state)]
                summary: dict[str, Any] = {
                    "client": client,
                    "corpus": corpus,
                    "cache_state": cache_state,
                    "sample_count": len(bucket_samples),
                }
                if len(bucket_samples) < required_samples:
                    missing.append({**summary, "required_sample_count": required_samples})
                    buckets.append(summary)
                    continue
                boundary_summary: dict[str, dict[str, float]] = {}
                for boundary in ("reader_usable", "audio_audible"):
                    values = [sample.boundaries_ms[boundary] for sample in bucket_samples]
                    boundary_summary[boundary] = {
                        "p50_ms": round(percentile(values, 0.5), 3),
                        "p95_ms": round(percentile(values, 0.95), 3),
                    }
                summary["boundaries"] = boundary_summary
                budget = warm_budget_ms if cache_state == "relaunch_warm" else cold_budget_ms
                latency = max(boundary_summary["reader_usable"]["p95_ms"], boundary_summary["audio_audible"]["p95_ms"])
                summary["budget_ms"] = budget
                summary["within_budget"] = latency <= budget
                if latency > budget:
                    exceeded.append({**summary, "p95_ms": latency})
                buckets.append(summary)

    integrity = conversion_integrity or {}
    missing_integrity = [path_name for path_name in ("cli", "server") if path_name not in integrity]
    failed_integrity = [path_name for path_name in ("cli", "server") if integrity.get(path_name) is False]
    status = "pending" if missing or missing_integrity else "failed" if exceeded or failed_integrity else "passed"
    return {
        "schema_version": SCHEMA_VERSION,
        "status": status,
        "requirements": {
            "clients": list(required_clients),
            "corpora": list(required_corpora),
            "cache_states": list(required_cache_states),
            "samples_per_bucket": required_samples,
            "warm_budget_ms": warm_budget_ms,
            "cold_budget_ms": cold_budget_ms,
        },
        "buckets": buckets,
        "missing": missing,
        "budget_exceeded": exceeded,
        "conversion_integrity": {path_name: integrity.get(path_name) for path_name in ("cli", "server")},
        "missing_conversion_integrity": missing_integrity,
        "failed_conversion_integrity": failed_integrity,
        "optimization_queue": [
            {
                "client": item["client"],
                "corpus": item["corpus"],
                "cache_state": item["cache_state"],
                "boundary": "reader_usable_or_audio_audible",
                "p95_ms": item["p95_ms"],
                "budget_ms": item["budget_ms"],
            }
            for item in exceeded
        ],
    }


def _parse_csv(value: str) -> tuple[str, ...]:
    return tuple(part.strip() for part in value.split(",") if part.strip())


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Validate cross-client latency evidence")
    parser.add_argument("evidence", type=Path, help="Path to a recorded evidence JSON bundle")
    parser.add_argument("--output", type=Path, help="Write the gate report to this JSON path")
    parser.add_argument("--clients", default=",".join(DEFAULT_CLIENTS))
    parser.add_argument("--corpora", default=",".join(DEFAULT_CORPORA))
    parser.add_argument("--cache-states", default=",".join(DEFAULT_CACHE_STATES))
    parser.add_argument("--samples", type=int, default=20, help="Required samples per bucket")
    parser.add_argument("--strict", action="store_true", help="Return failure until all evidence is complete and in budget")
    args = parser.parse_args(argv)
    try:
        evidence = load_evidence(args.evidence)
        report = evaluate(
            evidence.samples,
            clients=_parse_csv(args.clients),
            corpora=_parse_csv(args.corpora),
            cache_states=_parse_csv(args.cache_states),
            required_samples=args.samples,
            conversion_integrity=evidence.conversion_integrity,
        )
    except EvidenceError as error:
        print(f"performance_evidence_gate: {error}", file=sys.stderr)
        return 2
    output = json.dumps(report, indent=2, sort_keys=True)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(output + "\n", encoding="utf-8")
    print(output)
    return 0 if report["status"] == "passed" or not args.strict else 1


if __name__ == "__main__":
    raise SystemExit(main())
