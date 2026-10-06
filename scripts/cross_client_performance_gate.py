#!/usr/bin/env python3
"""Validate deterministic, cross-client performance evidence cohorts."""

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

SCHEMA_VERSION = 1
CLIENTS = ("apple", "web", "flutter")
CORPORA = ("epub", "selectable_text_pdf", "sideways_two_up_scanned_pdf")
CACHE_STATES = ("cold", "relaunch_warm")
BOUNDARIES = ("client", "streaming_backend", "queue", "audible")


class EvidenceError(ValueError):
    """Evidence is malformed and cannot be evaluated."""


@dataclass(frozen=True)
class Sample:
    client: str
    corpus: str
    cache_state: str
    run_id: str
    revision: str
    runner: str
    execution_environment: str
    resource_policy: str
    corpus_sha256: str
    corpus_size_bytes: int
    boundaries_ms: Mapping[str, float]
    integrity: Mapping[str, bool]


def _object(value: object, required: set[str], label: str) -> Mapping[str, Any]:
    if not isinstance(value, dict) or not required <= set(value):
        raise EvidenceError(f"{label} has missing or unsupported fields")
    return value


def _choice(value: object, allowed: tuple[str, ...], label: str) -> str:
    if not isinstance(value, str) or value not in allowed:
        raise EvidenceError(f"unsupported {label}")
    return value


def _uuid(value: object, label: str) -> str:
    if not isinstance(value, str):
        raise EvidenceError(f"{label} must be a canonical UUID")
    try:
        parsed = UUID(value)
    except ValueError:
        raise EvidenceError(f"{label} must be a canonical UUID") from None
    if str(parsed) != value.lower():
        raise EvidenceError(f"{label} must be a canonical UUID")
    return str(parsed)


def _digest(value: object, label: str) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", value):
        raise EvidenceError(f"{label} must be a hexadecimal SHA-256 digest")
    return value.lower()


def _positive_integer(value: object, label: str) -> int:
    if type(value) is not int or value <= 0:
        raise EvidenceError(f"{label} must be a positive integer")
    return value


def _boundaries(value: object) -> dict[str, float]:
    if not isinstance(value, dict) or set(value) != set(BOUNDARIES):
        raise EvidenceError("boundaries_ms must contain the cross-client boundary schema")
    result = {}
    for name in BOUNDARIES:
        timing = value[name]
        if isinstance(timing, bool) or not isinstance(timing, (int, float)):
            raise EvidenceError("boundary timings must be finite non-negative numbers")
        if not math.isfinite(timing) or timing < 0:
            raise EvidenceError("boundary timings must be finite non-negative numbers")
        result[name] = float(timing)
    return result


def _integrity(value: object) -> dict[str, bool]:
    if value is None:
        return {"conversion": True, "output": True}
    if not isinstance(value, dict) or set(value) != {"conversion", "output"}:
        raise EvidenceError("integrity must contain conversion and output")
    if any(type(item) is not bool for item in value.values()):
        raise EvidenceError("integrity values must be boolean")
    return dict(value)


def _sample(value: object, corpora: Mapping[str, Mapping[str, Any]]) -> Sample:
    item = _object(
        value,
        {
            "client", "corpus", "cache_state", "run_id", "revision", "runner",
            "execution_environment", "resource_policy", "corpus_sha256", "corpus_size_bytes",
            "boundaries_ms",
        },
        "sample",
    )
    client = _choice(item["client"], CLIENTS, "client")
    corpus = _choice(item["corpus"], CORPORA, "corpus")
    if corpus not in corpora or not corpora[corpus].get("available", False):
        raise EvidenceError("sample references an unavailable corpus")
    cache = _choice(item["cache_state"], CACHE_STATES, "cache state")
    revision = _digest(item["revision"], "revision")
    corpus_hash = _digest(item["corpus_sha256"], "corpus_sha256")
    size = _positive_integer(item["corpus_size_bytes"], "corpus_size_bytes")
    runner = item["runner"]
    if not isinstance(runner, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}", runner):
        raise EvidenceError("runner must be a bounded technical label")
    environment = item["execution_environment"]
    if not isinstance(environment, str) or not environment:
        raise EvidenceError("execution_environment must be a non-empty string")
    policy = item["resource_policy"]
    if not isinstance(policy, str) or not policy:
        raise EvidenceError("resource_policy must be a non-empty string")
    return Sample(
        client, corpus, cache, _uuid(item["run_id"], "run_id"), revision, runner,
        environment, policy, corpus_hash, size, _boundaries(item["boundaries_ms"]),
        _integrity(item.get("integrity")),
    )


