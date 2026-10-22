"""iOS-only entrypoints into the Python pipeline.

The macOS sidecar / CLI / HF Spaces backend drive ``converter.py``'s
``AudioConverter`` directly. iOS cannot: aiohttp / ``_socket`` /
``_ssl`` won't ``dlopen`` outside ``.framework`` bundles, so the
``EdgeTTS`` class -- which sits on top of those -- is dead weight on
iOS.

This module is the seam that lets Swift's ``PythonBridge`` reach into
the Python pipeline while letting Swift own the network. The flow:

1. Swift wires its ``EdgeTTSBridge`` (URLSessionWebSocketTask) into
   ``python_app.src.tts._edge_transport.set_transport(...)`` once at
   app boot.
2. Swift calls ``synthesize_chapter_via_transport(text, voice, out)``
   per chapter.
3. We chunk ``text`` here (paragraph-aware, char-bounded), invoke the
   transport once per chunk -- which on iOS dispatches to Swift, on
   any other host dispatches to ``edge_tts.Communicate`` -- concat
   the MP3 bytes, write the file, validate non-empty output.

Why a separate entrypoint instead of editing ``converter.py``: the
1637-test suite covers ``AudioConverter`` end-to-end with mocked
``edge_tts``; rerouting its TTS call site would require either
ripping out the ``EdgeTTS`` class wiring or duplicating its retry
loop here. Both are larger than the iOS use case justifies today.
This adapter shares the most important guarantees (chunking,
transport seam, file-write validation) with the main path and stays
small enough to audit at a glance.
"""

from __future__ import annotations

import os
import shutil
import sys
import time
from pathlib import Path
from typing import Any, Callable, List, Optional

# ``python_app.src.tts.__init__`` is intentionally lazy (PEP 562) so
# this import does NOT pull in ``factory.py`` -> ``urllib.request``
# -> ``base64`` -> ``struct`` -> ``_struct``. ``_struct`` is a
# CPython C extension shipped as a .so under ``lib-dynload/`` and
# iOS refuses to ``dlopen`` it outside a ``.framework`` bundle; if
# you ever re-add an eager ``factory`` import to ``tts/__init__.py``,
# every iOS chapter synthesis will crash here with
# ``No module named '_struct'``.
from .ios_book_conversion import convert_epub as convert_epub
from .ios_conversion_options import _OPTION_KEYS as _OPTION_KEYS
from .ios_conversion_options import _collected_options as _collected_options
from .ios_speech_preparation import _DEFAULT_EXPECTED_WPM as _DEFAULT_EXPECTED_WPM
from .ios_speech_preparation import _DEFAULT_FIRST_CHUNK_CHARS as _DEFAULT_FIRST_CHUNK_CHARS
from .ios_speech_preparation import _DEFAULT_IOS_CHUNK_CHARS as _DEFAULT_IOS_CHUNK_CHARS
from .ios_speech_preparation import _DEFAULT_MAX_SEGMENT_SECONDS as _DEFAULT_MAX_SEGMENT_SECONDS
from .ios_speech_preparation import _chunk_chars as _chunk_chars
from .ios_speech_preparation import _estimated_seconds as _estimated_seconds
from .ios_speech_preparation import _expected_wpm as _expected_wpm
from .ios_speech_preparation import _first_chunk_chars as _first_chunk_chars
from .ios_speech_preparation import _max_segment_seconds as _max_segment_seconds
from .ios_speech_preparation import _resolve_auto_voice as _resolve_auto_voice
from .ios_speech_preparation import _split_duration_bound as _split_duration_bound
from .ios_speech_preparation import _split_into_chunks as _split_into_chunks
from .ios_speech_preparation import prepare_audible_speech_text as prepare_audible_speech_text
from .ios_speech_preparation import prepare_chunks as prepare_chunks
from .tts import _edge_transport, _piper_transport


def _validate_audio_completeness(path: Path, text_length: int) -> tuple[bool, float]:
    """Apply the CLI's duration-based completeness check to an MP3 output."""
    if not path.exists():
        return False, 0.0
    if text_length < 1500:
        return True, 100.0
    try:
        from mutagen.mp3 import MP3

        duration_seconds = float(MP3(str(path)).info.length)
        expected_wpm = _expected_wpm()
        coverage = (duration_seconds / 60.0 * expected_wpm * 5.0 / text_length) * 100.0
        threshold = float(os.environ.get("TRUNCATION_THRESHOLD_PERCENT", "10"))
        return (100.0 - coverage) <= threshold, coverage
    except Exception:
        # Match the CLI: an unavailable MP3 parser must not reject otherwise
        # playable output; byte-level transport checks remain authoritative.
        return True, 100.0


