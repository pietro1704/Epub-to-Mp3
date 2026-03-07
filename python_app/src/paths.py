"""
Centralized path management for the Epub-to-Mp3 project.
Ensures cache and output directories are always in the project root,
regardless of where Python commands are executed from.
"""

import os
from pathlib import Path

SPACE_ID = os.getenv("SPACE_ID")


def _as_path(value: str | None) -> Path | None:
    if not value:
        return None
    return Path(value).expanduser().resolve()


def get_project_root() -> Path:
    """
    Detecta a raiz do projeto procurando por marcadores característicos.
    Sobe na hierarquia de diretórios até encontrar a raiz.

    Returns:
        Path: Caminho absoluto para a raiz do projeto
    """
    current = Path(__file__).resolve().parent

    # Marcadores que indicam a raiz do projeto
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


# Raiz do projeto (sempre /path/to/Epub-to-Mp3)
PROJECT_ROOT = get_project_root()

# Persistent root is configurable so CLI (local) and HF Space share the same tree
_persistent_override = _as_path(os.getenv("PERSISTENT_ROOT"))
if SPACE_ID:
    PERSISTENT_ROOT = _persistent_override or Path("/data/epub-to-mp3")
else:
    PERSISTENT_ROOT = _persistent_override or PROJECT_ROOT
PERSISTENT_ROOT.mkdir(exist_ok=True, parents=True)


def _resolve_output_dir() -> Path:
    override = _as_path(os.getenv("OUTPUT_DIR"))
    if override:
        return override
    if SPACE_ID:
        return PERSISTENT_ROOT / "output"
    return PROJECT_ROOT / "output"


def _resolve_cache_dir() -> Path:
    override = _as_path(os.getenv("CACHE_DIR"))
    if override:
        return override
    if SPACE_ID:
        return PERSISTENT_ROOT / ".cache"
    return PROJECT_ROOT / ".cache"


# Directories rooted at the project root (with shared overrides)
CACHE_DIR = _resolve_cache_dir()  # Temporary per-book data only
OUTPUT_DIR = _resolve_output_dir()
MODELS_DIR = PROJECT_ROOT / "models"  # TTS models (Piper, Coqui, etc.)
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
COQUI_MODELS_DIR = MODELS_DIR / "coqui"
PIPER_MODELS_DIR = MODELS_DIR / "piper"
COQUI_MODELS_DIR.mkdir(exist_ok=True, parents=True)
PIPER_MODELS_DIR.mkdir(exist_ok=True, parents=True)

# Compat: aliases expected by tests/legacy code
COQUI_CACHE_DIR = COQUI_MODELS_DIR
PIPER_MODEL_CACHE_DIR = PIPER_MODELS_DIR

# Telemetry lives in .cache (temporary data)
TELEMETRY_DIR = CACHE_DIR / "telemetry"
TELEMETRY_DIR.mkdir(exist_ok=True, parents=True)

# Point external libraries to the project-root model directory
os.environ.setdefault("TTS_HOME", str(COQUI_MODELS_DIR))
os.environ.setdefault("COQUI_TTS_CACHE_DIR", str(COQUI_MODELS_DIR))
os.environ.setdefault("PIPER_MODEL_DIR", str(PIPER_MODELS_DIR))

# Auto-accept Coqui TTS license (CPML non-commercial)
os.environ.setdefault("COQUI_TOS_AGREED", "1")


def get_cache_path(*parts: str) -> Path:
    """
    Retorna um caminho dentro do diretório de cache do projeto.

    Args:
        *parts: Componentes do caminho relativo ao cache

    Returns:
        Path: Caminho completo para o arquivo/diretório de cache
    """
    return CACHE_DIR.joinpath(*parts)


def get_output_path(*parts: str) -> Path:
    """
    Retorna um caminho dentro do diretório de output do projeto.

    Args:
        *parts: Componentes do caminho relativo ao output

    Returns:
        Path: Caminho completo para o arquivo/diretório de output
    """
    return OUTPUT_DIR.joinpath(*parts)


if __name__ == "__main__":
    print(f"Raiz do projeto: {PROJECT_ROOT}")
    print(f"Cache: {CACHE_DIR}")
    print(f"Output: {OUTPUT_DIR}")
    print(f"Cache exists: {CACHE_DIR.exists()}")
    print(f"Output exists: {OUTPUT_DIR.exists()}")
