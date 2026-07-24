"""Tests for scripts/heavy_job_guard.py — serialize heavy local jobs.

The guard exists to stop concurrent heavy work (xcodebuild / pytest / flutter)
from stacking on the user's panic-prone Intel 2018 Mac (CPU CATERR / PCIe↔T2
timeout). It must:
  - be a transparent pass-through off the constrained machine / when disabled,
  - serialize via an exclusive lock on the constrained machine,
  - fail fast (EX_TEMPFAIL=75) under NOWAIT when the lock is held.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "heavy_job_guard.py"


def _load_module():
    spec = importlib.util.spec_from_file_location("heavy_job_guard", SCRIPT)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def test_usage_error_without_separator() -> None:
    module = _load_module()
    assert module.main(["label", "echo", "hi"]) == 2


def test_passthrough_when_disabled(monkeypatch) -> None:
    module = _load_module()
    monkeypatch.setenv("HEAVY_JOB_GUARD_DISABLE", "1")
    # Should run the command directly (true => 0) without touching the lock.
    monkeypatch.setattr(module, "_acquire_lock", lambda label: pytest_fail())
    assert module.main(["build", "--", "true"]) == 0


def pytest_fail():  # pragma: no cover - helper sentinel
    raise AssertionError("_acquire_lock must not be called when disabled")


def test_passthrough_off_constrained_machine(monkeypatch) -> None:
    module = _load_module()
    monkeypatch.delenv("HEAVY_JOB_GUARD_DISABLE", raising=False)
    monkeypatch.setattr(module, "_is_constrained_intel_mac", lambda: False)
    monkeypatch.setattr(module, "_acquire_lock", lambda label: pytest_fail())
    assert module.main(["build", "--", "true"]) == 0


def test_serializes_on_constrained_machine(monkeypatch, tmp_path) -> None:
    module = _load_module()
    monkeypatch.delenv("HEAVY_JOB_GUARD_DISABLE", raising=False)
    monkeypatch.setattr(module, "_is_constrained_intel_mac", lambda: True)
    monkeypatch.setattr(module, "_load_too_high", lambda: False)
    monkeypatch.setattr(module, "_LOCK_PATH", str(tmp_path / "heavy.lock"))

    # First run acquires + releases cleanly.
    assert module.main(["build", "--", "true"]) == 0
    # Lock file is released; a second run also succeeds (no deadlock).
    assert module.main(["build", "--", "true"]) == 0


def test_nowait_fails_fast_when_lock_held(monkeypatch, tmp_path) -> None:
    import fcntl

    module = _load_module()
    monkeypatch.delenv("HEAVY_JOB_GUARD_DISABLE", raising=False)
    monkeypatch.setenv("HEAVY_JOB_GUARD_NOWAIT", "1")
    monkeypatch.setattr(module, "_is_constrained_intel_mac", lambda: True)
    monkeypatch.setattr(module, "_load_too_high", lambda: False)
    lock_path = str(tmp_path / "heavy.lock")
    monkeypatch.setattr(module, "_LOCK_PATH", lock_path)

    # Hold the lock from this test, then assert the guard refuses (75).
    holder = open(lock_path, "w")
    fcntl.flock(holder.fileno(), fcntl.LOCK_EX)
    try:
        try:
            module.main(["build", "--", "true"])
            raise AssertionError("expected SystemExit(75)")
        except SystemExit as exc:
            assert exc.code == 75
    finally:
        fcntl.flock(holder.fileno(), fcntl.LOCK_UN)
        holder.close()


def test_nowait_preserves_existing_holder_record(monkeypatch, tmp_path, capsys) -> None:
    import fcntl

    module = _load_module()
    monkeypatch.setenv("HEAVY_JOB_GUARD_NOWAIT", "1")
    monkeypatch.setattr(module, "_LOCK_PATH", str(tmp_path / "heavy.lock"))
    lock_path = Path(module._LOCK_PATH)
    lock_path.write_text("existing-build pid=123\n")
    holder = lock_path.open("r+")
    fcntl.flock(holder.fileno(), fcntl.LOCK_EX)
    try:
        try:
            module._acquire_lock("next-build")
        except SystemExit as exc:
            assert exc.code == 75
        assert "existing-build pid=123" in capsys.readouterr().err
        assert lock_path.read_text() == "existing-build pid=123\n"
    finally:
        fcntl.flock(holder.fileno(), fcntl.LOCK_UN)
        holder.close()


def test_nonzero_exit_propagates(monkeypatch, tmp_path) -> None:
    module = _load_module()
    monkeypatch.delenv("HEAVY_JOB_GUARD_DISABLE", raising=False)
    monkeypatch.setattr(module, "_is_constrained_intel_mac", lambda: True)
    monkeypatch.setattr(module, "_load_too_high", lambda: False)
    monkeypatch.setattr(module, "_LOCK_PATH", str(tmp_path / "heavy.lock"))
    rc = module.main(["build", "--", sys.executable, "-c", "import sys; sys.exit(3)"])
    assert rc == 3


def test_constrained_detection_non_darwin(monkeypatch) -> None:
    module = _load_module()
    monkeypatch.setattr(module.platform, "system", lambda: "Linux")
    assert module._is_constrained_intel_mac() is False