def _should_validate_audio(validate_audio: bool) -> bool:
    """Respect the caller's validation choice and the iOS runtime override."""
    if not validate_audio:
        return False
    return os.environ.get("IOS_VALIDATE_AUDIO", "1").strip().lower() not in {
        "0",
        "false",
        "no",
        "off",
    }


def _edge_stream_max_retries() -> int:
    """Return the total Edge attempts allowed for one text chunk.

    The default matches ``edge_tts``'s ``EDGE_STREAM_MAX_RETRIES`` policy.
    Keep the bound finite: an iOS conversion must remain cancellable and must
    never turn a transient service failure into an infinite Python call.
    """
    raw = os.environ.get("EDGE_STREAM_MAX_RETRIES", "1")
    try:
        return max(1, min(int(raw), 6))
    except ValueError:
        return 1


def _edge_retry_delay(attempt: int) -> float:
    """Return bounded exponential backoff for the next Edge attempt."""
    raw = os.environ.get("IOS_EDGE_RETRY_BACKOFF_SECONDS", "2")
    try:
        base = max(0.0, min(float(raw), 30.0))
    except ValueError:
        base = 2.0
    return min(30.0, base * (2 ** max(0, attempt)))


def _synthesize_edge_chunk(
    chunk: str,
    voice: str,
    *,
    piper_fallback_lang: Optional[str] = None,
) -> bytes:
    """Synthesize one chunk with the CLI-compatible Edge retry policy."""
    attempts = _edge_stream_max_retries()
    last_error: Optional[Exception] = None
    for attempt in range(attempts):
        try:
            result = _edge_transport.synthesize_chunk(chunk, voice)
            if result:
                return bytes(result)
            last_error = RuntimeError("Edge transport returned no audio")
        except Exception as edge_error:  # noqa: BLE001 - classify at the boundary
            # Swift cancellation is bridged as a Python exception. Never
            # sleep or retry after the user has replaced/cancelled Listen.
            if "cancel" in str(edge_error).lower():
                raise
            last_error = edge_error

        if attempt + 1 < attempts:
            time.sleep(_edge_retry_delay(attempt))

    if piper_fallback_lang is not None and _piper_transport.get_transport() is not None:
        try:
            fallback = _piper_transport.synthesize_chunk(
                chunk,
                piper_fallback_lang,
            )
            if fallback:
                return bytes(fallback)
        except Exception as piper_error:  # noqa: BLE001 - preserve both causes
            raise RuntimeError(
                "ios_entrypoints: edge failed and piper fallback failed: "
                f"edge={last_error!r} piper={piper_error!r}"
            ) from piper_error

    if last_error is not None:
        raise last_error
    return b""


