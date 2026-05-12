"""Pluggable Edge-TTS network transport seam.

The macOS sidecar / CLI / HF Spaces backend talk to the Microsoft
Edge-TTS endpoint via ``edge_tts.Communicate`` (a WebSocket on top of
``aiohttp``). iOS cannot ``dlopen`` libpython's ``_socket`` / ``_ssl``
extensions outside ``.framework`` bundles, so the aiohttp path is
unusable there.

This module exposes a single swappable callable -- the "transport" --
that synthesizes one text chunk into raw MP3 bytes. Default
implementation drives ``edge_tts.Communicate`` (same code the rest of
the project uses today, just lifted into a reusable function). The
iOS embed replaces it at boot via ``set_transport(swift_callback)`` so
``URLSessionWebSocketTask`` owns the socket while Python keeps owning
the orchestration (chunking, retry, validation).

Public surface is intentionally tiny:

* ``synthesize_chunk(text, voice, timeout=...) -> bytes`` -- the call
  Python code makes when it needs MP3 bytes for one chunk.
* ``set_transport(fn)`` -- iOS swaps the implementation here.
* ``get_transport()`` / ``reset_transport()`` -- introspection + test
  isolation.

Keeping the seam narrow means the giant ``edge_engine.py`` stays
untouched on the macOS/CLI/HF path; we only need a parallel iOS
entrypoint (``python_app.src.ios_entrypoints``) that goes through this
module instead of the full ``EdgeTTS`` class.
"""

from __future__ import annotations

import asyncio
import importlib
from typing import Callable, Optional

# Public type alias: (text, voice) -> raw MP3 bytes. Sync on purpose --
# Swift's URLSessionWebSocketTask runs on a detached Task and a
# DispatchSemaphore bridges back to a sync return on the Python thread,
# which is the simplest way to bridge PythonKit and Swift concurrency.
Transport = Callable[[str, str], bytes]


def _default_transport(text: str, voice: str) -> bytes:
    """Reference transport. Drives ``edge_tts.Communicate`` exactly the
    way ``edge_engine.EdgeTTS._synthesize_segment`` does for one chunk:
    open the stream, drain ``audio`` frames, return the bytes.

    Kept synchronous so callers don't need to know whether the active
    transport is async (Python / edge_tts) or sync (Swift bridge). We
    drive the asyncio loop locally with ``asyncio.run`` when there's no
    running loop, else ``loop.run_until_complete`` after creating a new
    one in a thread (rare on iOS -- iOS never uses this default).
    """
    edge_tts = importlib.import_module("edge_tts")

    async def _run() -> bytes:
        comm = edge_tts.Communicate(text, voice)
        chunks: list[bytes] = []
        async for frame in comm.stream():
            if frame.get("type") == "audio":
                chunks.append(frame.get("data", b""))
        return b"".join(chunks)

    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        loop = None
    if loop is None:
        return asyncio.run(_run())
    # Already inside a loop (rare for this path -- iOS uses the Swift
    # transport, not the default). Bounce through a worker thread so we
    # don't deadlock on the existing loop.
    import concurrent.futures

    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
        return pool.submit(asyncio.run, _run()).result()


_transport: Transport = _default_transport


def set_transport(fn: Optional[Transport]) -> None:
    """Install ``fn`` as the active transport. ``None`` resets to the
    default ``edge_tts.Communicate`` driver. Called once at iOS app
    boot from ``PythonEmbed.bootstrap()`` with the Swift bridge.
    """
    global _transport
    _transport = fn if fn is not None else _default_transport


def get_transport() -> Transport:
    """Returns the currently-installed transport. Tests use this to
    assert the swap succeeded without invoking the network.
    """
    return _transport


def reset_transport() -> None:
    """Restore the default transport. Tests call this in teardown so a
    monkey-patched transport doesn't leak into other tests.
    """
    set_transport(None)


def synthesize_chunk(text: str, voice: str) -> bytes:
    """The one call ``ios_entrypoints`` makes per chunk. Routes through
    whatever ``_transport`` is currently installed.

    Defensive type check: an installed transport MUST return ``bytes``.
    A regression in the iOS Swift bridge once *returned* a Python
    ``RuntimeError`` instance instead of raising it, which then flowed
    into ``audio.extend(...)`` and produced confusing downstream errors
    (or worse, a silent stall when truthy-but-non-bytes squeaked past a
    naive ``if mp3:`` check). Raising here keeps the failure attached
    to the chunk that caused it.
    """
    result = _transport(text, voice)
    if not isinstance(result, (bytes, bytearray)):
        raise TypeError(
            "edge transport returned "
            f"{type(result).__name__} (expected bytes); "
            "likely a Swift bridge regression where an error object "
            "was returned instead of raised"
        )
    return bytes(result)
