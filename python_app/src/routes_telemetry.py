"""Telemetry dashboard routes.

Exposes the `TelemetryRecorder.summary()` payload plus a timeline of recent
samples so the frontend can render a per-engine throughput dashboard without
scraping JSON files directly.
"""

from __future__ import annotations

from typing import Dict, List

from fastapi import APIRouter, HTTPException

from .telemetry import TelemetryRecorder

router = APIRouter(prefix="/api/telemetry", tags=["telemetry"])


def _recorder() -> TelemetryRecorder:
    import python_app.server as _srv

    recorder = getattr(_srv, "telemetry", None)
    if isinstance(recorder, TelemetryRecorder):
        return recorder
    return TelemetryRecorder()


@router.get("/summary")
async def telemetry_summary() -> Dict[str, object]:
    """Aggregated throughput stats per engine + ranked order.

    Includes a per-language breakdown when telemetry has language-tagged
    samples, so the dashboard can show that pt-BR Edge ≠ EN Edge in
    practice. Older recorders without the language-aware API still get
    a flat ``engines`` payload.
    """
    recorder = _recorder()
    summary = recorder.summary()
    ranked = recorder.ranked_engines()
    total_samples = sum(int((stats or {}).get("samples", 0) or 0) for stats in summary.values())
    by_language: Dict[str, Dict[str, Dict[str, float]]] = {}
    summary_by_language = getattr(recorder, "summary_by_language", None)
    if callable(summary_by_language):
        try:
            by_language = summary_by_language()
        except Exception:
            by_language = {}
    return {
        "engines": summary,
        "ranked": ranked,
        "totalSamples": total_samples,
        "byLanguage": by_language,
    }


@router.get("/timeline")
async def telemetry_timeline(limit: int = 50) -> Dict[str, object]:
    """Recent synthesis samples for charting (newest last)."""
    if limit <= 0 or limit > 500:
        raise HTTPException(status_code=400, detail="limit must be in 1..500")
    recorder = _recorder()
    samples: List[dict] = recorder.recent_samples(limit=limit)
    points: List[Dict[str, object]] = []
    for entry in samples:
        try:
            chars = float(entry.get("chars") or 0)
            synth = float(entry.get("synth_seconds") or 0)
        except (TypeError, ValueError):
            continue
        if chars <= 0 or synth <= 0:
            continue
        points.append(
            {
                "engine": str(entry.get("engine") or "").lower(),
                "voice": entry.get("voice"),
                "timestamp": entry.get("timestamp"),
                "charsPerSecond": round(chars / synth, 1),
                "chars": int(chars),
                "synthSeconds": round(synth, 2),
                "chapter": entry.get("chapter"),
                "jobId": entry.get("job_id"),
            }
        )
    return {
        "points": points,
        "count": len(points),
    }


__all__ = ["router"]
