# -*- coding: utf-8 -*-
"""Resumable job snapshots and saved timestamps."""

from __future__ import annotations

from typing import Optional


def _summarize_resume_job(_runtime, job_id: str, job_data: dict, saved_at: Optional[str] = None) -> dict:
    return {
        "jobId": job_id,
        "state": job_data.get("state", "queued"),
        "bookTitle": job_data.get("bookTitle", "Unknown Book"),
        "fileName": _runtime.Path(job_data.get("file_path", "")).name
        if job_data.get("file_path")
        else "unknown",
        "savedAt": saved_at
        or job_data.get("_saved_at")
        or _runtime.datetime.now(_runtime.timezone.utc).replace(tzinfo=None).isoformat(),
        "chaptersCompleted": job_data.get("chaptersCompleted", 0),
        "chaptersTotal": job_data.get("chaptersTotal"),
        "engine": job_data.get("engine"),
        "voice": job_data.get("voice"),
        "language": job_data.get("detectedLanguage") or job_data.get("language"),
        "formattingCues": job_data.get("formattingCues"),
        "uiLanguage": job_data.get("uiLanguage"),
    }


def _resolve_completed_iso(_runtime, job_data: dict) -> Optional[str]:
    completed_iso = job_data.get("completedAtIso")
    if completed_iso:
        return completed_iso
    completed_epoch = job_data.get("completedAt")
    if completed_epoch:
        try:
            return _runtime.datetime.fromtimestamp(float(completed_epoch), tz=_runtime.timezone.utc).isoformat()
        except (TypeError, ValueError):
            return None
    return None


def _determine_saved_at(_runtime, job_data: dict) -> str:
    return (
        _runtime._resolve_completed_iso(job_data)
        or job_data.get("_saved_at")
        or job_data.get("createdAt")
        or job_data.get("startedAt")
        or _runtime._utcnow_iso()
    )


def _resolve_chapter_timeout(_runtime, estimated_seconds: float, text_chars: int = 0) -> float:
    """Return an upper bound for synthesis before forcing fallback.

    The cap scales with chapter size so large chapters (50–70 K chars) get
    enough time even on HF where Edge synthesises at 50–100 chars/s.  A
    conservative minimum synthesis speed of 30 chars/s is assumed so the cap
    never cuts off a chapter that is still making steady progress.
    """
    estimate = max(float(estimated_seconds or 0.0), _runtime._CHAPTER_TIMEOUT_MIN)
    timeout = max(_runtime._CHAPTER_TIMEOUT_MIN, estimate * _runtime._CHAPTER_TIMEOUT_FACTOR)
    if text_chars > 0:
        # Floor: enough time for a very slow engine at 30 chars/s with 1.5× margin.
        synthesis_min = (text_chars / 30.0) * 1.5
        timeout = max(timeout, synthesis_min)
    return min(timeout, _runtime._CHAPTER_TIMEOUT_MAX)


def _collect_resumable_job_entries(_runtime, ) -> list[dict]:
    summaries: dict[str, dict] = {}
    for entry in _runtime.job_manager.get_resumable_jobs():
        summaries[entry["jobId"]] = entry
    for job_id, job_data in _runtime.jobs.items():
        if not job_data:
            continue
        state = job_data.get("state", "")
        if state not in {"queued", "running", "cancelling", "interrupted"}:
            continue
        summaries[job_id] = _runtime._summarize_resume_job(job_id, job_data)
    return sorted(summaries.values(), key=lambda entry: entry.get("savedAt", ""), reverse=True)
