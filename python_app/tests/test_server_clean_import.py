"""Exercise bootstrap order without a previously initialized server facade."""

import os
import subprocess
import sys
from pathlib import Path

import pytest


@pytest.mark.parametrize("module_name", ["server", "python_app.server"])
def test_server_bootstrap_in_fresh_process(module_name, tmp_path):
    repository = Path(__file__).resolve().parents[2]
    environment = os.environ.copy()
    environment.update(
        PYTHONPATH=os.pathsep.join((str(repository / "python_app"), str(repository))),
        PERSISTENT_ROOT=str(tmp_path / "persistent"),
        OUTPUT_DIR=str(tmp_path / "output"),
        CACHE_DIR=str(tmp_path / "cache"),
        DISABLE_TORCH="1",
        DISABLE_AUTO_RECOVERY="1",
        ENABLE_AUTO_TUNING="0",
        CLEANUP_INTERVAL_SECONDS="17",
    )
    result = subprocess.run(
        [
            sys.executable,
            "-c",
            "import importlib, inspect, os, sys; "
            "server = importlib.import_module(sys.argv[1]); "
            "assert server.app.title == 'EPUB to MP3 Converter API'; "
            "assert server.get_cleanup_interval_seconds() == 17; "
            "assert not inspect.signature(server.get_cleanup_interval_seconds).parameters; "
            "os.environ['CLEANUP_INTERVAL_SECONDS'] = 'invalid'; "
            "assert server.get_cleanup_interval_seconds() == (60 if os.getenv('SPACE_ID') else 300)",
            module_name,
        ],
        cwd=tmp_path,
        env=environment,
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