def synthesize_chapter_via_transport(
    text: str,
    voice: str,
    out_path: str,
    piper_fallback_lang: Optional[str] = None,
    validate_audio: bool = True,
) -> str:
    """iOS entrypoint. Chunks ``text``, synthesizes each chunk via the
    currently-installed Edge transport in
    ``python_app.src.tts._edge_transport``, concatenates the MP3 bytes,
    writes to ``out_path``.

    If ``piper_fallback_lang`` is non-``None`` AND a Piper transport is
    installed in ``python_app.src.tts._piper_transport``, per-chunk
    Edge failures are retried through Piper before being counted as
    failures. This is the slice-1b "stub-only" path: the seam exists,
    but until Swift installs a real Piper transport
    ``_piper_transport.synthesize_chunk`` raises
    ``"piper transport not installed"`` -- which we treat as a hard
    failure for that chunk (Edge already failed, Piper isn't there).

    Returns the resolved string path on success. Raises ``RuntimeError``
    if every chunk failed (no audio at all).

    NB: MP3 concatenation by raw byte append is the same trick
    ``EdgeTTS._synthesize_parallel`` uses (Edge emits ID3-less MP3
    frames; concatenation produces a valid playable file). If we ever
    need true container-level concat we can swap to ``ffmpeg -f
    concat`` here without touching the Swift side.
    """
    if (voice or "auto").strip().lower() == "auto":
        voice = _resolve_auto_voice(text)

    chunks = _split_into_chunks(text, _chunk_chars())
    if not chunks:
        raise RuntimeError("ios_entrypoints: empty input text")

    piper_available = (
        piper_fallback_lang is not None and _piper_transport.get_transport() is not None
    )

    audio = bytearray()
    for chunk in chunks:
        mp3 = _synthesize_edge_chunk(
            chunk,
            voice,
            piper_fallback_lang=piper_fallback_lang if piper_available else None,
        )
        if mp3:
            audio.extend(mp3)

    if not audio:
        raise RuntimeError("ios_entrypoints: transport produced no audio")

    destination = Path(out_path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(bytes(audio))
    if _should_validate_audio(validate_audio):
        audio_complete, coverage = _validate_audio_completeness(destination, len(text))
        if not audio_complete:
            destination.unlink(missing_ok=True)
            raise RuntimeError(
                "audio completeness below CLI threshold: " f"{coverage:.1f}% coverage"
            )
    return str(destination)


def synthesize_chapter_streaming(
    text: str,
    voice: str,
    out_path: str,
    on_segment: Callable[[bytes, int, int], None],
    piper_fallback_lang: Optional[str] = None,
    validate_audio: bool = True,
) -> str:
    """Segment-streaming iOS entrypoint.

    Identical to ``synthesize_chapter_via_transport`` in chunking and
    fallback logic, but calls ``on_segment(mp3_bytes, segment_index,
    total_chunks)`` immediately after each chunk closes rather than
    accumulating all audio before returning.  Swift installs a closure
    here that:

    1. Writes ``mp3_bytes`` to a numbered temp file.
    2. Creates an ``AVPlayerItem(url:)`` from that file.
    3. Inserts the item into the running ``AVQueuePlayer``.

    This enables the player to start the first segment within ~500 ms of
    synthesis start while subsequent segments stream in behind it —
    satisfying Apple's HIG < 3 s time-to-first-byte requirement.

    The final concatenated MP3 is still written to ``out_path`` so the
    chapter-level resume / cache reuse path works unchanged.

    Special behaviour for the first chunk: ``_first_chunk_chars()``
    (default 500 chars) is used instead of the normal chunk size, giving
    the Swift player a short burst to queue immediately. All subsequent
    chunks use ``_chunk_chars()`` (default 10 000 chars) for throughput.

    ``on_segment`` is called with ``total_chunks = 0`` initially because
    the total is not known until all chunks have been enumerated.  After
    the final chunk, ``on_segment`` is **not** re-called; callers that
    need the total should count invocations themselves or use the
    returned file path as completion signal.

    Raises ``RuntimeError`` if every chunk produced no audio.
    """
    text = (text or "").strip()
    if not text:
        raise RuntimeError("ios_entrypoints: empty input text")

    prepared = prepare_chunks(text, voice=voice, streaming=True)
    voice = str(prepared["voice"])
    chunks = list(prepared["chunks"])

    piper_available = (
        piper_fallback_lang is not None and _piper_transport.get_transport() is not None
    )

    audio = bytearray()
    for segment_index, chunk in enumerate(chunks):
        mp3 = _synthesize_edge_chunk(
            chunk,
            voice,
            piper_fallback_lang=piper_fallback_lang if piper_available else None,
        )

        if mp3:
            audio.extend(mp3)
            # Deliver this segment to Swift immediately — total_chunks is
            # not known in advance, pass 0 as sentinel.
            on_segment(bytes(mp3), segment_index, 0)

    if not audio:
        raise RuntimeError("ios_entrypoints: transport produced no audio")

    destination = Path(out_path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(bytes(audio))
    if _should_validate_audio(validate_audio):
        audio_complete, coverage = _validate_audio_completeness(destination, len(text))
        if not audio_complete:
            destination.unlink(missing_ok=True)
            raise RuntimeError(
                "audio completeness below CLI threshold: " f"{coverage:.1f}% coverage"
            )
    return str(destination)


def _override_persistent_paths(cache_dir: str, output_dir: str) -> Path:
    """Set env + patch the in-memory ``paths`` module so subsequent
    imports / readers honour the iOS sandbox directories.

    Returns the resolved ``CACHE_DIR`` ``Path`` for downstream callers
    (``CacheManager`` needs an explicit ``cache_dir=`` argument; we
    don't rely on it sniffing the env again).
    """
    cache_path = Path(cache_dir).expanduser()
    output_path = Path(output_dir).expanduser()
    cache_path.mkdir(parents=True, exist_ok=True)
    output_path.mkdir(parents=True, exist_ok=True)

    # 1. Env so future fresh imports see the right values.
    os.environ["CACHE_DIR"] = str(cache_path)
    os.environ["OUTPUT_DIR"] = str(output_path)
    # PERSISTENT_ROOT is a sandbox-wide anchor. We pick the parent of the
    # cache dir to keep ``.cache/`` and ``output/`` siblings, matching
    # the layout the CLI uses under PROJECT_ROOT.
    persistent_root = cache_path.parent if cache_path.parent != cache_path else cache_path
    os.environ["PERSISTENT_ROOT"] = str(persistent_root)

    # 2. Patch ``paths`` if already imported. Using ``setattr`` on the
    # live module is safe -- ``importlib.reload`` would re-execute the
    # body and rebuild dataclasses, breaking any caller (tests, Swift
    # bridge) that grabbed a reference earlier.
    paths_mod = sys.modules.get("python_app.src.paths")
    if paths_mod is not None:
        paths_mod.CACHE_DIR = cache_path
        paths_mod.OUTPUT_DIR = output_path
        paths_mod.PERSISTENT_ROOT = persistent_root
        for sub, attr in (
            (".jobs", "JOBS_DIR"),
            (".uploads", "UPLOADS_DIR"),
            (".job_inputs", "JOB_INPUTS_DIR"),
            (".source_backups", "SOURCE_BACKUPS_DIR"),
            (".logs", "LOGS_DIR"),
        ):
            target = persistent_root / sub
            target.mkdir(parents=True, exist_ok=True)
            setattr(paths_mod, attr, target)
        telemetry = cache_path / "telemetry"
        telemetry.mkdir(parents=True, exist_ok=True)
        paths_mod.TELEMETRY_DIR = telemetry

    return cache_path


def _normalise_chapter_selector(chapter: Any) -> Optional[List[str]]:
    """Mirror the CLI's ``--chapter`` semantics in lightweight form.

    The full CLI supports dotted indices (``3.1``), title substrings, and
    comma-separated lists. This slice only needs index-based selection
    (Swift UI sends integers); we accept a few shapes for parity:

    * ``None`` / empty -> no filter (all chapters).
    * ``int`` -> single 1-based index.
    * ``str`` -> single token, may be ``"3"`` or ``"3,5"`` or ``"3.1"``.
    * ``list``/``tuple`` -> repeat-flag equivalent.

    Returns a list of string tokens, or ``None`` to mean "no filter".
    """
    if chapter is None:
        return None
    if isinstance(chapter, (list, tuple)):
        flat: List[str] = []
        for item in chapter:
            if item is None:
                continue
            flat.extend(str(item).split(","))
        cleaned = [tok.strip() for tok in flat if str(tok).strip()]
        return cleaned or None
    if isinstance(chapter, int):
        return [str(chapter)]
    text = str(chapter).strip()
    if not text:
        return None
    return [tok.strip() for tok in text.split(",") if tok.strip()]


def _chapter_matches(chapter: Any, selectors: List[str]) -> bool:
    """Match a Chapter against CLI-style selector tokens. Compares the
    index (as string), the dotted-index parent, and falls back to a
    case-insensitive substring match against the chapter name.
    """
    index_str = str(getattr(chapter, "index", ""))
    name = str(getattr(chapter, "name", ""))
    for token in selectors:
        if token == index_str:
            return True
        if "." in index_str and index_str.split(".", 1)[0] == token:
            return True
        if token and token.lower() in name.lower():
            return True
    return False


def _clear_book_cache(cache_root: Path, output_root: Path, book_title: str) -> None:
    """Remove cached text + output for ``book_title`` so the next pass
    regenerates everything. Best-effort: missing dirs are ignored.
    """
    from .utils import FileManager

    sanitized = FileManager.sanitize_filename(book_title or "untitled")
    for target in (cache_root / sanitized, output_root / sanitized):
        if target.exists():
            shutil.rmtree(target, ignore_errors=True)


__all__ = [
    "prepare_audible_speech_text",
    "prepare_chunks",
    "synthesize_chapter_via_transport",
    "synthesize_chapter_streaming",
    "convert_epub",
]