def _unique_json(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise EvidenceError("duplicate manifest field")
        result[key] = value
    return result


def load_manifest(path: Path) -> tuple[tuple[Sample, ...], dict[str, Any]]:
    """Load and validate a manifest without turning missing evidence into a pass."""
    try:
        payload = json.loads(path.read_bytes(), object_pairs_hook=_unique_json)
    except (OSError, UnicodeError, json.JSONDecodeError, RecursionError) as error:
        if isinstance(error, EvidenceError):
            raise
        raise EvidenceError("could not read evidence manifest") from None
    return load_manifest_from_payload(payload)


def load_manifest_from_payload(payload: object) -> tuple[tuple[Sample, ...], dict[str, Any]]:
    """Validate an already decoded manifest; useful for callers and unit tests."""
    if not isinstance(payload, dict) or payload.get("schema_version") != SCHEMA_VERSION:
        raise EvidenceError(f"schema_version must be {SCHEMA_VERSION}")
    _object(payload, {"schema_version", "collectors", "corpora", "samples"}, "manifest")
    collectors = _object(payload["collectors"], set(CLIENTS), "collectors")
    normalized_collectors = {}
    for client in CLIENTS:
        entry = _object(collectors[client], {"available"}, f"collector {client}")
        if type(entry["available"]) is not bool:
            raise EvidenceError("collector availability must be boolean")
        normalized_collectors[client] = {"available": entry["available"]}
    raw_corpora = _object(payload["corpora"], set(CORPORA), "corpora")
    normalized_corpora = {}
    for corpus in CORPORA:
        entry = _object(raw_corpora[corpus], {"available"}, f"corpus {corpus}")
        if type(entry["available"]) is not bool:
            raise EvidenceError("corpus availability must be boolean")
        normalized_corpora[corpus] = {"available": entry["available"]}
    if not isinstance(payload["samples"], list):
        raise EvidenceError("samples must be an array")
    samples = tuple(_sample(item, normalized_corpora) for item in payload["samples"])
    return samples, {"collectors": normalized_collectors, "corpora": normalized_corpora}


def _percentile(values: Iterable[float], fraction: float) -> float:
    ordered = sorted(values)
    if not ordered:
        raise EvidenceError("cannot calculate a percentile without samples")
    offset = (len(ordered) - 1) * fraction
    lower, upper = math.floor(offset), math.ceil(offset)
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (offset - lower)


def evaluate(
    samples: Iterable[Sample],
    *,
    collectors: Mapping[str, Mapping[str, bool]] | None = None,
    corpora: Mapping[str, Mapping[str, bool]] | None = None,
    required_samples: int = 20,
    cold_budget_ms: float = 1000,
    warm_budget_ms: float = 200,
) -> dict[str, Any]:
    """Evaluate every client/corpus/cache bucket; unavailable inputs stay pending."""
    if type(required_samples) is not int or required_samples != 20:
        raise EvidenceError("required_samples must be exactly 20")
    for budget in (cold_budget_ms, warm_budget_ms):
        if isinstance(budget, bool) or not isinstance(budget, (int, float)) or not math.isfinite(budget) or budget <= 0:
            raise EvidenceError("budgets must be positive finite numbers")
    collectors = collectors or {client: {"available": True} for client in CLIENTS}
    corpora = corpora or {corpus: {"available": True} for corpus in CORPORA}
    groups: dict[tuple[str, str, str], list[Sample]] = defaultdict(list)
    run_ids: set[str] = set()
    corpus_metadata: dict[str, tuple[str, int]] = {}
    for sample in samples:
        if sample.run_id in run_ids:
            raise EvidenceError("run_id was reused across samples")
        run_ids.add(sample.run_id)
        metadata = (sample.corpus_sha256, sample.corpus_size_bytes)
        previous = corpus_metadata.setdefault(sample.corpus, metadata)
        if previous != metadata:
            raise EvidenceError("corpus metadata differs within a corpus")
        groups[sample.client, sample.corpus, sample.cache_state].append(sample)
    buckets = []
    missing = []
    failures = []
    for client in CLIENTS:
        for corpus in CORPORA:
            available = collectors.get(client, {}).get("available", False) and corpora.get(corpus, {}).get("available", False)
            for cache in CACHE_STATES:
                values = groups[client, corpus, cache]
                bucket = {"client": client, "corpus": corpus, "cache_state": cache, "sample_count": len(values)}
                reasons = []
                if not collectors.get(client, {}).get("available", False):
                    reasons.append("collector_unavailable")
                if not corpora.get(corpus, {}).get("available", False):
                    reasons.append("corpus_unavailable")
                if len(values) < required_samples:
                    reasons.append("insufficient_samples")
                if reasons:
                    bucket["pending_reasons"] = reasons
                    missing.append(bucket)
                elif available:
                    integrity_ok = all(
                        sample.integrity["conversion"] and sample.integrity["output"]
                        for sample in values
                    )
                    bucket["boundaries"] = {
                        name: {"p50_ms": round(_percentile((sample.boundaries_ms[name] for sample in values), 0.5), 3),
                               "p95_ms": round(_percentile((sample.boundaries_ms[name] for sample in values), 0.95), 3)}
                        for name in BOUNDARIES
                    }
                    budget = warm_budget_ms if cache == "relaunch_warm" else cold_budget_ms
                    bucket["budget_ms"] = budget
                    bucket["integrity_ok"] = integrity_ok
                    bucket["within_budget"] = integrity_ok and all(
                        bucket["boundaries"][name]["p95_ms"] <= budget
                        for name in ("client", "audible")
                    )
                    if not bucket["within_budget"]:
                        if not integrity_ok:
                            bucket["integrity_failure"] = True
                        failures.append(bucket)
                buckets.append(bucket)
    status = "failed" if failures else "pending" if missing else "passed"
    return {
        "schema_version": SCHEMA_VERSION,
        "status": status,
        "requirements": {"clients": list(CLIENTS), "corpora": list(CORPORA), "cache_states": list(CACHE_STATES), "samples_per_bucket": required_samples},
        "buckets": buckets,
        "missing": missing,
        "budget_exceeded": failures,
        "optimization_queue": sorted(failures, key=lambda item: max(item["boundaries"][name]["p95_ms"] for name in ("client", "audible")) / item["budget_ms"], reverse=True),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--strict", action="store_true")
    args = parser.parse_args(argv)
    try:
        samples, metadata = load_manifest(args.manifest)
        report = evaluate(samples, **metadata)
    except (EvidenceError, OSError) as error:
        print(f"cross_client_performance_gate: {error}", file=sys.stderr)
        return 2
    print(json.dumps(report, indent=2, sort_keys=True))
    return 1 if args.strict and report["status"] != "passed" else 1 if report["status"] == "failed" else 0


if __name__ == "__main__":
    raise SystemExit(main())
