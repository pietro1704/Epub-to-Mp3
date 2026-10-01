"""Regression tests for single ownership of a server conversion run."""

from __future__ import annotations

import asyncio

import pytest


@pytest.mark.asyncio
async def test_schedule_job_conversion_deduplicates_live_tasks(monkeypatch):
    import python_app.server as server

    started = asyncio.Event()
    release = asyncio.Event()
    calls = 0

    async def fake_process(job_id: str) -> None:
        nonlocal calls
        calls += 1
        started.set()
        await release.wait()

    monkeypatch.setattr(server, "process_conversion", fake_process)
    monkeypatch.setattr(server, "_job_tasks", {})

    assert server._schedule_job_conversion("job-1") is True
    await started.wait()
    assert server._schedule_job_conversion("job-1") is False
    assert calls == 1

    release.set()
    task = server._job_tasks["job-1"]
    await task
    await asyncio.sleep(0)
    assert "job-1" not in server._job_tasks


@pytest.mark.asyncio
async def test_schedule_job_conversion_allows_new_run_after_previous_finishes(monkeypatch):
    import python_app.server as server

    calls = 0

    async def fake_process(job_id: str) -> None:
        nonlocal calls
        calls += 1

    monkeypatch.setattr(server, "process_conversion", fake_process)
    monkeypatch.setattr(server, "_job_tasks", {})

    assert server._schedule_job_conversion("job-2") is True
    await server._job_tasks["job-2"]
    await asyncio.sleep(0)
    assert server._schedule_job_conversion("job-2") is True
    await server._job_tasks["job-2"]
    assert calls == 2
