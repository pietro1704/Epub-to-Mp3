"""Run the legacy book conversion contract through installed native transports."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any, Dict, List, Optional

from .ios_conversion_options import _collected_options
from .ios_speech_preparation import prepare_audible_speech_text
from .tts import _piper_transport


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
    from . import ios_entrypoints as _runtime
    from .ios_entrypoints import (
        _chapter_matches,
        _clear_book_cache,
        _normalise_chapter_selector,
        _override_persistent_paths,
        _validate_audio_completeness,
    )

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
        # ``engine_chain_fallback`` is the CLI's explicit opt-in for the
        # ranked offline tier. Keep the default Edge-only, but honor that
        # switch when a native Piper transport is actually installed.
        piper_fallback_requested = bool(
            engine_chain_fallback and _piper_transport.get_transport() is not None
        )
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
    should_validate_audio = bool(validate_audio and not no_validate)

    for ch in selected:
        index_str = str(getattr(ch, "index", ""))
        name = str(getattr(ch, "name", "") or f"chapter_{index_str}")
        raw_speech = getattr(ch, "speech_text", None)
        text = (
            prepare_audible_speech_text(raw_speech) if raw_speech else getattr(ch, "text", "") or ""
        )
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
            _runtime.synthesize_chapter_via_transport(
                text,
                voice_id,
                str(out_path),
                piper_fallback_lang=piper_lang,
                validate_audio=should_validate_audio,
            )
            audio_complete, coverage = _validate_audio_completeness(out_path, char_count)
            if should_validate_audio and not audio_complete:
                raise RuntimeError(
                    "audio completeness below CLI threshold: " f"{coverage:.1f}% coverage"
                )
            entry["status"] = "completed"
            entry["output_path"] = str(out_path)
            entry["voice"] = voice_id
            entry["audio_coverage_percent"] = coverage
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
