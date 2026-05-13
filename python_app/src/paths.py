"""
Centralized path management for the Epub-to-Mp3 project.
Ensures cache and output directories are always in the project root,
regardless of where Python commands are executed from.
"""

import os
import shutil
import sys
from pathlib import Path

SPACE_ID = os.getenv("SPACE_ID")

# Subdirectories that make a directory recognisable as a previous
# Epub-to-Mp3 persistent root (used by the legacy-temp migration).
_FROZEN_SENTINEL_SUBDIRS = (".jobs", "output", ".cache")


def _as_path(value: str | None) -> Path | None:
    if not value:
        return None
    return Path(value).expanduser().resolve()


def is_frozen_bundle() -> bool:
    """True when running from a PyInstaller bundle (one-file or one-dir).

    PyInstaller one-file bundles extract into a per-launch temp directory
    (``_MEIxxxx``) that macOS evicts on cleanup. Anchoring persistent state
    there loses jobs/cache/output between launches.
    """
    return bool(getattr(sys, "frozen", False) and getattr(sys, "_MEIPASS", None))


def user_data_dir(app_name: str = "Epub-to-Mp3") -> Path:
    """Return a stable per-user data dir for the current OS.

    Used when the backend runs as a bundled desktop app so that cache, output
    and job state survive across app launches.
    """
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / app_name
    if os.name == "nt":
        base = os.environ.get("APPDATA") or str(Path.home() / "AppData" / "Roaming")
        return Path(base) / app_name
    xdg = os.environ.get("XDG_DATA_HOME")
    if xdg:
        return Path(xdg) / app_name
    return Path.home() / ".local" / "share" / app_name


def get_project_root() -> Path:
    """Locate the project root by walking up to the first directory that
    contains a well-known marker file.

    Returns:
        Path: Absolute path to the project root.
    """
    current = Path(__file__).resolve().parent

    # Markers that identify the project root
    root_markers = [
        ".git",
        "pytest.ini",
        "requirements-hf.txt",
        "CLAUDE.md",
    ]

    # Walk up until a root marker is found or filesystem root is reached
    while current != current.parent:
        if any((current / marker).exists() for marker in root_markers):
            return current
        current = current.parent

    # Fallback: assume we're in python_app/src and the project root is 2 levels up
    return Path(__file__).resolve().parent.parent.parent


PROJECT_ROOT = get_project_root()


def _looks_like_legacy_root(path: Path) -> bool:
    """True if ``path`` contains any non-empty Epub-to-Mp3 sentinel dir."""
    try:
        for name in _FROZEN_SENTINEL_SUBDIRS:
            sub = path / name
            if sub.is_dir() and any(sub.iterdir()):
                return True
    except OSError:
        return False
    return False


def _find_legacy_frozen_roots(temp_dir: Path | None = None) -> list[Path]:
    """Return candidate `_MEI*` directories that hold prior persistent state,
    sorted newest first by mtime.
    """
    import tempfile

    base = temp_dir or Path(tempfile.gettempdir())
    candidates: list[Path] = []
    try:
        for entry in base.glob("_MEI*"):
            if entry.is_dir() and _looks_like_legacy_root(entry):
                candidates.append(entry)
    except OSError:
        return []
    candidates.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    return candidates


def _target_is_empty(target: Path) -> bool:
    """True if the stable user-data dir has no prior Epub-to-Mp3 content."""
    if not target.exists():
        return True
    return not _looks_like_legacy_root(target)


def migrate_from_legacy_temp(target: Path, temp_dir: Path | None = None) -> Path | None:
    """Copy a previous PyInstaller temp root into ``target`` once.

    Returns the source path that was migrated, or ``None`` when no migration
    happened. Safe to call repeatedly: subsequent calls are a no-op once the
    target holds any sentinel content.
    """
    if not _target_is_empty(target):
        return None
    sources = _find_legacy_frozen_roots(temp_dir)
    if not sources:
        return None
    source = sources[0]
    target.mkdir(exist_ok=True, parents=True)
    for name in _FROZEN_SENTINEL_SUBDIRS + (".uploads", ".job_inputs", ".logs", ".source_backups"):
        src_sub = source / name
        if not src_sub.is_dir():
            continue
        dst_sub = target / name
        if dst_sub.exists():
            continue
        try:
            shutil.copytree(src_sub, dst_sub)
        except OSError:
            continue
    return source


