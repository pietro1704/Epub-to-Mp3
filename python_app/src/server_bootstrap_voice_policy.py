# -*- coding: utf-8 -*-
"""Ordered legacy server initialization at the facade seam."""

from __future__ import annotations


def _initialize_server_voice_policy(_runtime):
    _runtime.list_available_voices = _runtime.app.get("/api/voices")(_runtime._bind_server_function(_runtime._server_server_voice_routes.list_available_voices, _runtime.sys.modules[_runtime.__name__]))


    # ── Voice preview cache ─────────────────────────────────────────────────
    _runtime._PREVIEW_CACHE_DIR = _runtime.CACHE_DIR / "voice-previews"
    _runtime._PREVIEW_CACHE_DIR.mkdir(parents=True, exist_ok=True)

    # Cleanup cached previews older than 30 days on startup
    _runtime._PREVIEW_TTL_SECONDS = 30 * 24 * 3600
    try:
        _runtime._now = _runtime.time.time()
        for _runtime._cached_file in _runtime._PREVIEW_CACHE_DIR.glob("*.mp3"):
            try:
                if _runtime._now - _runtime._cached_file.stat().st_mtime > _runtime._PREVIEW_TTL_SECONDS:
                    _runtime._cached_file.unlink()
            except OSError:
                pass
    except Exception:
        pass

    # ── Voice preview rate limiter (per-IP sliding window) ──────────────────
    _runtime._PREVIEW_RATE_WINDOW = 60  # seconds
    _runtime._PREVIEW_RATE_LIMIT = 10  # max requests per window
    _runtime._preview_rate_log: dict[str, list[float]] = {}
    _runtime.__dict__.setdefault("__annotations__", {})['_preview_rate_log'] = 'dict[str, list[float]]'
    _runtime._preview_rate_lock = _runtime.threading.Lock()


    _runtime._check_preview_rate_limit = _runtime._bind_server_function(_runtime._server_server_voice_routes._check_preview_rate_limit, _runtime.sys.modules[_runtime.__name__])


    _runtime._PREVIEW_SAMPLE_TEXTS: dict[str, str] = {
        "pt": ("Era uma vez, numa terra distante, um livro que ganhava vida ao ser ouvido."),
        "en": ("Once upon a time, in a distant land, a book came alive when it was heard."),
        "es": ("Érase una vez, en una tierra lejana, un libro que cobraba vida al ser escuchado."),
        "fr": (
            "Il était une fois, dans un pays lointain, un livre qui prenait vie quand on l'écoutait."
        ),
        "de": ("Es war einmal, in einem fernen Land, ein Buch, das lebendig wurde, wenn man es hörte."),
        "ja": "むかしむかし、遠い国に、聞くと命を宿す本がありました。",
        "zh": "从前，在一个遥远的地方，有一本书，当有人听它时，它便活了过来。",
        "it": (
            "C'era una volta, in una terra lontana, un libro che prendeva vita quando veniva ascoltato."
        ),
    }
    _runtime.__dict__.setdefault("__annotations__", {})['_PREVIEW_SAMPLE_TEXTS'] = 'dict[str, str]'

    # Limit concurrent preview synthesis to avoid overloading the system
    _runtime._preview_semaphore = _runtime.asyncio.Semaphore(2)
    # In-flight dedup: maps cache_key -> Future so parallel requests for the
    # same voice share a single synthesis
    _runtime._preview_in_flight: dict[str, _runtime.asyncio.Future[_runtime.Path]] = {}
    _runtime.__dict__.setdefault("__annotations__", {})['_preview_in_flight'] = 'dict[str, asyncio.Future[Path]]'


    _runtime.voice_preview = _runtime.app.get("/api/voice-preview")(_runtime._bind_server_function(_runtime._server_server_voice_routes.voice_preview, _runtime.sys.modules[_runtime.__name__]))
