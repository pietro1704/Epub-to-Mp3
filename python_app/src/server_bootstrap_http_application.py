# -*- coding: utf-8 -*-
"""Ordered legacy server initialization at the facade seam."""

from __future__ import annotations


def _initialize_server_http_application(_runtime):
    _runtime.app = _runtime.FastAPI(title="EPUB to MP3 Converter API", lifespan=_runtime._lifespan)

    _runtime.ROOT_DIR = _runtime.Path(_runtime.__file__).resolve().parents[1]
    _runtime.WEB_DIR = _runtime.ROOT_DIR / "web"
    _runtime.SAMPLE_BOOK_CANDIDATES = [
        _runtime.WEB_DIR / "dist" / "sample.epub",
        _runtime.WEB_DIR / "public" / "sample.epub",
    ]

    # Performance controls
    # **PERFORMANCE**: Turbo mode sempre ativo para igualar CLI
    _runtime.FORCE_TURBO = _runtime.os.getenv("FORCE_TURBO_MODE", "true").strip().lower() in {"1", "true", "yes", "on"}
    _runtime.TURBO_SLOT_MULTIPLIER = max(
        1, int(_runtime.os.getenv("FORCE_TURBO_SLOT_MULTIPLIER", "3") or "3")
    )  # 3x para igualar CLI
    _runtime.WORKER_MAX = max(1, int(_runtime.os.getenv("JOB_WORKERS_MAX", "16") or "16"))
    # Hard cap on simultaneous book conversions. Turbo mode scales parallelism
    # *within* a job (chapters/chunks), not the number of concurrent books.
    _runtime.MAX_CONCURRENT_BOOKS = max(1, int(_runtime.os.getenv("MAX_CONCURRENT_BOOKS", "1") or "1"))
    # **PERFORMANCE**: Use the same aggressive settings as the CLI
    # Disable conservative auto-tune for maximum speed
    _runtime.EDGE_AUTO_TUNE = _runtime.os.getenv("EDGE_AUTO_TUNE", "false").strip().lower() in {"1", "true", "yes", "on"}
    # On HF Spaces, Edge-TTS shares egress IPs and runs at 60-120 chars/s even when
    # "working" (vs 200+ locally). Use tighter thresholds so slow mode + engine
    # switch trigger sooner rather than letting each chapter crawl for 3-4 minutes.
    _runtime._hf_mode = bool(_runtime.os.getenv("SPACE_ID"))
    _runtime.EDGE_MIN_CHARS_PER_SECOND = float(
        _runtime.os.getenv("EDGE_MIN_CHARS_PER_SECOND", "100" if _runtime._hf_mode else "60") or "60"
    )
    _runtime.EDGE_SLOW_RATIO_THRESHOLD = float(
        _runtime.os.getenv("EDGE_SLOW_RATIO_THRESHOLD", "1.5" if _runtime._hf_mode else "2.2") or "2.2"
    )
    # Safe mode should be materially more conservative than the normal profile so
    # Edge can survive transient throttling instead of timing out and dropping to Piper.
    _runtime.EDGE_SAFE_CHUNK_CHARS = max(
        2500, int(_runtime.os.getenv("EDGE_SAFE_CHUNK_CHARS", "5000" if _runtime._hf_mode else "4000") or "4000")
    )
    _runtime.EDGE_SAFE_MAX_SEGMENT_SECONDS = max(
        30, int(_runtime.os.getenv("EDGE_SAFE_MAX_SEGMENT_SECONDS", "120" if _runtime._hf_mode else "90") or "90")
    )
    _runtime.EDGE_SAFE_CHAPTER_PARALLEL = max(
        1, int(_runtime.os.getenv("EDGE_SAFE_CHAPTER_PARALLEL", "1" if _runtime._hf_mode else "8") or "1")
    )
    _runtime.EDGE_SAFE_TIMEOUT_MAX = max(
        90.0, float(_runtime.os.getenv("EDGE_SAFE_TIMEOUT_MAX", "180" if _runtime._hf_mode else "120") or "120")
    )
    # **PERFORMANCE**: More aggressive caps for all network tiers
    _runtime.EDGE_AUTO_PARALLEL_CAPS = {
        "slow": max(1, int(_runtime.os.getenv("EDGE_AUTO_PARALLEL_CAP_SLOW", "4") or "4")),
        "medium": max(1, int(_runtime.os.getenv("EDGE_AUTO_PARALLEL_CAP_MEDIUM", "6") or "6")),
        "fast": max(1, int(_runtime.os.getenv("EDGE_AUTO_PARALLEL_CAP_FAST", "8") or "8")),
        "ultra": max(1, int(_runtime.os.getenv("EDGE_AUTO_PARALLEL_CAP_ULTRA", "8") or "8")),
    }

    # Job cleanup configuration
    # On HF Spaces, output files live on /data (persistent across restarts), so we
    # keep them much longer by default. Override via COMPLETED_JOB_TTL_HOURS env var.
    _runtime._DEFAULT_TTL_HOURS = 48 if _runtime.os.getenv("SPACE_ID") else 4
    _runtime.COMPLETED_JOB_TTL_HOURS = float(
        _runtime.os.getenv("COMPLETED_JOB_TTL_HOURS", str(_runtime._DEFAULT_TTL_HOURS)) or _runtime._DEFAULT_TTL_HOURS
    )
    # HF Spaces recycles jobs faster than local dev; default to a shorter cleanup
    # interval there so orphaned entries don't linger for the full 5-minute window.
    _runtime._DEFAULT_CLEANUP_INTERVAL = 60 if _runtime.os.getenv("SPACE_ID") else 300
    _runtime.CLEANUP_INTERVAL_SECONDS = max(
        10,
        int(
            _runtime.os.getenv("CLEANUP_INTERVAL_SECONDS", str(_runtime._DEFAULT_CLEANUP_INTERVAL))
            or _runtime._DEFAULT_CLEANUP_INTERVAL
        ),
    )


    _runtime.get_cleanup_interval_seconds = _runtime._bind_server_function(_runtime._server_server_form_values.get_cleanup_interval_seconds, _runtime.sys.modules[_runtime.__name__])


    _runtime.TELEMETRY_RETENTION_HOURS = max(
        24, int(_runtime.os.getenv("TELEMETRY_RETENTION_HOURS", "720") or "720")
    )  # 30 days

    # CORS configuration - supports both local dev and Cloudflare deployment
    _runtime.allowed_origins = [
        "http://localhost:5173",
        "http://127.0.0.1:5173",
        "http://localhost:3000",
        "http://127.0.0.1:3000",
        "http://localhost:8000",
        "http://127.0.0.1:8000",
        "http://localhost:7860",
        "http://127.0.0.1:7860",
    ]

    # Add Cloudflare Pages domain from environment (for production)
    _runtime.cloudflare_domain = _runtime.os.getenv("CLOUDFLARE_PAGES_URL")
    if _runtime.cloudflare_domain:
        _runtime.allowed_origins.append(_runtime.cloudflare_domain)
        _runtime.allowed_origins.append(_runtime.cloudflare_domain.replace("http://", "https://"))

    # Add custom frontend URL if provided
    _runtime.frontend_url = _runtime.os.getenv("FRONTEND_URL")
    if _runtime.frontend_url:
        _runtime.allowed_origins.append(_runtime.frontend_url)

    _runtime.app.add_middleware(
        _runtime.CORSMiddleware,
        allow_origins=_runtime.allowed_origins,
        # Dev-friendly local origins (localhost, loopback, private LAN)
        allow_origin_regex=(
            r"^https?://("
            r"localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\]|::1|"
            r"10(?:\.\d{1,3}){3}|"
            r"192\.168(?:\.\d{1,3}){2}|"
            r"172\.(?:1[6-9]|2\d|3[0-1])(?:\.\d{1,3}){2}"
            r")(:\d+)?$"
        ),
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )
