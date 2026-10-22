"""Typed CLI benchmark manifests and isolated, atomic persistence."""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping

PROJECT_ROOT = Path(__file__).resolve().parent.parent

SCHEMA_VERSION = 1
_ALLOWED_STATUSES = frozenset({"completed", "failed", "interrupted", "planned"})
_REQUIRED_ISOLATION_KEYS = ("persistent_root", "cache_dir", "output_dir")


class ManifestError(ValueError):
    """Raised when a benchmark manifest is malformed or unsafe."""


@dataclass(frozen=True)
class BenchmarkResult:
    """Normalized result from one benchmark profile."""

    path: Path
    schema_version: int
    run_id: str
    profile: dict[str, Any]
    isolation: dict[str, str]
    status: str
    started_at: float
    finished_at: float | None
    metrics: dict[str, Any]
    chapters: tuple[dict[str, Any], ...]
    error: str | None

    @property
    def is_complete(self) -> bool:
        """Whether the profile completed and has a finish timestamp."""
        return self.status == "completed" and self.finished_at is not None

    @property
    def wall_time_seconds(self) -> float:
        """Return measured wall time, deriving it from timestamps when needed."""
        value = _as_float(self.metrics.get("wall_time_seconds"))
        if value > 0:
            return value
        if self.finished_at is not None:
            return max(0.0, self.finished_at - self.started_at)
        return 0.0

    @property
    def total_chars(self) -> int:
        """Return the total number of source characters represented by the run."""
        value = self.metrics.get("total_chars")
        if value is not None:
            return max(0, _as_int(value))
        return sum(max(0, _as_int(chapter.get("chars"))) for chapter in self.chapters)

    @property
    def chars_per_second(self) -> float:
        """Return recorded or safely derived throughput."""
        value = _as_float(self.metrics.get("chars_per_second"))
        if value > 0:
            return value
        wall_time = self.wall_time_seconds
        return self.total_chars / wall_time if wall_time > 0 else 0.0

    @property
    def request_count(self) -> int:
        return max(0, _as_int(self.metrics.get("request_count")))

    @property
    def failures(self) -> int:
        return max(0, _as_int(self.metrics.get("failures")))

    @property
    def retries(self) -> int:
        return max(0, _as_int(self.metrics.get("retries")))

    @property
    def output_hash(self) -> str | None:
        value = self.metrics.get("output_hash")
        return str(value) if value else None


def _as_float(value: object) -> float:
    if value is None:
        return 0.0
    if isinstance(value, (int, float, str)):
        try:
            return float(value)
        except ValueError:
            return 0.0
    return 0.0


def _as_int(value: object) -> int:
    if value is None:
        return 0
    if isinstance(value, (int, float, str)):
        try:
            return int(value)
        except ValueError:
            return 0
    return 0


def _require_mapping(payload: object, label: str) -> Mapping[str, Any]:
    if not isinstance(payload, Mapping):
        raise ManifestError(f"manifest {label} must be an object")
    return payload


def _normalize_isolation(isolation: Mapping[str, Any]) -> dict[str, str]:
    normalized: dict[str, str] = {}
    for key in _REQUIRED_ISOLATION_KEYS:
        value = isolation.get(key)
        if not isinstance(value, str) or not value.strip():
            raise ManifestError(f"manifest isolation.{key} must be a path")
        normalized[key] = str(Path(value).expanduser().resolve())
    return normalized


def validate_isolated_paths(
    *,
    persistent_root: Path,
    cache_dir: Path,
    output_dir: Path,
    project_root: Path = PROJECT_ROOT,
) -> None:
    """Reject benchmark paths that could reuse the working tree.

    The directories do not need to exist yet. All paths are resolved before the
    containment checks, which also prevents a symlink under the project root
    from bypassing the safety guard.
    """
    project = Path(project_root).expanduser().resolve()
    persistent = Path(persistent_root).expanduser().resolve()
    cache = Path(cache_dir).expanduser().resolve()
    output = Path(output_dir).expanduser().resolve()

    if persistent == project or persistent.is_relative_to(project):
        raise ManifestError("benchmark persistent root must be isolated from the project root")
    if not cache.is_relative_to(persistent) or not output.is_relative_to(persistent):
        raise ManifestError("benchmark cache and output paths must stay inside the isolated root")
    if cache == persistent or output == persistent:
        raise ManifestError("benchmark cache and output paths must be subdirectories")


