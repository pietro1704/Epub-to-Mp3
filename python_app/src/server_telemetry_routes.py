# -*- coding: utf-8 -*-
"""Conversion estimates and engine/segment telemetry endpoints."""

from __future__ import annotations

from typing import Optional


async def estimate_conversion(_runtime,
    upload_id: str,
    engine: str = "auto",
) -> dict:
    """Estimate conversion time and output size for an uploaded ebook.

    Returns per-engine estimates using observed telemetry throughput,
    falling back to conservative defaults when no samples are available.

    Args:
        upload_id: ID returned by POST /api/uploads
        engine:    TTS engine to estimate for. "auto" returns all engines.

    Response:
        chapters        Total chapters found
        total_chars     Total characters to synthesise
        engine          Engine the primary estimate applies to
        chars_per_second  Throughput used for the estimate (chars/s)
        telemetry_based  True if throughput came from real samples
        estimated_duration_seconds
        estimated_duration_formatted  Human-readable (e.g. "12 min 34 s")
        estimated_output_mb  Approximate MP3 size at 128 kbps
        engine_estimates  Dict of engine → estimate for all engines
    """
    # ── Locate the uploaded file ─────────────────────────────────────────
    with _runtime._pending_lock:
        upload_info = _runtime._pending_uploads.get(upload_id)

    file_path: Optional[str] = None
    if upload_info:
        file_path = upload_info.get("file_path")
    else:
        # Try to find it on disk (upload may have been consumed by convert)
        upload_dir = _runtime.uploads_dir / upload_id
        if upload_dir.exists():
            for candidate in upload_dir.iterdir():
                if candidate.suffix.lower() in {
                    ".epub",
                    ".pdf",
                    ".fb2",
                    ".docx",
                    ".cbz",
                    ".cbr",
                    ".mobi",
                    ".prc",
                    ".azw",
                    ".azw3",
                }:
                    file_path = str(candidate)
                    break

    if not file_path or not _runtime.Path(file_path).exists():
        raise _runtime.HTTPException(status_code=404, detail="Upload not found or already consumed")

    # ── Count chapters and chars (use cache when pre-warmed by upload) ───
    total_chars = 0
    chapter_count = 0
    chapter_breakdown: list[dict] = []

    try:
        cache_manager = _runtime.get_cache_manager()
        cached = cache_manager.get_cached_chapters(_runtime.Path(file_path))
        if cached and cached.get("chapters"):
            chapters_data = cached["chapters"]
            for ch in chapters_data:
                text = ch.get("text", "")
                chars = len(text)
                chapter_breakdown.append({"name": ch.get("title", ""), "chars": chars})
                total_chars += chars
            chapter_count = len(chapters_data)
        else:
            reader = _runtime.EbookReader(file_path)
            for ch in reader.get_chapters():
                text = getattr(ch, "text", "") or ""
                chars = len(text)
                chapter_breakdown.append({"name": getattr(ch, "name", ""), "chars": chars})
                total_chars += chars
            chapter_count = len(chapter_breakdown)
    except Exception as exc:
        raise _runtime.HTTPException(status_code=422, detail=f"Failed to parse ebook: {exc}")

    if chapter_count == 0:
        raise _runtime.HTTPException(status_code=422, detail="No chapters found in ebook")

    # ── Default throughput per engine (chars/s, conservative) ────────────
    _DEFAULTS: dict[str, float] = {
        "edge": 110.0,
        "piper": 25.0,
        "auto": 110.0,
    }
    # 128 kbps MP3: 16 KB/s
    _KBPS_BYTES_PER_SECOND = 128 * 1024 / 8

    telem_summary = _runtime.telemetry.summary()

    def _estimate_for_engine(eng: str) -> dict:
        telem = telem_summary.get(eng, {})
        if telem and telem.get("avg_chars_per_second", 0) > 0:
            cps = float(telem["avg_chars_per_second"])
            telem_based = True
            samples = int(telem.get("samples", 0))
        else:
            cps = _DEFAULTS.get(eng, _DEFAULTS["edge"])
            telem_based = False
            samples = 0

        est_seconds = total_chars / cps if cps > 0 else 0.0
        est_mb = (est_seconds * _KBPS_BYTES_PER_SECOND) / (1024 * 1024)

        mins, secs = divmod(int(est_seconds), 60)
        hours, mins = divmod(mins, 60)
        if hours:
            formatted = f"{hours}h {mins}m {secs}s"
        elif mins:
            formatted = f"{mins}m {secs}s"
        else:
            formatted = f"{secs}s"

        result: dict = {
            "chars_per_second": round(cps, 1),
            "telemetry_based": telem_based,
            "telemetry_samples": samples,
            "estimated_duration_seconds": round(est_seconds),
            "estimated_duration_formatted": formatted,
            "estimated_output_mb": round(est_mb, 1),
        }
        return result

    known_engines = list(_DEFAULTS.keys() - {"auto"})
    engine_estimates = {eng: _estimate_for_engine(eng) for eng in known_engines}

    # "auto" picks the best engine with telemetry data, else edge
    ranked = _runtime.telemetry.ranked_engines()
    primary_engine = ranked[0] if ranked else "edge"
    if engine != "auto" and engine in _DEFAULTS:
        primary_engine = engine

    primary = _estimate_for_engine(primary_engine)

    return {
        "chapters": chapter_count,
        "total_chars": total_chars,
        "engine": primary_engine,
        "chars_per_second": primary["chars_per_second"],
        "telemetry_based": primary["telemetry_based"],
        "telemetry_samples": primary["telemetry_samples"],
        "estimated_duration_seconds": primary["estimated_duration_seconds"],
        "estimated_duration_formatted": primary["estimated_duration_formatted"],
        "estimated_output_mb": primary["estimated_output_mb"],
        "engine_estimates": engine_estimates,
        "chapter_breakdown": chapter_breakdown,
    }