# Persistent root is configurable so CLI (local) and HF Space share the same tree.
# Bundled desktop app uses the OS user-data dir because the PyInstaller temp
# extraction directory is wiped between launches.
_persistent_override = _as_path(os.getenv("PERSISTENT_ROOT"))
if SPACE_ID:
    PERSISTENT_ROOT = _persistent_override or Path("/data/epub-to-mp3")
elif is_frozen_bundle() and _persistent_override is None:
    PERSISTENT_ROOT = user_data_dir()
    # Best-effort one-shot import of the newest legacy `_MEI*` persistent
    # root so pre-fix desktop users don't lose finished conversions.
    try:
        migrate_from_legacy_temp(PERSISTENT_ROOT)
    except Exception:
        pass
else:
    PERSISTENT_ROOT = _persistent_override or PROJECT_ROOT
PERSISTENT_ROOT.mkdir(exist_ok=True, parents=True)


def _resolve_output_dir() -> Path:
    override = _as_path(os.getenv("OUTPUT_DIR"))
    if override:
        return override
    if SPACE_ID or is_frozen_bundle():
        return PERSISTENT_ROOT / "output"
    return PROJECT_ROOT / "output"


def _resolve_cache_dir() -> Path:
    override = _as_path(os.getenv("CACHE_DIR"))
    if override:
        return override
    if SPACE_ID or is_frozen_bundle():
        return PERSISTENT_ROOT / ".cache"
    return PROJECT_ROOT / ".cache"


# Directories rooted at the project root (with shared overrides)
CACHE_DIR = _resolve_cache_dir()  # Temporary per-book data only
OUTPUT_DIR = _resolve_output_dir()
MODELS_DIR = PROJECT_ROOT / "models"  # TTS models (Piper)
JOBS_DIR = PERSISTENT_ROOT / ".jobs"
UPLOADS_DIR = PERSISTENT_ROOT / ".uploads"
JOB_INPUTS_DIR = PERSISTENT_ROOT / ".job_inputs"
SOURCE_BACKUPS_DIR = PERSISTENT_ROOT / ".source_backups"

# Create directories if they don't exist
CACHE_DIR.mkdir(exist_ok=True, parents=True)
OUTPUT_DIR.mkdir(exist_ok=True, parents=True)
MODELS_DIR.mkdir(exist_ok=True, parents=True)
JOBS_DIR.mkdir(exist_ok=True, parents=True)
UPLOADS_DIR.mkdir(exist_ok=True, parents=True)
JOB_INPUTS_DIR.mkdir(exist_ok=True, parents=True)
SOURCE_BACKUPS_DIR.mkdir(exist_ok=True, parents=True)

# Subdirectories for specific model types (inside root/models)
PIPER_MODELS_DIR = MODELS_DIR / "piper"
PIPER_MODELS_DIR.mkdir(exist_ok=True, parents=True)

# Compat: aliases expected by tests/legacy code
PIPER_MODEL_CACHE_DIR = PIPER_MODELS_DIR

# Telemetry lives in .cache (temporary data)
TELEMETRY_DIR = CACHE_DIR / "telemetry"
TELEMETRY_DIR.mkdir(exist_ok=True, parents=True)

# Persistent conversion session log (never auto-deleted)
LOGS_DIR = PERSISTENT_ROOT / ".logs"
LOGS_DIR.mkdir(exist_ok=True, parents=True)

# Point external libraries to the project-root model directory
os.environ.setdefault("PIPER_MODEL_DIR", str(PIPER_MODELS_DIR))


def get_cache_path(*parts: str) -> Path:
    """Return a path inside the project cache directory."""
    return CACHE_DIR.joinpath(*parts)


def get_output_path(*parts: str) -> Path:
    """Return a path inside the project output directory."""
    return OUTPUT_DIR.joinpath(*parts)


if __name__ == "__main__":
    print(f"Project root: {PROJECT_ROOT}")
    print(f"Cache: {CACHE_DIR}")
    print(f"Output: {OUTPUT_DIR}")
    print(f"Cache exists: {CACHE_DIR.exists()}")
    print(f"Output exists: {OUTPUT_DIR.exists()}")
