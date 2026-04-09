"""Desktop entry point — Edge-TTS only, no heavy ML dependencies.

Spawned as a Tauri sidecar. Starts FastAPI on a fixed local port.
"""

import os
import sys

# Force Edge-TTS, disable all local engine fallbacks before any other imports
os.environ.setdefault("DISABLE_PIPER_FALLBACK", "1")
os.environ.setdefault("EPUB_TO_MP3_ENGINE", "edge")

# Ensure ffmpeg is available via static-ffmpeg (downloads once to a local cache)
try:
    import static_ffmpeg  # type: ignore[import-untyped]

    print("Checking ffmpeg…", flush=True)
    static_ffmpeg.add_paths()
    print("ffmpeg ready.", flush=True)
except ImportError:
    pass  # ffmpeg must be on PATH if static-ffmpeg is not installed

# When running as a PyInstaller onefile binary, __file__ points inside _MEIPASS.
# Add the project root (parent of this file's directory) to sys.path so that
# `python_app.*` imports resolve correctly.
_here = os.path.dirname(os.path.abspath(__file__))
_root = os.path.dirname(_here)
if _root not in sys.path:
    sys.path.insert(0, _root)

DESKTOP_PORT = int(os.environ.get("EPUB_TO_MP3_PORT", "47860"))


def main() -> None:
    import uvicorn

    print("Loading server…", flush=True)
    from python_app.server import app  # deferred so env vars are set first

    print(f"Starting server on port {DESKTOP_PORT}…", flush=True)
    uvicorn.run(app, host="127.0.0.1", port=DESKTOP_PORT, log_level="info")


if __name__ == "__main__":
    main()
