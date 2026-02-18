# -*- coding: utf-8 -*-
"""Tests for scripts/external_worker_pool.py."""

from __future__ import annotations

import argparse
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


def _load_module():
    root = Path(__file__).resolve().parents[2]
    script_path = root / "scripts" / "external_worker_pool.py"
    spec = importlib.util.spec_from_file_location("external_worker_pool", script_path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class TestExternalWorkerPool(unittest.IsolatedAsyncioTestCase):
    def setUp(self) -> None:
        self.mod = _load_module()
        self.temp_dir = tempfile.TemporaryDirectory(prefix="worker-pool-test-")
        self.addCleanup(self.temp_dir.cleanup)

    async def test_run_job_with_retry_retries_once(self):
        calls = {"count": 0}

        async def fake_run_job(**_kwargs):
            calls["count"] += 1
            if calls["count"] == 1:
                return Path("book.epub"), 2, 0.2, False
            return Path("book.epub"), 0, 0.1, False

        with patch.object(self.mod, "_run_job", side_effect=fake_run_job):
            result = await self.mod._run_job_with_retry(
                sem=self.mod.asyncio.Semaphore(1),
                file_path=Path("book.epub"),
                cmd=["python", "-m", "python_app.main", "convert", "book.epub"],
                idx=1,
                total=1,
                retries=1,
                retry_delay_s=0.0,
                job_timeout_seconds=0.0,
            )
        self.assertEqual(calls["count"], 2)
        self.assertEqual(result[1], 0)  # exit code
        self.assertEqual(result[3], 2)  # attempts
        self.assertFalse(result[4])  # timed out

    async def test_main_async_writes_json_report(self):
        tmp = Path(self.temp_dir.name)
        fake_book = tmp / "sample.epub"
        fake_book.write_text("x", encoding="utf-8")
        report = tmp / "report.json"

        async def fake_run_job_with_retry(**kwargs):
            file_path = kwargs["file_path"]
            return Path(file_path), 0, 0.33, 1, False

        args = argparse.Namespace(
            inputs=[str(fake_book)],
            batch_file=None,
            workers=1,
            forward_arg=[],
            retries=0,
            retry_delay_seconds=0.0,
            json_report=str(report),
            forward_args="",
            job_timeout_seconds=0.0,
        )

        with patch.object(self.mod, "_expand_inputs", return_value=[fake_book]):
            with patch.object(self.mod, "_run_job_with_retry", side_effect=fake_run_job_with_retry):
                code = await self.mod._main_async(args)

        self.assertEqual(code, 0)
        self.assertTrue(report.exists())
        payload = json.loads(report.read_text(encoding="utf-8"))
        self.assertEqual(int(payload.get("successes", -1)), 1)
        self.assertEqual(int(payload.get("failures", -1)), 0)
        self.assertEqual(len(payload.get("items", [])), 1)
        self.assertFalse(bool(payload["items"][0].get("timed_out", True)))

    async def test_run_job_marks_timeout(self):
        class _SlowProc:
            def __init__(self):
                self.killed = False

            async def wait(self):
                await self_mod.asyncio.sleep(0.05)
                return 0

            def kill(self):
                self.killed = True

        self_mod = self.mod
        proc = _SlowProc()

        async def fake_spawn(*_args, **_kwargs):
            return proc

        with patch.object(self_mod.asyncio, "create_subprocess_exec", side_effect=fake_spawn):
            _path, code, _elapsed, timed_out = await self_mod._run_job(
                sem=self_mod.asyncio.Semaphore(1),
                file_path=Path("slow.epub"),
                cmd=["python", "-m", "python_app.main", "convert", "slow.epub"],
                idx=1,
                total=1,
                job_timeout_seconds=0.01,
            )

        self.assertEqual(code, 124)
        self.assertTrue(timed_out)
        self.assertTrue(proc.killed)


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
