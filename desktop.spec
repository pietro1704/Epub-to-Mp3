# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller spec — Edge-TTS only desktop backend (onefile binary)."""

from pathlib import Path

ROOT = Path(SPECPATH)

a = Analysis(
    [str(ROOT / "python_app" / "desktop_main.py")],
    pathex=[str(ROOT)],
    binaries=[],
    datas=[
        # Include the full python_app package so all imports resolve
        (str(ROOT / "python_app"), "python_app"),
    ],
    hiddenimports=[
        # uvicorn internals not always auto-detected
        "uvicorn.logging",
        "uvicorn.loops",
        "uvicorn.loops.auto",
        "uvicorn.loops.asyncio",
        "uvicorn.protocols",
        "uvicorn.protocols.http",
        "uvicorn.protocols.http.auto",
        "uvicorn.protocols.http.h11_impl",
        "uvicorn.protocols.http.httptools_impl",
        "uvicorn.protocols.websockets",
        "uvicorn.protocols.websockets.auto",
        "uvicorn.protocols.websockets.websockets_impl",
        "uvicorn.protocols.websockets.wsproto_impl",
        "uvicorn.lifespan",
        "uvicorn.lifespan.on",
        # starlette internals
        "starlette.routing",
        "starlette.middleware",
        "starlette.staticfiles",
        "starlette.responses",
        # edge-tts
        "edge_tts",
        "edge_tts.communicate",
        # book parsing
        "ebooklib",
        "ebooklib.epub",
        "pypdf",
        "bs4",
        "bs4.builder",
        # language detection
        "langdetect",
        "langdetect.detector",
        # audio
        "mutagen",
        "mutagen.mp3",
        "static_ffmpeg",
        # async/network
        "aiohttp",
        "aiofiles",
        "certifi",
        # utils
        "psutil",
        "tqdm",
        "packaging",
    ],
    excludes=[
        # Heavy ML — not needed for Edge-TTS only
        "torch",
        "torchaudio",
        "TTS",
        "kokoro",
        "piper",
        "numpy",
        "pandas",
        "scipy",
        "sklearn",
        "matplotlib",
        "IPython",
        "jupyter",
        "notebook",
        "coqui",
        "tensorflow",
        "jax",
    ],
    noarchive=False,
)

pyz = PYZ(a.pure)

# Onefile: pass binaries + datas directly to EXE (no COLLECT step)
exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.datas,
    [],
    name="epub-to-mp3-server",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    upx_exclude=[],
    console=True,
    runtime_tmpdir=None,
)
