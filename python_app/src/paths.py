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

    # Sobe na hierarquia até encontrar um marcador ou chegar na raiz do sistema
    while current != current.parent:
        if any((current / marker).exists() for marker in root_markers):
            return current
        current = current.parent

    # Fallback: assume que estamos em python_app/src e a raiz é 2 níveis acima
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


# Diretórios sempre na raiz do projeto (com overrides compartilhados)
CACHE_DIR = _resolve_cache_dir()  # Apenas para dados temporários de livros
OUTPUT_DIR = _resolve_output_dir()
MODELS_DIR = PROJECT_ROOT / "models"  # Modelos TTS (Piper, Coqui, etc.)

# Cria os diretórios se não existirem
CACHE_DIR.mkdir(exist_ok=True, parents=True)
OUTPUT_DIR.mkdir(exist_ok=True, parents=True)
MODELS_DIR.mkdir(exist_ok=True, parents=True)

# Subdiretórios para modelos específicos (dentro de root/models)
COQUI_MODELS_DIR = MODELS_DIR / "coqui"
PIPER_MODELS_DIR = MODELS_DIR / "piper"
COQUI_MODELS_DIR.mkdir(exist_ok=True, parents=True)
PIPER_MODELS_DIR.mkdir(exist_ok=True, parents=True)

# Compat: aliases expected by tests/legacy code
COQUI_CACHE_DIR = COQUI_MODELS_DIR
PIPER_MODEL_CACHE_DIR = PIPER_MODELS_DIR

# Telemetria pode ficar em .cache (dados temporários)
TELEMETRY_DIR = CACHE_DIR / "telemetry"
TELEMETRY_DIR.mkdir(exist_ok=True, parents=True)

# Força bibliotecas externas a usarem o diretório de modelos na raiz do projeto
os.environ.setdefault("TTS_HOME", str(COQUI_MODELS_DIR))
os.environ.setdefault("COQUI_TTS_CACHE_DIR", str(COQUI_MODELS_DIR))
os.environ.setdefault("PIPER_MODEL_DIR", str(PIPER_MODELS_DIR))

# Auto-aceitar licença Coqui TTS (CPML não-comercial)
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