def _validate_payload(payload: Mapping[str, Any], *, path: Path) -> None:
    schema_version = payload.get("schema_version")
    if schema_version != SCHEMA_VERSION:
        raise ManifestError(f"manifest schema_version must be {SCHEMA_VERSION}")

    run_id = payload.get("run_id")
    if not isinstance(run_id, str) or not run_id.strip():
        raise ManifestError("manifest run_id must be a non-empty string")

    profile = _require_mapping(payload.get("profile"), "profile")
    if not profile.get("engine"):
        raise ManifestError("manifest profile.engine is required")

    isolation = _normalize_isolation(_require_mapping(payload.get("isolation"), "isolation"))
    validate_isolated_paths(
        persistent_root=Path(isolation["persistent_root"]),
        cache_dir=Path(isolation["cache_dir"]),
        output_dir=Path(isolation["output_dir"]),
    )

    status = payload.get("status")
    if status not in _ALLOWED_STATUSES:
        allowed = ", ".join(sorted(_ALLOWED_STATUSES))
        raise ManifestError(f"manifest status must be one of: {allowed}")

    started_at = _as_float(payload.get("started_at"))
    if started_at <= 0:
        raise ManifestError("manifest started_at must be a positive timestamp")

    finished_at = payload.get("finished_at")
    if finished_at is not None and _as_float(finished_at) <= 0:
        raise ManifestError("manifest finished_at must be a positive timestamp or null")
    if status == "completed" and finished_at is None:
        raise ManifestError("completed manifest requires finished_at")

    metrics = _require_mapping(payload.get("metrics", {}), "metrics")
    chapters = payload.get("chapters", [])
    if not isinstance(chapters, list):
        raise ManifestError("manifest chapters must be an array")
    for index, chapter in enumerate(chapters):
        if not isinstance(chapter, Mapping):
            raise ManifestError(f"manifest chapters[{index}] must be an object")

    # Keep this local variable explicit: it documents that the normalized paths
    # are validated even though callers may keep the original JSON payload.
    _ = (path, profile, isolation, metrics)


def _normalize_payload(payload: Mapping[str, Any], *, path: Path) -> BenchmarkResult:
    _validate_payload(payload, path=path)
    isolation = _normalize_isolation(_require_mapping(payload["isolation"], "isolation"))
    metrics = dict(_require_mapping(payload.get("metrics", {}), "metrics"))
    chapters = tuple(dict(chapter) for chapter in payload.get("chapters", []))
    finished_at = payload.get("finished_at")
    return BenchmarkResult(
        path=path,
        schema_version=int(payload["schema_version"]),
        run_id=str(payload["run_id"]),
        profile=dict(_require_mapping(payload["profile"], "profile")),
        isolation=isolation,
        status=str(payload["status"]),
        started_at=_as_float(payload["started_at"]),
        finished_at=_as_float(finished_at) if finished_at is not None else None,
        metrics=metrics,
        chapters=chapters,
        error=str(payload["error"]) if payload.get("error") else None,
    )


def load_manifest(path: Path) -> BenchmarkResult:
    """Load and validate a JSON manifest for one benchmark profile."""
    path = Path(path)
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise
    except (OSError, json.JSONDecodeError) as exc:
        raise ManifestError(f"could not read benchmark manifest {path}: {exc}") from exc
    if not isinstance(payload, Mapping):
        raise ManifestError("manifest root must be an object")
    return _normalize_payload(payload, path=path)


def write_manifest(path: Path, payload: Mapping[str, Any]) -> Path:
    """Validate and atomically write a benchmark manifest."""
    path = Path(path)
    _normalize_payload(payload, path=path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)
    return path
