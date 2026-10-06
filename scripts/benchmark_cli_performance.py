#!/usr/bin/env python3
"""Create and parse safe, isolated CLI performance benchmark manifests.

The parser is deliberately independent from Edge-TTS and filesystem scanning so
unit tests can validate complete, failed, and interrupted runs without network
access. The command-line runner is added below the parser contract and must use
an isolated persistent root for every benchmark.
"""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import os
import posixpath
import resource
import subprocess
import sys
import tempfile
import time
import uuid
import zipfile
from dataclasses import dataclass
from html.parser import HTMLParser
from pathlib import Path
from typing import Any, Iterable, Mapping

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


class _TextExtractor(HTMLParser):
    """Extract visible text from one EPUB HTML document."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []
        self._ignored_depth = 0

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag.lower() in {"script", "style", "svg"}:
            self._ignored_depth += 1

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() in {"script", "style", "svg"} and self._ignored_depth:
            self._ignored_depth -= 1

    def handle_data(self, data: str) -> None:
        if not self._ignored_depth:
            self.parts.append(data)

    def text(self) -> str:
        return " ".join(" ".join(self.parts).split())


@dataclass(frozen=True)
class _InputChapter:
    source: Path
    name: str
    text: str

    @property
    def chars(self) -> int:
        return len(self.text)


def _extract_epub_chapters(path: Path) -> list[_InputChapter]:
    """Read EPUB spine text without touching the application's cache."""
    from xml.etree import ElementTree as ET

    try:
        with zipfile.ZipFile(path) as archive:
            container = ET.fromstring(archive.read("META-INF/container.xml"))
            rootfile = container.find(".//{*}rootfile")
            opf_name = rootfile.attrib.get("full-path") if rootfile is not None else None
            if not opf_name:
                raise ManifestError(f"EPUB {path} has no OPF rootfile")
            opf = ET.fromstring(archive.read(opf_name))
            manifest: dict[str, tuple[str, str]] = {}
            for item in opf.findall(".//{*}manifest/{*}item"):
                item_id = item.attrib.get("id")
                href = item.attrib.get("href")
                media_type = item.attrib.get("media-type", "")
                if item_id and href and ("html" in media_type or "xhtml" in media_type):
                    manifest[item_id] = (href, item.attrib.get("properties", ""))

            spine_ids: list[str] = []
            for item in opf.findall(".//{*}spine/{*}itemref"):
                item_id = item.attrib.get("idref")
                if item_id:
                    spine_ids.append(item_id)
            if not spine_ids:
                spine_ids = list(manifest)
            base = posixpath.dirname(opf_name)
            chapters: list[_InputChapter] = []
            for index, item_id in enumerate(spine_ids, 1):
                item = manifest.get(item_id)
                if item is None:
                    continue
                href, _properties = item
                member = posixpath.normpath(posixpath.join(base, html.unescape(href)))
                try:
                    raw = archive.read(member).decode("utf-8", errors="replace")
                except KeyError:
                    continue
                parser = _TextExtractor()
                parser.feed(raw)
                text = parser.text()
                if text:
                    chapters.append(_InputChapter(path, f"{path.stem} chapter {index}", text))
            return chapters
    except (OSError, KeyError, ET.ParseError, zipfile.BadZipFile) as exc:
        raise ManifestError(f"could not read EPUB input {path}: {exc}") from exc


def _collect_input_chapters(inputs: Iterable[Path]) -> list[_InputChapter]:
    chapters: list[_InputChapter] = []
    for raw_path in inputs:
        path = Path(raw_path).expanduser().resolve()
        if not path.exists() or not path.is_file():
            raise ManifestError(f"benchmark input does not exist: {path}")
        suffix = path.suffix.lower()
        if suffix in {".txt", ".text"}:
            try:
                text = path.read_text(encoding="utf-8")
            except OSError as exc:
                raise ManifestError(f"could not read benchmark input {path}: {exc}") from exc
            chapters.append(_InputChapter(path, path.stem, text))
        elif suffix == ".epub":
            chapters.extend(_extract_epub_chapters(path))
        else:
            raise ManifestError(f"benchmark input must be .txt or .epub: {path}")
    if not chapters:
        raise ManifestError("benchmark input contains no readable chapters")
    return chapters


def _chapter_manifest_entries(
    chapters: Iterable[_InputChapter], status: str
) -> list[dict[str, Any]]:
    return [
        {
            "path": str(chapter.source),
            "name": chapter.name,
            "chars": chapter.chars,
            "status": status,
        }
        for chapter in chapters
    ]


def _new_run_id() -> str:
    return f"cli-{uuid.uuid4().hex[:12]}"


def _empty_metrics(total_chars: int, *, wall_time_seconds: float = 0.0) -> dict[str, Any]:
    return {
        "wall_time_seconds": round(max(0.0, wall_time_seconds), 3),
        "total_chars": max(0, int(total_chars)),
        "chars_per_second": 0.0,
        "request_count": 0,
        "failures": 0,
        "retries": 0,
        "peak_rss_bytes": 0,
        "peak_available_ram_bytes": 0,
        "cache_bytes": 0,
        "output_hash": None,
    }


