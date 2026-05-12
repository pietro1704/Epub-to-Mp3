"""Pluggable Piper TTS transport seam (iOS stub-only).

Mirror of ``_edge_transport.py`` for the offline Piper engine, scoped
to the iOS embed. On macOS / CLI / HF Spaces the Piper engine drives
``subprocess.Popen("piper", ...)`` directly (see ``piper_engine.py``);
that path is impossible on iOS because the sandbox forbids
``Process`` /``execve``. Slice 1b's eventual goal is for Swift to call
an in-process ONNX runtime, feed phoneme IDs from espeak-ng, and encode
the resulting float-array audio to MP3 via lame -- all behind this
seam.

**This is the stub-only slice.** None of those C dependencies (
``onnxruntime``, ``espeak-ng``, ``lame``) are cross-compiled for iOS in
the repo yet, so the transport simply does not get installed at boot
time and ``synthesize_chunk`` raises a clear ``RuntimeError`` instead
of guessing. See ``ios/PIPER-EMBED.md`` for the bring-up plan.

Public surface mirrors ``_edge_transport``:

* ``synthesize_chunk(text, lang) -> bytes`` -- raises ``RuntimeError``
  until a transport is installed; once installed, returns raw MP3 bytes.
* ``set_transport(fn)`` / ``reset_transport()`` -- Swift swap points.
* ``get_transport()`` -- introspection for tests.

The signature is ``(text, lang)`` -- ``lang`` is the BCP-47 / IETF
language tag (e.g. ``"pt-BR"``, ``"en-US"``) rather than a specific
voice name. Piper model selection is language-driven on iOS: the
Swift bridge looks up the bundled ``.onnx`` model for that language
and runs it. If we ever surface per-voice Piper models on iOS, this
contract may grow a third arg.
"""

from __future__ import annotations

from typing import Callable, Optional

# (text, language tag) -> raw MP3 bytes. Sync on purpose -- the Swift
# bridge will marshal the async ONNX call back through a
# DispatchSemaphore, same trick ``_edge_transport`` uses.
Transport = Callable[[str, str], bytes]

# No default transport. Until Swift wires one in via ``set_transport``
# the seam is intentionally inert; ``synthesize_chunk`` raises so a
# caller never gets silent zero-byte audio.
_TRANSPORT: Optional[Transport] = None


def set_transport(fn: Optional[Transport]) -> None:
    """Install ``fn`` as the active Piper transport. ``None`` removes
    any installed transport (back to the "no transport" state where
    ``synthesize_chunk`` raises).

    Called once at iOS app boot from ``PythonEmbed.bootstrap()`` with
    the Swift ``PiperBridge`` callback. Calling repeatedly replaces
    the previous transport -- last writer wins.
    """
    global _TRANSPORT
    _TRANSPORT = fn


def get_transport() -> Optional[Transport]:
    """Returns the currently-installed transport, or ``None`` if none
    is installed. Tests use this to assert install/reset behaviour
    without invoking the (potentially failing) transport.
    """
    return _TRANSPORT


def reset_transport() -> None:
    """Remove any installed transport. Tests call this in teardown so
    a monkey-patched transport doesn't leak into later tests.
    """
    set_transport(None)


def synthesize_chunk(text: str, lang: str) -> bytes:
    """The one call ``ios_entrypoints`` makes per chunk when Edge has
    failed and the caller requested ``fallback_engine="piper"``.

    Raises:
        RuntimeError: if no transport is installed. The error message
            points at ``ios/PIPER-EMBED.md`` so the operator knows the
            stub seam was hit instead of a real model.
    """
    transport = _TRANSPORT
    if transport is None:
        raise RuntimeError("piper transport not installed; see ios/PIPER-EMBED.md")
    result = transport(text, lang)
    if not isinstance(result, (bytes, bytearray)):
        raise TypeError(
            "piper transport returned "
            f"{type(result).__name__} (expected bytes); "
            "likely a Swift bridge regression where an error object "
            "was returned instead of raised"
        )
    return bytes(result)
