"""Dependency bootstrap tests inject every process effect and use temporary paths."""

from types import SimpleNamespace
from unittest.mock import Mock

import pytest
from src import _engine_selection_mixin as facade
from src.legacy_dependency_bootstrap import install_requirements


def _fixture(tmp_path):
    project = tmp_path / "project"
    source = project / "python_app" / "src" / "_engine_selection_mixin.py"
    source.parent.mkdir(parents=True)
    source.write_text("# fixture")
    requirement = project / "python_app" / "requirements.txt"
    requirement.write_text("fixture-only")
    return source, requirement


def test_module_location_selects_requirements_outside_checkout(tmp_path, monkeypatch):
    source, requirement = _fixture(tmp_path)
    outside = tmp_path / "outside"
    outside.mkdir()
    monkeypatch.chdir(outside)
    runner = Mock(return_value=SimpleNamespace(returncode=0))
    exec_process = Mock()
    assert install_requirements(
        SimpleNamespace(t=lambda key: key), source, process_runner=runner,
        exec_process=exec_process, python_executable="fixture-python", argv=["convert"],
    )
    runner.assert_called_once_with(
        ["fixture-python", "-m", "pip", "install", "-r", str(requirement)],
        check=False, capture_output=True, text=True,
    )
    exec_process.assert_not_called()


def test_facade_only_attempts_dependency_installation_once(tmp_path, monkeypatch):
    (tmp_path / "requirements.txt").write_text("fixture-only")
    monkeypatch.chdir(tmp_path)
    host = object.__new__(facade._EngineSelectionMixin)
    host._requirements_attempted = False
    host.loc = SimpleNamespace(t=lambda key: key)
    runner = Mock(return_value=SimpleNamespace(returncode=1, stderr="not available", stdout=""))
    monkeypatch.setattr(facade.subprocess, "run", runner)
    assert not host._install_requirements()
    assert not host._install_requirements()
    runner.assert_called_once()


def test_dependency_install_cancellation_propagates(tmp_path, monkeypatch):
    source, _ = _fixture(tmp_path)
    monkeypatch.chdir(tmp_path)
    runner = Mock(side_effect=KeyboardInterrupt)
    exec_process = Mock()
    with pytest.raises(KeyboardInterrupt):
        install_requirements(
            SimpleNamespace(t=lambda key: key), source, process_runner=runner,
            exec_process=exec_process, python_executable="fixture-python", argv=[],
        )
    exec_process.assert_not_called()
