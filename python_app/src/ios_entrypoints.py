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
import re
import shutil
import sys
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional

from .tts import _edge_transport, _piper_transport

# Mirror ``EdgeTTS._DEFAULT_CHUNK_SIZE`` (12_000) but cap a touch lower
# so paragraph-boundary chunking has slack to land on whitespace
# instead of mid-word. Configurable via env for parity with the rest
# of the Edge tuning surface.
_DEFAULT_IOS_CHUNK_CHARS = 10_000


def _chunk_chars() -> int:
    raw = os.environ.get("IOS_EDGE_CHUNK_CHARS")
    if not raw:
        return _DEFAULT_IOS_CHUNK_CHARS
    try:
        value = int(raw)
    except ValueError:
        return _DEFAULT_IOS_CHUNK_CHARS
    return max(1_000, min(value, 15_000))


def _split_into_chunks(text: str, max_chars: int) -> List[str]:
    """Paragraph-aware char-bounded chunker. Splits on double newlines
    first, then on sentence boundaries, then hard-wraps as a last
    resort. Never returns an empty list for non-empty input.

    Deliberately simple: ``EdgeTTS._chunk_text`` does dialogue-voice
    routing + SSML prosody wrapping that depends on configuration we
    don't surface to iOS yet. Keeping iOS on plain-text chunks matches
    what ``EdgeTTSBridge.swift`` currently emits.
    """
    text = (text or "").strip()
    if not text:
        return []
    if len(text) <= max_chars:
        return [text]

    chunks: List[str] = []
    buffer = ""
    for paragraph in re.split(r"\n\s*\n", text):
        paragraph = paragraph.strip()
        if not paragraph:
            continue
        # If the paragraph itself exceeds max_chars, fall back to
        # sentence-level splitting so we don't emit a giant chunk.
        candidates: Iterable[str]
        if len(paragraph) > max_chars:
            candidates = re.split(r"(?<=[.!?])\s+", paragraph)
        else:
            candidates = [paragraph]
        for piece in candidates:
            piece = piece.strip()
            if not piece:
                continue
            # Hard-wrap any remaining oversize piece.
            while len(piece) > max_chars:
                head, piece = piece[:max_chars], piece[max_chars:].lstrip()
                if buffer:
                    chunks.append(buffer)
                    buffer = ""
                chunks.append(head)
            if not piece:
                continue
            if len(buffer) + len(piece) + 2 <= max_chars:
                buffer = f"{buffer}\n\n{piece}" if buffer else piece
            else:
                if buffer:
                    chunks.append(buffer)
                buffer = piece
    if buffer:
        chunks.append(buffer)
    return chunks


def synthesize_chapter_via_transport(
    text: str,
    voice: str,
    out_path: str,
    piper_fallback_lang: Optional[str] = None,
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
    chunks = _split_into_chunks(text, _chunk_chars())
    if not chunks:
        raise RuntimeError("ios_entrypoints: empty input text")

    piper_available = (
        piper_fallback_lang is not None and _piper_transport.get_transport() is not None
    )

    audio = bytearray()
    for chunk in chunks:
        mp3: bytes = b""
        try:
            mp3 = _edge_transport.synthesize_chunk(chunk, voice)
        except Exception as edge_exc:  # noqa: BLE001 - any edge failure is a fallback trigger
            if not piper_available:
                raise
            try:
                mp3 = _piper_transport.synthesize_chunk(
                    chunk,
                    piper_fallback_lang,  # type: ignore[arg-type]
                )
            except Exception as piper_exc:  # noqa: BLE001
                raise RuntimeError(
                    "ios_entrypoints: edge failed and piper fallback failed: "
                    f"edge={edge_exc!r} piper={piper_exc!r}"
                ) from piper_exc
        else:
            # Edge returned empty bytes -- treat as a soft failure and
            # try Piper if available (matches the Edge segment-integrity
            # tolerance pattern in the desktop path).
            if not mp3 and piper_available:
                try:
                    mp3 = _piper_transport.synthesize_chunk(
                        chunk,
                        piper_fallback_lang,  # type: ignore[arg-type]
                    )
                except Exception:  # noqa: BLE001
                    # Piper failed too -- keep going; the no-audio check
                    # below will raise if every chunk yielded nothing.
                    mp3 = b""
        if mp3:
            audio.extend(mp3)

    if not audio:
        raise RuntimeError("ios_entrypoints: transport produced no audio")

    destination = Path(out_path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(bytes(audio))
    return str(destination)


# ---------------------------------------------------------------------------
# CLI superset: ``convert_epub``
# ---------------------------------------------------------------------------
#
# Slice 1a goal: expose the full CLI flag surface (``python -m
# python_app.main convert ...``) as a single Python entrypoint Swift can
# call. iOS cannot run the real ``AudioConverter.convert`` end-to-end --
# the ``EdgeTTS`` class depends on ``aiohttp``/``_socket``/``_ssl`` which
# won't ``dlopen`` outside ``.framework`` bundles. Network ownership
# lives in Swift (``EdgeTTSBridge`` -> ``URLSessionWebSocketTask``) and
# is wired into ``_edge_transport.set_transport(...)`` at app boot.
#
# So this entrypoint:
#   1. Overrides ``PERSISTENT_ROOT``/``CACHE_DIR``/``OUTPUT_DIR`` via env
#      AND patches ``python_app.src.paths`` module-level constants in
#      case the module was already imported (no ``importlib.reload`` --
#      tests in the suite hold class references that reload would break;
#      see ``feedback_test_isolation.md``).
#   2. Parses the EPUB through ``EbookReader`` -- same parser the CLI /
#      sidecar / HF Spaces use.
#   3. Applies the CLI's chapter selection / clear-cache / show-structure
#      semantics.
#   4. Synthesises each surviving chapter through
#      ``synthesize_chapter_via_transport`` -- so the Swift Edge transport
#      handles the network and Python keeps owning chunking + file write.
#   5. Returns ``{"manifest": [...], "outputs": [paths], "errors": [...]}``.
#
# Edge-only this slice. Piper lands in slice 1b (parallel work). Passing
# ``engine="piper"`` or ``fallback_engine="piper"`` raises a clear
# ``RuntimeError`` instead of silently fanning out (the Carl regression:
# pt-BR audiobook narrated by English Piper because fallback flipped
# behind the user's back -- see ``feedback_language_correctness_priority``).
#
# All other CLI flags are accepted as keyword args for parity (so iOS UI
# can map 1:1 against the CLI without inventing names). Most are stored
# on the result under ``applied_options`` for inspection; the few that
# affect this slice's behaviour (``chapter``, ``clear_cache``,
# ``show_structure``, ``max_chapter_chars``, ``voice``, ``no_cache``,
# ``force_reprocess``, ``filter_chapters``) are honoured here directly.


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


def convert_epub(
    epub_path: str,
    output_dir: str,
    cache_dir: str,
    voice: str = "auto",
    engine: str = "edge",
    fallback_engine: str = "none",
    chapter: Any = None,
    clear_cache: bool = False,
    show_structure: bool = False,
    max_chapter_chars: int = 0,
    batch_dir: Optional[str] = None,
    # ---- CLI superset accepted for parity (mirror order in main.py) ----
    extra_inputs: Optional[List[str]] = None,
    engine_chain_fallback: bool = False,
    prewarm_edge: bool = False,
    prewarm_piper: bool = False,
    inject_title_pause: int = 0,
    model: Optional[str] = None,
    detect_language: bool = False,
    filter_chapters: bool = False,
    verbose: Optional[bool] = None,
    formatting_cues: Optional[bool] = None,
    character_voices: Optional[bool] = None,
    narrator_voice: Optional[str] = None,
    character_voice: Optional[str] = None,
    listen: bool = False,
    export_to_iphone: Optional[bool] = None,
    no_parallel: bool = False,
    multi_engine_parallel: bool = False,
    no_footnote: bool = False,
    footnote_chapter_end: bool = False,
    no_cache: bool = False,
    resume_from_failure: Optional[bool] = None,
    verify_only: bool = False,
    fix_mode: bool = False,
    verify_transcription: Optional[bool] = None,
    deep_validate: Optional[bool] = None,
    validate_during_conversion: bool = False,
    auto_validate_output: Optional[bool] = None,
    auto_fix_output: Optional[bool] = None,
    no_validate: bool = False,
    validate_text: bool = True,
    validate_audio: bool = True,
    strict_validate: bool = False,
    transcription_model: str = "small",
    validation_language: Optional[str] = None,
    from_chapter_to_end: Optional[str] = None,
    from_chapter_to_chapter: Optional[str] = None,
    sections: Optional[List[str]] = None,
    priority: Optional[List[str]] = None,
    language: Optional[str] = None,
    use_language_detection: Optional[bool] = None,
    prioritize_primary_language: Optional[bool] = None,
    ui_language: Optional[str] = None,
    max_performance: bool = False,
    overnight: bool = False,
    profile: Optional[str] = None,
    speed_scenario: str = "auto",
    parallel_slots: Optional[int] = None,
    chapter_stall_seconds: Optional[float] = None,
    edge_chunk_chars: Optional[int] = None,
    edge_max_segment_seconds: Optional[int] = None,
    edge_network_tier: Optional[str] = None,
    edge_enable_parallel: Optional[bool] = None,
    edge_auto_tune: Optional[bool] = None,
    edge_stable_mode: Optional[bool] = None,
    piper_max_procs: Optional[int] = None,
    piper_chunk_chars: Optional[int] = None,
    bitrate: Optional[str] = None,
    sample_rate: Optional[int] = None,
    channels: Optional[int] = None,
    force_reprocess: bool = False,
    health_check_interval_seconds: Optional[float] = None,
    health_check_slow_edge_cps: Optional[float] = None,
    health_check_slow_cps: Optional[float] = None,
    health_check_high_cpu: Optional[float] = None,
    health_check_high_mem: Optional[float] = None,
    health_check_ok_cpu: Optional[float] = None,
    health_check_ok_mem: Optional[float] = None,
    health_check_slow_streak: Optional[int] = None,
    retry_failed: Optional[int] = None,
    retry_failed_manual: bool = False,
    show_metrics_summary: bool = False,
    show_metrics_dashboard: bool = False,
    open_metrics_dashboard: bool = False,
    export_metrics_bundle: bool = False,
    chapter_prefetch: Optional[bool] = None,
    stage_pipeline: Optional[bool] = None,
    stage_pipeline_depth: Optional[int] = None,
    auto_ab: Optional[bool] = None,
    adaptive_checkpoint: Optional[bool] = None,
    stop_on_error: bool = False,
) -> Dict[str, Any]:
    """Run the full conversion pipeline against ``epub_path``.

    iOS-shaped invariants enforced here:

    * **Edge-only**: ``engine`` is normalised to ``"edge"`` (``"auto"``
      is accepted as an alias); ``fallback_engine`` is forced to
      ``"none"``. Anything else raises ``RuntimeError`` so a UI bug
      can't silently swap to Piper (Carl regression guard).
    * **Sandboxed paths**: ``cache_dir`` and ``output_dir`` are
      mandatory; ``PROJECT_ROOT`` is meaningless on iOS.
    * **Network owned by Swift**: synthesis goes through
      ``_edge_transport.synthesize_chunk`` -- which Swift swaps for its
      ``URLSessionWebSocketTask`` bridge at app boot.

    Returns ``{"manifest": [...], "outputs": [...], "errors": [...]}``
    where ``manifest`` is a list of per-chapter dicts (``index``,
    ``name``, ``char_count``, ``output_path`` or ``error``) suitable
    for Swift to JSON-decode into ``ConvertResult``.

    Raises:
        FileNotFoundError: ``epub_path`` does not exist.
        RuntimeError: engine != edge in this slice; or transport
            returned no audio.
    """
    # ---------------- Engine gate (edge-only this slice) -----------------
    normalised_engine = (engine or "edge").strip().lower()
    if normalised_engine in {"auto", ""}:
        normalised_engine = "edge"
    if normalised_engine != "edge":
        raise RuntimeError(
            f"convert_epub: engine={engine!r} is not supported on iOS in this slice. "
            "Slice 1a is Edge-only; Piper support arrives in slice 1b."
        )
    # Piper fallback gate. The CLI uses ``--fallback-engine piper`` to
    # enable per-chunk Piper retry when Edge fails. iOS slice 1b
    # installs a seam (``_piper_transport.set_transport``) but the
    # actual ONNX/espeak-ng/lame cross-compile is deferred -- so the
    # transport is usually not installed at runtime. We honour the
    # request only when the seam is wired; otherwise we raise with a
    # pointer at the bring-up doc so the operator knows what to build.
    normalised_fallback = (fallback_engine or "none").strip().lower()
    piper_fallback_requested = False
    if normalised_fallback in {"", "none"}:
        piper_fallback_requested = False
    elif normalised_fallback == "piper":
        if _piper_transport.get_transport() is None:
            raise RuntimeError(
                "convert_epub: piper fallback requested but no piper transport "
                "installed -- see ios/PIPER-EMBED.md"
            )
        piper_fallback_requested = True
    else:
        raise RuntimeError(
            f"convert_epub: fallback_engine={fallback_engine!r} is not supported on iOS. "
            "Accepted values: 'none' (default) or 'piper' (requires installed transport)."
        )

    # ---------------- Path sandbox ----------------
    cache_root = _override_persistent_paths(cache_dir, output_dir)
    output_root = Path(output_dir).expanduser()

    # ---------------- Input validation ----------------
    epub_p = Path(epub_path).expanduser()
    if not epub_p.exists():
        raise FileNotFoundError(f"convert_epub: input not found: {epub_p}")

    # ``MAX_CHAPTER_CHARS=0`` disables the cap, matching the CLI default.
    if max_chapter_chars and max_chapter_chars > 0:
        os.environ["MAX_CHAPTER_CHARS"] = str(int(max_chapter_chars))

    # ---------------- Parse EPUB ----------------
    # Lazy imports so the engine-gate error path doesn't pay the cost.
    from .cache_manager import CacheManager
    from .ebook_reader import EbookReader
    from .utils import FileManager

    reader = EbookReader(str(epub_p))
    book_title = reader.title or epub_p.stem
    sanitized_title = FileManager.sanitize_filename(book_title)

    # ---------------- Cache management ----------------
    cache_manager = CacheManager(cache_dir=cache_root)
    if clear_cache or no_cache:
        _clear_book_cache(cache_root, output_root, book_title)
        try:
            cache_manager.clear_cache(epub_p, title=book_title)
        except Exception:
            # CacheManager.clear_cache is best-effort; missing index is
            # not an error from the user's perspective.
            pass

    # ---------------- Chapter selection ----------------
    all_chapters = reader.get_chapter_structure(preserve_all=not filter_chapters)
    selectors = _normalise_chapter_selector(chapter)
    if selectors:
        selected = [c for c in all_chapters if _chapter_matches(c, selectors)]
    else:
        selected = list(all_chapters)

    # ---------------- show-structure short-circuit ----------------
    if show_structure:
        structure = [
            {
                "index": str(getattr(c, "index", "")),
                "name": getattr(c, "name", ""),
                "level": int(getattr(c, "level", 1)),
                "char_count": len(getattr(c, "text", "") or ""),
            }
            for c in all_chapters
        ]
        return {
            "manifest": structure,
            "outputs": [],
            "errors": [],
            "book_title": book_title,
            "book_author": getattr(reader, "author", "") or "",
            "show_structure": True,
            "applied_options": _collected_options(locals()),
        }

    # ---------------- Oversize guard ----------------
    char_cap = int(max_chapter_chars or 0)

    # ---------------- Output directory ----------------
    book_output_dir = output_root / sanitized_title
    book_output_dir.mkdir(parents=True, exist_ok=True)

    # ---------------- Voice resolution ----------------
    voice_id = (voice or "auto").strip()
    book_lang = (reader.language or "").lower()
    if voice_id.lower() == "auto":
        # Sensible default per book language. The Swift UI overrides
        # this when the user picks a voice; we deliberately don't reach
        # into the full ``VoiceConfigProvider`` here -- iOS surfaces
        # voice selection in its own settings sheet.
        if book_lang.startswith("pt"):
            voice_id = "pt-BR-FranciscaNeural"
        else:
            voice_id = "en-US-AriaNeural"

    # Piper fallback uses BCP-47 language tags rather than Edge voice
    # names. Map the book's detected language to the closest tag the
    # Swift PiperBridge knows about (pt-BR, en-US in slice 1b).
    piper_lang: Optional[str] = None
    if piper_fallback_requested:
        if book_lang.startswith("pt"):
            piper_lang = "pt-BR"
        else:
            piper_lang = "en-US"

    # ---------------- Synthesis loop ----------------
    manifest: List[Dict[str, Any]] = []
    outputs: List[str] = []
    errors: List[str] = []

    for ch in selected:
        index_str = str(getattr(ch, "index", ""))
        name = str(getattr(ch, "name", "") or f"chapter_{index_str}")
        text = getattr(ch, "speech_text", None) or getattr(ch, "text", "") or ""
        char_count = len(text)

        entry: Dict[str, Any] = {
            "index": index_str,
            "name": name,
            "level": int(getattr(ch, "level", 1)),
            "char_count": char_count,
        }

        if not text.strip():
            entry["status"] = "skipped"
            entry["reason"] = "empty"
            manifest.append(entry)
            continue

        if char_cap and char_count > char_cap:
            entry["status"] = "skipped"
            entry["reason"] = f"exceeds max_chapter_chars={char_cap}"
            manifest.append(entry)
            errors.append(
                f"chapter {index_str} ({char_count} chars) exceeds max_chapter_chars={char_cap}"
            )
            continue

        safe_name = FileManager.sanitize_filename(name)
        out_path = book_output_dir / f"{index_str} - {safe_name}.mp3"

        # Reuse existing output unless caller asked to redo.
        if not (force_reprocess or no_cache or clear_cache):
            if out_path.exists() and out_path.stat().st_size > 0:
                entry["status"] = "cached"
                entry["output_path"] = str(out_path)
                manifest.append(entry)
                outputs.append(str(out_path))
                continue

        try:
            synthesize_chapter_via_transport(
                text,
                voice_id,
                str(out_path),
                piper_fallback_lang=piper_lang,
            )
            entry["status"] = "completed"
            entry["output_path"] = str(out_path)
            entry["voice"] = voice_id
            if piper_lang is not None:
                entry["piper_fallback_lang"] = piper_lang
            manifest.append(entry)
            outputs.append(str(out_path))
        except Exception as exc:  # noqa: BLE001 - surface every failure
            entry["status"] = "failed"
            entry["error"] = str(exc)
            manifest.append(entry)
            errors.append(f"chapter {index_str}: {exc}")

    return {
        "manifest": manifest,
        "outputs": outputs,
        "errors": errors,
        "book_title": book_title,
        "book_author": getattr(reader, "author", "") or "",
        "output_dir": str(book_output_dir),
        "cache_dir": str(cache_root),
        "show_structure": False,
        "applied_options": _collected_options(locals()),
    }


# Snapshot of every CLI flag we accepted, returned to the caller so
# Swift can confirm what was applied and the test suite can assert flag
# plumbing without invoking the full pipeline.
_OPTION_KEYS = (
    "voice",
    "engine",
    "fallback_engine",
    "chapter",
    "clear_cache",
    "show_structure",
    "max_chapter_chars",
    "batch_dir",
    "engine_chain_fallback",
    "prewarm_edge",
    "prewarm_piper",
    "inject_title_pause",
    "model",
    "detect_language",
    "filter_chapters",
    "verbose",
    "formatting_cues",
    "character_voices",
    "narrator_voice",
    "character_voice",
    "listen",
    "export_to_iphone",
    "no_parallel",
    "multi_engine_parallel",
    "no_footnote",
    "footnote_chapter_end",
    "no_cache",
    "resume_from_failure",
    "verify_only",
    "fix_mode",
    "verify_transcription",
    "deep_validate",
    "validate_during_conversion",
    "auto_validate_output",
    "auto_fix_output",
    "no_validate",
    "validate_text",
    "validate_audio",
    "strict_validate",
    "transcription_model",
    "validation_language",
    "from_chapter_to_end",
    "from_chapter_to_chapter",
    "sections",
    "priority",
    "language",
    "use_language_detection",
    "prioritize_primary_language",
    "ui_language",
    "max_performance",
    "overnight",
    "profile",
    "speed_scenario",
    "parallel_slots",
    "chapter_stall_seconds",
    "edge_chunk_chars",
    "edge_max_segment_seconds",
    "edge_network_tier",
    "edge_enable_parallel",
    "edge_auto_tune",
    "edge_stable_mode",
    "piper_max_procs",
    "piper_chunk_chars",
    "bitrate",
    "sample_rate",
    "channels",
    "force_reprocess",
    "health_check_interval_seconds",
    "health_check_slow_edge_cps",
    "health_check_slow_cps",
    "health_check_high_cpu",
    "health_check_high_mem",
    "health_check_ok_cpu",
    "health_check_ok_mem",
    "health_check_slow_streak",
    "retry_failed",
    "retry_failed_manual",
    "show_metrics_summary",
    "show_metrics_dashboard",
    "open_metrics_dashboard",
    "export_metrics_bundle",
    "chapter_prefetch",
    "stage_pipeline",
    "stage_pipeline_depth",
    "auto_ab",
    "adaptive_checkpoint",
    "stop_on_error",
)


def _collected_options(scope: Dict[str, Any]) -> Dict[str, Any]:
    """Return only the CLI-surface kwargs from a ``locals()`` dump,
    skipping local variables that happen to share a name. Keeps the
    Swift-side JSON small and the ``applied_options`` contract stable.
    """
    return {key: scope.get(key) for key in _OPTION_KEYS if key in scope}


__all__ = ["synthesize_chapter_via_transport", "convert_epub"]