async def get_engine_telemetry(_runtime, ) -> dict:
    """Return aggregated throughput data to compare Edge vs Piper speeds."""
    summary = _runtime.telemetry.summary()
    recent = [
        {
            "engine": entry.get("engine"),
            "chars": entry.get("chars"),
            "synth_seconds": entry.get("synth_seconds"),
            "timestamp": entry.get("timestamp"),
        }
        for entry in _runtime.telemetry.recent_samples(limit=10)
    ]
    return {
        "engines": summary,
        "recent": recent,
    }


async def get_segment_telemetry(_runtime, ) -> dict:
    """Return latest segment-level telemetry summary if available."""
    summary_path = _runtime._latest_segment_summary()
    if summary_path is None:
        return {"available": False, "summary": None, "source": None}
    try:
        payload = _runtime.json.loads(summary_path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise _runtime.HTTPException(status_code=500, detail=f"Failed to read segment telemetry: {exc}")
    return {
        "available": True,
        "summary": payload if isinstance(payload, dict) else {},
        "source": str(summary_path),
    }


async def get_feature_ab_history(_runtime, limit: int = 20) -> dict:
    """Return rolling feature A/B benchmark history, when available."""
    history_path = _runtime._feature_ab_history_path()
    if not history_path.exists():
        return {
            "available": False,
            "history": {"entries": []},
            "entries": [],
            "count": 0,
            "source": str(history_path),
        }
    try:
        payload = _runtime.json.loads(history_path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise _runtime.HTTPException(status_code=500, detail=f"Failed to read feature history: {exc}")

    history = payload if isinstance(payload, dict) else {"entries": []}
    entries = history.get("entries", [])
    if not isinstance(entries, list):
        entries = []
    entries = [item for item in entries if isinstance(item, dict)]
    safe_limit = max(1, min(200, int(limit or 20)))
    return {
        "available": True,
        "history": history,
        "entries": entries[:safe_limit],
        "count": len(entries),
        "source": str(history_path),
    }
