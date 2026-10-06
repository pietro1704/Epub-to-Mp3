from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

import pytest

_SCRIPT_PATH = Path(__file__).resolve().parents[2] / "scripts" / "benchmark_cli_performance.py"


def _load_module():
    spec = importlib.util.spec_from_file_location("benchmark_cli_performance", _SCRIPT_PATH)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


BENCH = _load_module()


def _manifest(**overrides: object) -> dict:
    payload = {
        "schema_version": 1,
        "run_id": "run-123",
        "profile": {
            "name": "baseline",
            "engine": "edge",
            "chapter_parallel": 4,
            "segment_seconds": 85,
        },
        "isolation": {
            "persistent_root": "/tmp/benchmark-root",
            "cache_dir": "/tmp/benchmark-root/.cache",
            "output_dir": "/tmp/benchmark-root/output",
        },
        "status": "completed",
        "started_at": 100.0,
        "finished_at": 112.5,
        "metrics": {
            "wall_time_seconds": 12.5,
            "total_chars": 1000,
            "chars_per_second": 80.0,
            "request_count": 4,
            "failures": 0,
            "retries": 1,
            "peak_rss_bytes": 1234,
            "peak_available_ram_bytes": 5678,
            "cache_bytes": 90,
            "output_hash": "sha256:abc",
        },
        "chapters": [{"path": "chapter-1.txt", "chars": 1000, "status": "completed"}],
    }
    payload.update(overrides)
    return payload


def test_parse_complete_manifest_returns_normalized_metrics(tmp_path: Path) -> None:
    path = tmp_path / "complete.json"
    path.write_text(json.dumps(_manifest()), encoding="utf-8")

    result = BENCH.load_manifest(path)

    assert result.status == "completed"
    assert result.is_complete is True
    assert result.total_chars == 1000
    assert result.wall_time_seconds == 12.5
    assert result.chars_per_second == 80.0
    assert result.request_count == 4
    assert result.failures == 0
    assert result.retries == 1
    assert result.output_hash == "sha256:abc"


def test_parse_failed_manifest_preserves_failure_reason(tmp_path: Path) -> None:
    path = tmp_path / "failed.json"
    payload = _manifest(
        status="failed",
        finished_at=110.0,
        error="edge unavailable",
        metrics={"wall_time_seconds": 10.0, "total_chars": 500, "failures": 2},
    )
    path.write_text(json.dumps(payload), encoding="utf-8")

    result = BENCH.load_manifest(path)

    assert result.status == "failed"
    assert result.is_complete is False
    assert result.failures == 2
    assert result.error == "edge unavailable"


def test_parse_interrupted_manifest_allows_missing_finish_time(tmp_path: Path) -> None:
    path = tmp_path / "interrupted.json"
    payload = _manifest(
        status="interrupted",
        finished_at=None,
        metrics={"wall_time_seconds": 8.0, "total_chars": 250, "failures": 0},
    )
    path.write_text(json.dumps(payload), encoding="utf-8")

    result = BENCH.load_manifest(path)

    assert result.status == "interrupted"
    assert result.is_complete is False
    assert result.finished_at is None
    assert result.total_chars == 250


def test_load_manifest_rejects_unknown_status(tmp_path: Path) -> None:
    path = tmp_path / "invalid.json"
    path.write_text(json.dumps(_manifest(status="running")), encoding="utf-8")

    with pytest.raises(BENCH.ManifestError, match="status"):
        BENCH.load_manifest(path)


def test_write_manifest_round_trips(tmp_path: Path) -> None:
    path = tmp_path / "nested" / "manifest.json"

    written = BENCH.write_manifest(path, _manifest())

    assert written == path
    assert BENCH.load_manifest(path).run_id == "run-123"


def test_validate_isolated_paths_rejects_project_root(tmp_path: Path) -> None:
    project_root = tmp_path / "project"
    project_root.mkdir()

    with pytest.raises(BENCH.ManifestError, match="isolated"):
        BENCH.validate_isolated_paths(
            persistent_root=project_root,
            cache_dir=project_root / ".cache",
            output_dir=project_root / "output",
            project_root=project_root,
        )


def test_validate_isolated_paths_accepts_private_temp_root(tmp_path: Path) -> None:
    project_root = tmp_path / "project"
    benchmark_root = tmp_path / "benchmark"
    project_root.mkdir()
    benchmark_root.mkdir()

    BENCH.validate_isolated_paths(
        persistent_root=benchmark_root,
        cache_dir=benchmark_root / ".cache",
        output_dir=benchmark_root / "output",
        project_root=project_root,
    )


def test_dry_run_materializes_text_manifest_in_isolated_root(tmp_path: Path) -> None:
    chapter = tmp_path / "chapter-one.txt"
    chapter.write_text("A short benchmark chapter.", encoding="utf-8")
    isolated_root = tmp_path / "isolated"
    manifest_path = tmp_path / "results" / "profile.json"

    result = BENCH.run_benchmark(
        inputs=[chapter],
        persistent_root=isolated_root,
        manifest_path=manifest_path,
        engine="edge",
        chapter_parallel=4,
        segment_seconds=120,
        dry_run=True,
        live_edge=False,
    )

    assert result.status == "planned"
    assert result.is_complete is False
    assert result.total_chars == len("A short benchmark chapter.")
    assert result.profile["chapter_parallel"] == 4
    assert result.profile["segment_seconds"] == 120
    assert result.isolation["persistent_root"] == str(isolated_root.resolve())
    assert manifest_path.exists()


def test_non_dry_run_refuses_network_without_explicit_live_edge(tmp_path: Path) -> None:
    chapter = tmp_path / "chapter-one.txt"
    chapter.write_text("No network should be touched.", encoding="utf-8")

    result = BENCH.run_benchmark(
        inputs=[chapter],
        persistent_root=tmp_path / "isolated",
        manifest_path=tmp_path / "refused.json",
        engine="edge",
        chapter_parallel=1,
        segment_seconds=85,
        dry_run=False,
        live_edge=False,
    )

    assert result.status == "failed"
    assert result.is_complete is False
    assert result.error == "live Edge execution requires --live-edge"
    assert result.request_count == 0


def test_runner_rejects_missing_input_before_writing_manifest(tmp_path: Path) -> None:
    manifest_path = tmp_path / "missing.json"

    with pytest.raises(BENCH.ManifestError, match="input"):
        BENCH.run_benchmark(
            inputs=[tmp_path / "missing.txt"],
            persistent_root=tmp_path / "isolated",
            manifest_path=manifest_path,
            engine="edge",
            chapter_parallel=1,
            segment_seconds=85,
            dry_run=True,
            live_edge=False,
        )

    assert not manifest_path.exists()
