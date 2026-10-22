# -*- coding: utf-8 -*-
"""Voice catalogue, preview rate limiting and preview synthesis."""

from __future__ import annotations


from fastapi import Request
from fastapi.responses import FileResponse


async def list_available_voices(_runtime, ) -> dict:
    """Expose curated voice/model suggestions for the frontend."""
    provider = _runtime.tts_factory.voice_provider
    return {
        "voices": provider.get_voice_suggestions(),
    }


def _check_preview_rate_limit(_runtime, client_ip: str) -> bool:
    """Return True if the request should be allowed."""
    now = _runtime.time.time()
    cutoff = now - _runtime._PREVIEW_RATE_WINDOW
    with _runtime._preview_rate_lock:
        timestamps = _runtime._preview_rate_log.get(client_ip, [])
        timestamps = [t for t in timestamps if t > cutoff]
        if len(timestamps) >= _runtime._PREVIEW_RATE_LIMIT:
            _runtime._preview_rate_log[client_ip] = timestamps
            return False
        timestamps.append(now)
        _runtime._preview_rate_log[client_ip] = timestamps
    return True


async def voice_preview(_runtime,
    request: Request, engine: str, voice: str = "", language: str = "pt"
) -> FileResponse:
    """Synthesize a short sample for the given engine+voice and return MP3.

    Results are cached on disk so subsequent requests are instant.
    Rate-limited to 10 requests/minute per IP.
    """
    client_ip = request.client.host if request.client else "unknown"
    if not _runtime._check_preview_rate_limit(client_ip):
        raise _runtime.HTTPException(
            status_code=429, detail="Too many preview requests. Try again in a minute."
        )

    engine = engine.lower().strip()
    if engine not in ("edge", "piper"):
        raise _runtime.HTTPException(status_code=400, detail=f"Unsupported engine: {engine}")

    lang_code = language.lower().split("-")[0] if language else "pt"

    # Pick sample text matching language (or engine default)
    if engine == "piper" and lang_code not in ("pt", "en", "es", "fr", "de", "it"):
        lang_code = "pt"

    sample_text = _runtime._PREVIEW_SAMPLE_TEXTS.get(lang_code, _runtime._PREVIEW_SAMPLE_TEXTS["en"])

    # Deterministic cache key
    voice_slug = (voice or "default").replace("/", "_").replace(" ", "_")
    cache_key = f"{engine}__{voice_slug}__{lang_code}"
    cache_path = _runtime._PREVIEW_CACHE_DIR / f"{cache_key}.mp3"

    if cache_path.exists() and cache_path.stat().st_size > 0:
        return _runtime.FileResponse(
            cache_path,
            media_type="audio/mpeg",
            headers={"Cache-Control": "public, max-age=86400"},
        )

    # Dedup in-flight requests for the same cache key
    loop = _runtime.asyncio.get_running_loop()
    if cache_key in _runtime._preview_in_flight:
        try:
            result_path = await _runtime._preview_in_flight[cache_key]
            return _runtime.FileResponse(
                result_path,
                media_type="audio/mpeg",
                headers={"Cache-Control": "public, max-age=86400"},
            )
        except Exception:
            pass  # fall through to synthesize

    future: _runtime.asyncio.Future[_runtime.Path] = loop.create_future()
    _runtime._preview_in_flight[cache_key] = future

    try:
        async with _runtime._preview_semaphore:
            # Double-check after acquiring semaphore (another request may have filled it)
            if cache_path.exists() and cache_path.stat().st_size > 0:
                future.set_result(cache_path)
                return _runtime.FileResponse(
                    cache_path,
                    media_type="audio/mpeg",
                    headers={"Cache-Control": "public, max-age=86400"},
                )

            import tempfile

            with tempfile.TemporaryDirectory() as tmp_dir:
                raw_output = _runtime.Path(tmp_dir) / "preview.mp3"

                config = _runtime.ConversionConfig(
                    engine=engine,
                    voice=voice or None,
                    primary_language=lang_code,
                    verbose=False,
                )

                try:
                    tts_engine = _runtime.tts_factory.create_engine(config)
                    await _runtime.asyncio.wait_for(
                        tts_engine.synthesize_async(sample_text, raw_output),
                        timeout=30.0,
                    )
                except _runtime.asyncio.TimeoutError:
                    future.set_exception(
                        _runtime.HTTPException(status_code=504, detail="Preview synthesis timed out")
                    )
                    raise _runtime.HTTPException(status_code=504, detail="Preview synthesis timed out")
                except Exception as exc:
                    future.set_exception(
                        _runtime.HTTPException(status_code=500, detail=f"Synthesis failed: {exc}")
                    )
                    raise _runtime.HTTPException(
                        status_code=500,
                        detail=f"Synthesis failed: {exc}",
                    )

                if not raw_output.exists() or raw_output.stat().st_size == 0:
                    future.set_exception(
                        _runtime.HTTPException(status_code=500, detail="Synthesis produced empty output")
                    )
                    raise _runtime.HTTPException(status_code=500, detail="Synthesis produced empty output")

                _runtime.shutil.copy2(raw_output, cache_path)

        future.set_result(cache_path)
        return _runtime.FileResponse(
            cache_path,
            media_type="audio/mpeg",
            headers={"Cache-Control": "public, max-age=86400"},
        )
    finally:
        _runtime._preview_in_flight.pop(cache_key, None)