def _directory_bytes(path: Path) -> int:
    return (
        sum(item.stat().st_size for item in path.rglob("*") if item.is_file())
        if path.exists()
        else 0
    )


def _output_hash(path: Path) -> str | None:
    files = sorted(item for item in path.rglob("*") if item.is_file()) if path.exists() else []
    if not files:
        return None
    digest = hashlib.sha256()
    for item in files:
        digest.update(str(item.relative_to(path)).encode("utf-8"))
        digest.update(item.read_bytes())
    return f"sha256:{digest.hexdigest()}"


def _memory_available_bytes() -> int:
    try:
        import psutil

        return int(psutil.virtual_memory().available)
    except Exception:
        return 0


def _child_peak_rss_bytes() -> int:
    value = int(resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss or 0)
    return value if sys.platform == "darwin" else value * 1024


def _runtime_metric_counts(cache_dir: Path) -> tuple[int, int, int]:
    requests = failures = retries = 0
    for path in cache_dir.rglob("*.jsonl") if cache_dir.exists() else []:
        try:
            lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            continue
        for line in lines:
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            event = str(record.get("event") or record.get("kind") or "").lower()
            if record.get("request_ms") is not None or "request" in event or "segment" in event:
                requests += 1
            if record.get("success") is False or record.get("status") in {"failed", "error"}:
                failures += 1
            retries += max(0, _as_int(record.get("retry_count") or record.get("retries")))
    return requests, failures, retries


def _write_text_fixture_epub(chapters: list[_InputChapter], target: Path) -> Path:
    """Materialize text inputs as a tiny EPUB inside the isolated root."""
    from xml.sax.saxutils import escape

    target.parent.mkdir(parents=True, exist_ok=True)
    opf_items: list[str] = []
    spine_items: list[str] = []
    html_files: list[tuple[str, str]] = []
    for index, chapter in enumerate(chapters, 1):
        item_id = f"chapter-{index}"
        href = f"chapter-{index:03d}.xhtml"
        body = escape(chapter.text).replace("\n", "<br/>\n")
        html_files.append((href, body))
        opf_items.append(f'<item id="{item_id}" href="{href}" media-type="application/xhtml+xml"/>')
        spine_items.append(f'<itemref idref="{item_id}"/>')
    opf = (
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="bookid">'
        '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>CLI benchmark</dc:title>'
        '<dc:language>en</dc:language></metadata>'
        f'<manifest>{"".join(opf_items)}</manifest><spine>{"".join(spine_items)}</spine></package>'
    )
    container = (
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
        '<rootfiles><rootfile full-path="OEBPS/content.opf" '
        'media-type="application/oebps-package+xml"/></rootfiles></container>'
    )
    with zipfile.ZipFile(target, "w") as archive:
        archive.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        archive.writestr("META-INF/container.xml", container)
        archive.writestr("OEBPS/content.opf", opf)
        for href, body in html_files:
            archive.writestr(
                f"OEBPS/{href}",
                f'<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml"><body>{body}</body></html>',
            )
    return target


def _prepare_live_input(chapters: list[_InputChapter], root: Path) -> list[Path]:
    sources = {chapter.source for chapter in chapters}
    if all(path.suffix.lower() in {".txt", ".text"} for path in sources):
        return [_write_text_fixture_epub(chapters, root / ".inputs" / "benchmark.epub")]
    if all(path.suffix.lower() == ".epub" for path in sources):
        return sorted(sources)
    raise ManifestError("mixing text and EPUB benchmark inputs is not supported")


def _run_live_cli(
    *,
    inputs: list[Path],
    root: Path,
    cache_dir: Path,
    output_dir: Path,
    engine: str,
    chapter_parallel: int,
    segment_seconds: int,
) -> tuple[int, float, int]:
    command = [
        sys.executable,
        str(PROJECT_ROOT / "python_app" / "convert"),
        *(str(path) for path in inputs),
        "--engine",
        engine,
        "--output-dir",
        str(output_dir),
        "--parallel-slots",
        str(chapter_parallel),
        "--edge-max-segment-seconds",
        str(segment_seconds),
        "--no-auto-validate-output",
        "--no-deep-validate",
        "--no-verify-transcription",
        "--no-verbose",
    ]
    environment = os.environ.copy()
    environment.update(
        {
            "PERSISTENT_ROOT": str(root),
            "CACHE_DIR": str(cache_dir),
            "OUTPUT_DIR": str(output_dir),
            "CHAPTER_PARALLEL_COUNT": str(chapter_parallel),
            "CHAPTER_PARALLEL_MAX": str(chapter_parallel),
        }
    )
    started = time.perf_counter()
    completed = subprocess.run(command, cwd=PROJECT_ROOT, env=environment, check=False)
    return completed.returncode, max(0.0, time.perf_counter() - started), _child_peak_rss_bytes()


def run_benchmark(
    *,
    inputs: Iterable[Path],
    persistent_root: Path,
    manifest_path: Path,
    engine: str,
    chapter_parallel: int,
    segment_seconds: int,
    dry_run: bool,
    live_edge: bool,
) -> BenchmarkResult:
    """Run or plan one profile using only an isolated cache/output root."""
    root = Path(persistent_root).expanduser().resolve()
    cache_dir = root / ".cache"
    output_dir = root / "output"
    validate_isolated_paths(
        persistent_root=root,
        cache_dir=cache_dir,
        output_dir=output_dir,
    )
    if chapter_parallel < 1:
        raise ManifestError("chapter_parallel must be at least 1")
    if segment_seconds < 1:
        raise ManifestError("segment_seconds must be positive")
    normalized_engine = str(engine).strip().lower()
    if normalized_engine not in {"edge", "piper", "auto"}:
        raise ManifestError("benchmark engine must be edge, piper, or auto")

    chapters = _collect_input_chapters(inputs)
    root.mkdir(parents=True, exist_ok=True)
    cache_dir.mkdir(parents=True, exist_ok=True)
    output_dir.mkdir(parents=True, exist_ok=True)
    run_id = _new_run_id()
    started_at = time.time()
    profile = {
        "name": run_id,
        "engine": normalized_engine,
        "chapter_parallel": int(chapter_parallel),
        "segment_seconds": int(segment_seconds),
        "live_edge": bool(live_edge),
    }
    isolation = {
        "persistent_root": str(root),
        "cache_dir": str(cache_dir),
        "output_dir": str(output_dir),
    }
    metrics = _empty_metrics(sum(chapter.chars for chapter in chapters))

    if dry_run:
        status = "planned"
        finished_at = None
        error = None
        chapter_status = "planned"
    elif not live_edge:
        status = "failed"
        finished_at = time.time()
        error = "live Edge execution requires --live-edge"
        chapter_status = "not_started"
    else:
        live_inputs = _prepare_live_input(chapters, root)
        before_available = _memory_available_bytes()
        return_code, wall_time, peak_rss = _run_live_cli(
            inputs=live_inputs,
            root=root,
            cache_dir=cache_dir,
            output_dir=output_dir,
            engine=normalized_engine,
            chapter_parallel=chapter_parallel,
            segment_seconds=segment_seconds,
        )
        after_available = _memory_available_bytes()
        request_count, failures, retries = _runtime_metric_counts(cache_dir)
        total_chars = sum(chapter.chars for chapter in chapters)
        metrics.update(
            {
                "wall_time_seconds": round(wall_time, 3),
                "chars_per_second": round(total_chars / wall_time, 3) if wall_time else 0.0,
                "request_count": request_count,
                "failures": failures if failures else (0 if return_code == 0 else 1),
                "retries": retries,
                "peak_rss_bytes": peak_rss,
                "peak_available_ram_bytes": max(before_available, after_available),
                "cache_bytes": _directory_bytes(cache_dir),
                "output_hash": _output_hash(output_dir),
            }
        )
        status = "completed" if return_code == 0 else "failed"
        finished_at = time.time()
        error = None if return_code == 0 else f"CLI exited with status {return_code}"
        chapter_status = "completed" if return_code == 0 else "failed"

    if status in {"planned", "failed"} and not live_edge:
        metrics["cache_bytes"] = _directory_bytes(cache_dir)
    payload = {
        "schema_version": SCHEMA_VERSION,
        "run_id": run_id,
        "profile": profile,
        "isolation": isolation,
        "status": status,
        "started_at": started_at,
        "finished_at": finished_at,
        "metrics": metrics,
        "chapters": _chapter_manifest_entries(chapters, chapter_status),
    }
    if error:
        payload["error"] = error
    write_manifest(Path(manifest_path), payload)
    return load_manifest(Path(manifest_path))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Run an isolated CLI conversion performance benchmark"
    )
    parser.add_argument("inputs", nargs="+", type=Path, help="Cached text chapters or EPUB inputs")
    parser.add_argument("--root", type=Path, help="Isolated benchmark persistent root")
    parser.add_argument("--manifest", type=Path, help="JSON result manifest path")
    parser.add_argument("--engine", choices=("edge", "piper", "auto"), default="edge")
    parser.add_argument("--chapter-parallel", type=int, default=1)
    parser.add_argument("--segment-seconds", type=int, default=85)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument(
        "--live-edge", action="store_true", help="Allow real Edge/network execution"
    )
    args = parser.parse_args(argv)

    root = args.root or Path(tempfile.mkdtemp(prefix="epub-cli-benchmark-"))
    run_id = _new_run_id()
    manifest = args.manifest or PROJECT_ROOT / "benchmarks" / "cli-performance" / f"{run_id}.json"
    try:
        result = run_benchmark(
            inputs=args.inputs,
            persistent_root=root,
            manifest_path=manifest,
            engine=args.engine,
            chapter_parallel=args.chapter_parallel,
            segment_seconds=args.segment_seconds,
            dry_run=args.dry_run,
            live_edge=args.live_edge,
        )
    except (ManifestError, OSError) as exc:
        print(f"benchmark_cli_performance: {exc}", file=sys.stderr)
        return 2
    print(f"status={result.status} chars={result.total_chars} manifest={manifest}")
    return 0 if result.status in {"planned", "completed"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
