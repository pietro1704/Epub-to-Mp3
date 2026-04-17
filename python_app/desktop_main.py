"""Desktop entry point — Edge-TTS only, no heavy ML dependencies.

Spawned as a Tauri sidecar. Starts FastAPI on a fixed local port.
"""

import os
import sys

# When running as a PyInstaller onefile binary, __file__ points inside _MEIPASS.
# Add the project root (parent of this file's directory) to sys.path so that
# `python_app.*` imports resolve correctly.
_here = os.path.dirname(os.path.abspath(__file__))
_root = os.path.dirname(_here)
if _root not in sys.path:
    sys.path.insert(0, _root)


def _apply_desktop_env_defaults() -> None:
    """Force Edge-TTS and disable local engine fallbacks.

    Kept as a function (rather than module-level side effects) so that
    importing this module from tests doesn't pollute the process env and
    break fallback-related tests elsewhere.
    """
    os.environ.setdefault("DISABLE_PIPER_FALLBACK", "1")
    os.environ.setdefault("EPUB_TO_MP3_ENGINE", "edge")


def resolve_ffmpeg_cache_dir() -> "os.PathLike[str] | None":
    """Return the stable directory where static-ffmpeg should cache its archive.

    Anchored at ``PERSISTENT_ROOT/.ffmpeg/<platform>`` so the ~60 MB archive is
    downloaded once, not on every relaunch. The platform-named leaf matters:
    static-ffmpeg extracts the zip one level up and expects the binary at
    ``<download_dir>/ffmpeg``, which only lines up when the leaf is the zip's
    internal platform subdir (``darwin``/``linux``/``win32``).
    """
    try:
        from python_app.src.paths import PERSISTENT_ROOT

        cache = PERSISTENT_ROOT / ".ffmpeg" / sys.platform
        cache.mkdir(exist_ok=True, parents=True)
        return cache
    except Exception:
        return None


def setup_ffmpeg() -> None:
    """Prime static-ffmpeg using the stable cache dir when available."""
    try:
        import static_ffmpeg  # type: ignore[import-untyped]
    except ImportError:
        # ffmpeg must be on PATH if static-ffmpeg is not installed
        return

    cache_dir = resolve_ffmpeg_cache_dir()
    print("Checking ffmpeg…", flush=True)
    if cache_dir is not None:
        static_ffmpeg.add_paths(download_dir=str(cache_dir))
    else:
        static_ffmpeg.add_paths()
    print("ffmpeg ready.", flush=True)


DESKTOP_PORT = int(os.environ.get("EPUB_TO_MP3_PORT", "47860"))


def main() -> None:
    _apply_desktop_env_defaults()
    setup_ffmpeg()

    import uvicorn

    print("Loading server…", flush=True)
    from python_app.server import app  # deferred so env vars are set first

    print(f"Starting server on port {DESKTOP_PORT}…", flush=True)
    uvicorn.run(app, host="127.0.0.1", port=DESKTOP_PORT, log_level="info")


if __name__ == "__main__":
    main()
