#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Simplified EBook to Audiobook Converter - SOLID principles applied
Reduced from 564 to ~100 lines while maintaining all functionality
"""

import argparse
import asyncio
import contextlib
import copy
import glob
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
import traceback
import unicodedata
import zipfile
from dataclasses import dataclass
from dataclasses import replace as _dc_replace
from pathlib import Path
from typing import Any, Dict, List, Optional, Set, Tuple
from urllib.parse import unquote

# macOS Intel + NumPy + Accelerate triggers FPE at import time. Disable Accelerate usage.
os.environ.setdefault("NPY_DISABLE_MAC_OS_ACCELERATE", "1")

try:  # Optional dependency for shell tab completion
    import argcomplete  # type: ignore
    from argcomplete.completers import ChoicesCompleter, FilesCompleter
except ImportError:  # pragma: no cover - argcomplete is optional
    argcomplete = None
    ChoicesCompleter = None
    FilesCompleter = None

# Local imports
from src.benchmark_profile import apply_benchmark_profile
from src.chapter_utils import deduplicate_chapters_by_content
from src.config import AppConfig, ConversionConfig
from src.converter import AudioConverter, ConversionResult
from src.ebook_reader import Chapter, EbookReader, FormattingSegment, TextProcessor
from src.i18n import get_localization
from src.language import (
    LanguageDetector,
    LanguageMarkup,
    LanguageProfile,
    get_language_detector,
)
from src.paths import JOB_INPUTS_DIR, JOBS_DIR, OUTPUT_DIR, UPLOADS_DIR
from src.text_formatting import PRESERVE_TTS_LAYOUT, TextFormattingProcessor
from src.ui.menu import MenuInterface
from src.utils import FileManager, resolve_cache_root

_FALLBACK_ENGINE_CHOICES = {"piper", "kokoro", "coqui", "spark", "none"}


def _resolve_cli_fallback_engine(
    flag_value: Optional[str], env_value: Optional[str]
) -> Optional[str]:
    """Resolve the CLI fallback-engine preference.

    The ``--fallback-engine`` flag wins when set to anything other than
    ``auto``. Otherwise ``FALLBACK_ENGINE_OVERRIDE`` is consulted so a single
    env var can configure both the CLI and the server's engine chain.
    Returns ``None`` when no override applies (engine-selection mixin then
    chooses based on language).
    """
    flag = (flag_value or "auto").strip().lower()
    if flag and flag != "auto":
        return flag
    env = (env_value or "").strip().lower()
    if env and env != "auto" and env in _FALLBACK_ENGINE_CHOICES:
        return env
    return None


def _prewarm_piper_pipeline(language: Optional[str] = None) -> bool:
    """Best-effort Piper warm-up: locate binary + resolve model. Never raises."""
    try:
        from src.tts.piper_engine import prewarm_piper
    except Exception:
        return False
    try:
        ok = prewarm_piper(language)
    except Exception:
        ok = False
    if ok:
        print("✅ Piper binary + model located")
    else:
        print("⏭️  Piper pre-warm skipped (binary or model unavailable)")
    return bool(ok)


def _prewarm_edge_pipeline(voice: Optional[str] = None) -> bool:
    """Eagerly open an Edge-TTS connection so the first chapter doesn't pay
    the TLS handshake. Best-effort — never raises.
    """
    try:
        import asyncio as _asyncio

        from src.tts.edge_engine import prewarm_edge
    except Exception:
        return False
    pick = (voice or "en-US-AriaNeural").strip() or "en-US-AriaNeural"
    try:
        ok = _asyncio.run(prewarm_edge(pick))
    except RuntimeError:
        # Already inside a running loop (rare in CLI). Skip silently.
        return False
    except Exception:
        ok = False
    if ok:
        print("✅ Edge-TTS connection pre-warmed")
    else:
        print("⏭️  Edge-TTS pre-warm skipped (offline or unavailable)")
    return bool(ok)


def _prewarm_kokoro_pipeline(language: Optional[str]) -> bool:
    """Eagerly load the Kokoro KPipeline so the first chapter doesn't pay the cost.

    Returns True on success, False if Kokoro is unsupported for the language or
    the import failed. Never raises — pre-warm is best-effort.
    """
    try:
        from src.tts.kokoro_engine import kokoro_supports_language
    except Exception:
        return False
    if not kokoro_supports_language(language):
        print(f"⏭️  Kokoro pre-warm skipped (language '{language}' not supported)")
        return False
    try:
        from src.tts.kokoro_engine import _ensure_kokoro

        _ensure_kokoro()
        print("✅ Kokoro pipeline pre-warmed")
        return True
    except Exception as exc:
        print(f"⏭️  Kokoro pre-warm failed: {exc}")
        return False


@dataclass
class ChapterStructureItem:
    chapter: Chapter
    index: str
    main_title: Optional[str]
    sub_title: Optional[str]
    preview: Optional[str]
    display_name: str
    text_override: Optional[str] = None
    speak_heading: bool = True


class ConverterApplication:
    """Main application class following SRP"""

    PREVIEW_WORD_LIMIT = 30
    FOOTNOTE_CONTEXT_WORDS = 8
    SUPPORTED_INPUT_SUFFIXES = (".epub", ".pdf")

    def __init__(self, ui_language: Optional[str] = None):
        self.localization = get_localization(ui_language)
        self.config = AppConfig()
        self.menu = MenuInterface(localization=self.localization)
        self.converter = AudioConverter(localization=self.localization)
        self.cache_root = resolve_cache_root()
        self.language_detector: LanguageDetector = get_language_detector()
        self.language_markup = LanguageMarkup(self.language_detector)
        self.language_profile: Optional[LanguageProfile] = None
        self._interactive_mode = True
        self._footnote_summary_printed = False

    @staticmethod
    def _resolve_verbose(args: argparse.Namespace) -> bool:
        raw = getattr(args, "verbose", None)
        if raw is None:
            return True
        return bool(raw)

    @staticmethod
    def _resolve_formatting_cues(args: argparse.Namespace, default: bool = True) -> bool:
        raw = getattr(args, "formatting_cues", None)
        if raw is None:
            return default
        return bool(raw)

    @staticmethod
    def _normalize_language_override(raw: Optional[str]) -> Optional[str]:
        if raw is None:
            return None
        cleaned = str(raw).strip()
        if not cleaned:
            return None
        if cleaned.lower() in {"auto", "unknown"}:
            return None
        return cleaned

    @staticmethod
    def _clamp_int(
        value: Optional[int],
        *,
        min_value: Optional[int] = None,
        max_value: Optional[int] = None,
    ) -> Optional[int]:
        if value is None:
            return None
        try:
            parsed = int(value)
        except (TypeError, ValueError):
            return None
        if min_value is not None:
            parsed = max(min_value, parsed)
        if max_value is not None:
            parsed = min(max_value, parsed)
        return parsed

    @staticmethod
    def _clamp_float(
        value: Optional[float],
        *,
        min_value: Optional[float] = None,
        max_value: Optional[float] = None,
    ) -> Optional[float]:
        if value is None:
            return None
        try:
            parsed = float(value)
        except (TypeError, ValueError):
            return None
        if min_value is not None:
            parsed = max(min_value, parsed)
        if max_value is not None:
            parsed = min(max_value, parsed)
        return parsed

    @staticmethod
    def _apply_no_parallel_env(args: argparse.Namespace) -> None:
        if getattr(args, "no_parallel", False):
            os.environ["CHAPTER_PARALLEL_COUNT"] = "1"
            os.environ["CHAPTER_PARALLEL_MAX"] = "1"
            os.environ["EDGE_ENABLE_PARALLEL"] = "false"

    def run(self, args: argparse.Namespace) -> int:
        """Entry point that orchestrates optional batch conversion."""
        if getattr(args, "command", None) == "clear_cache":
            return self._handle_clear_cache(args)

        verbose = self._resolve_verbose(args)
        hardware_profile = None
        try:
            from src.hardware_detector import HardwareDetector

            hardware_profile = HardwareDetector.detect()
            HardwareDetector.apply_optimizations(hardware_profile)
            if verbose:
                HardwareDetector.print_profile(hardware_profile, verbose=True)
        except Exception:
            hardware_profile = None

        self._apply_no_parallel_env(args)

        targets, batch_requested = self._resolve_batch_targets(args)
        if not targets:
            print("⚠️ No EPUB/PDF files found to convert.")
            return 1

        if len(targets) == 1 and not batch_requested:
            args.input_file = str(targets[0])
            return self._run_single_conversion(args, hardware_profile=hardware_profile)

        return self._run_batch(args, targets, hardware_profile=hardware_profile)

    def _resolve_batch_targets(self, args: argparse.Namespace) -> Tuple[List[Path], bool]:
        """Resolve positional + batch inputs into a deduplicated ordered list of books."""
        requested_batch = any(
            bool(getattr(args, attr, None))
            for attr in ("extra_inputs", "batch_inputs", "batch_manifest")
        )
        sources: List[str] = []
        positional: List[str] = []
        primary = getattr(args, "input_file", None)
        if primary:
            positional.append(str(primary))
        positional.extend(getattr(args, "extra_inputs", None) or [])
        sources.extend(positional)

        batch_inputs = getattr(args, "batch_inputs", None) or []
        sources.extend(batch_inputs)
        sources.extend(self._read_batch_manifest(getattr(args, "batch_manifest", None)))

        targets: List[Path] = []
        seen: Set[str] = set()
        for raw in sources:
            for expanded in self._expand_batch_source(raw):
                for file_path in self._flatten_source_to_files(expanded):
                    key = self._canonical_path_key(file_path)
                    if key in seen:
                        continue
                    seen.add(key)
                    targets.append(file_path)
        return targets, requested_batch

    def _expand_batch_source(self, raw: str) -> List[Path]:
        """Expand globs/user paths into concrete Path objects."""
        pattern = os.path.expanduser(raw)
        matches = [Path(match) for match in glob.glob(pattern)]
        if matches:
            return matches
        return [Path(pattern)]

    def _flatten_source_to_files(self, path: Path) -> List[Path]:
        """Return a list of valid input files from a file or directory."""
        resolved = path.expanduser()
        try:
            exists = resolved.exists()
        except OSError:
            exists = False

        if not exists:
            print(self.localization.t("file_not_found", path=resolved))
            return []

        if resolved.is_file():
            if resolved.suffix.lower() in self.SUPPORTED_INPUT_SUFFIXES:
                return [resolved]
            print(f"⚠️ Skipping unsupported file: {resolved.name}")
            return []

        if resolved.is_dir():
            files = [
                candidate
                for candidate in sorted(resolved.rglob("*"))
                if candidate.is_file() and candidate.suffix.lower() in self.SUPPORTED_INPUT_SUFFIXES
            ]
            if not files:
                print(f"⚠️ No EPUB/PDF files found in {resolved}")
            return files

        print(f"⚠️ Invalid path: {resolved}")

        return []

    @staticmethod
    def _canonical_path_key(path: Path) -> str:
        try:
            return str(path.resolve())
        except OSError:
            return str(path)

    def _run_batch(
        self,
        args: argparse.Namespace,
        targets: List[Path],
        *,
        hardware_profile=None,
    ) -> int:
        """Execute sequential conversions (or verify/fix) for multiple books."""
        total = len(targets)
        stop_on_error = bool(getattr(args, "batch_stop_on_error", False))
        successes = 0
        exit_code = 0
        failed_books: List[str] = []

        verify_mode = getattr(args, "verify_only", False)
        fix_mode = getattr(args, "fix_mode", False)

        for index, target in enumerate(targets, start=1):
            self._print_batch_header(target, index, total)
            single_args = copy.deepcopy(args)
            single_args.input_file = str(target)
            single_args.extra_inputs = []
            single_args.batch_inputs = []
            single_args.batch_manifest = None
            result = self._run_single_conversion(single_args, hardware_profile=hardware_profile)
            if result == 0:
                successes += 1
            else:
                exit_code = exit_code or result or 1
                failed_books.append(target.name)
                if stop_on_error:
                    print("🛑 Processing interrupted after failure.")
                    break

        if verify_mode:
            label = "verified clean"
        elif fix_mode:
            label = "fixed successfully"
        else:
            label = "succeeded"
        print(f"\n📚 Batch complete: {successes}/{total} book(s) {label}.")
        if failed_books:
            print("   Failed books:")
            for failed in failed_books:
                print(f"   - {failed}")
        return exit_code

    @staticmethod
    def _read_batch_manifest(manifest: Optional[str]) -> List[str]:
        if not manifest:
            return []
        manifest_path = Path(manifest).expanduser()
        if not manifest_path.exists():
            print(f"⚠️ List file not found: {manifest_path}")
            return []
        entries: List[str] = []
        try:
            with manifest_path.open("r", encoding="utf-8") as handle:
                for line in handle:
                    stripped = line.strip()
                    if not stripped or stripped.startswith("#"):
                        continue
                    entries.append(stripped)
        except OSError as exc:
            print(f"⚠️ Failed to read batch list ({manifest_path}): {exc}")
        return entries

    @staticmethod
    def _print_batch_header(target: Path, index: int, total: int) -> None:
        divider = "=" * 60
        print(f"\n{divider}")
        print(f"📘 Book {index}/{total}: {target.name}")
        print(f"{divider}")

    def _run_single_conversion(
        self,
        args: argparse.Namespace,
        *,
        hardware_profile=None,
    ) -> int:
        """Main application entry point"""
        conversion_start = time.time()
        try:
            if hardware_profile is None:
                from src.hardware_detector import HardwareDetector

                hardware_profile = HardwareDetector.detect()
                HardwareDetector.apply_optimizations(hardware_profile)
                verbose = self._resolve_verbose(args)
                if verbose:
                    HardwareDetector.print_profile(hardware_profile, verbose=True)
            self._apply_no_parallel_env(args)
            self.converter.hardware_profile = hardware_profile

            # Validate input
            input_path = Path(getattr(args, "input_file", "")).expanduser()
            if not input_path.exists():
                print(self.localization.t("file_not_found", path=input_path))
                return 1
            suffix = input_path.suffix.lower()
            if suffix not in {".epub", ".pdf"}:
                friendly = suffix or "(no extension)"
                print(f"❌ Unsupported format: {friendly}. Please provide an .epub or .pdf file.")
                return 1

            # Load ebook — oversized chapters are auto-split at a threshold
            # computed from EDGE_CHUNK_CHARS × EDGE_MAX_CONCURRENCY × 2.
            reader = EbookReader(str(input_path))

            # Show structure only
            if args.show_structure:
                self._show_structure(
                    reader, filter_chapters=bool(getattr(args, "filter_chapters", False))
                )
                return 0

            # Prepare structured chapters for conversion
            structure_items = self._generate_structure_items(
                reader, filter_chapters=bool(getattr(args, "filter_chapters", False))
            )

            if getattr(args, "detect_language", False):
                verbose = self._resolve_verbose(args)
                self.language_profile = self._prepare_language_profile(
                    reader, structure_items, verbose=verbose, allow_prompt=False
                )
                self._update_metadata_display_language()
                return 0

            range_start = getattr(args, "from_chapter_to_end", None)
            range_span = getattr(args, "from_chapter_to_chapter", None)
            subset_requested = bool(range_start or range_span)
            if range_start and range_span:
                print("❌ Use apenas --from-chapter-to-end ou --from-chapter-to-chapter.")
                return 1
            if range_span:
                parsed = self._parse_range_selector(range_span)
                if not parsed:
                    print(
                        "❌ Invalid range. Use 'A..B' (e.g. 5.1..7.3) in "
                        "--from-chapter-to-chapter."
                    )
                    return 1
                structure_items, filtered = self._filter_structure_range(
                    structure_items, parsed[0], parsed[1]
                )
                if filtered and not structure_items:
                    return 1
            elif range_start:
                structure_items, filtered = self._filter_structure_range(
                    structure_items, range_start, None
                )
                if filtered and not structure_items:
                    return 1

            selectors: List[str] = []
            selectors.extend(self._expand_selector_args(getattr(args, "chapters", []) or []))
            selectors.extend(self._expand_selector_args(getattr(args, "sections", []) or []))
            if selectors:
                subset_requested = True

            structure_items, filtered = self._filter_structure_selection(
                structure_items, selectors if selectors else None
            )
            if filtered and not structure_items:
                return 1

            # **NEW**: Use CacheManager for better cache handling
            from src.cache_manager import CacheManager

            cache_manager = CacheManager(cache_dir=self.cache_root)

            # Lazy GC of stale per-chapter ``text/*.txt`` cache files.
            # Each conversion drops ``<book>/text/*-pre-tts.txt`` and
            # ``-parsed.txt`` per chapter. Across many books / edition
            # swaps, that directory grows unboundedly. The sweep is
            # idempotent per process and only runs once per CLI start.
            try:
                cache_manager.cleanup_old_text_files()
            except Exception:
                pass

            if getattr(args, "clear_cache", False):
                input_path = (
                    Path(getattr(args, "input_file", ""))
                    if getattr(args, "input_file", None)
                    else None
                )
                if input_path:
                    display_name = reader.title or input_path.stem
                    output_base = Path(getattr(args, "output_dir", None) or OUTPUT_DIR)
                    sanitized_title = FileManager.sanitize_filename(display_name)

                    if selectors:
                        # Chapter-specific: clear only selected chapters' cache and output
                        safe_book_title = FileManager.sanitize_filename(
                            reader.title or input_path.stem
                        )
                        cache_book_dir = self.cache_root / safe_book_title

                        print()
                        print(
                            f"🗑️  Removing cache for {len(structure_items)} chapter(s) "
                            f"of: {display_name}"
                        )
                        print()

                        cleared_text = 0
                        cleared_audio = 0
                        for chapter in structure_items:
                            chapter_label = str(chapter.index)
                            # Remove pre-tts and parsed text files from the text cache dir
                            text_dir = cache_book_dir / "text"
                            if text_dir.exists():
                                for pattern in (
                                    f"{chapter_label} - *-pre-tts.txt",
                                    f"{chapter_label} - *-parsed.txt",
                                ):
                                    for f in text_dir.glob(pattern):
                                        f.unlink(missing_ok=True)
                                        cleared_text += 1
                            # Remove cached MP3/WAV from the cache (temp) dir
                            if cache_book_dir.exists():
                                for pattern in (
                                    f"{chapter_label} - *.mp3",
                                    f"{chapter_label} - *.wav",
                                ):
                                    for f in cache_book_dir.glob(pattern):
                                        f.unlink(missing_ok=True)
                                        cleared_audio += 1
                            # Remove EdgeTTS stream chunks (prevents chunk resume)
                            label_safe = chapter_label.replace(".", "_")
                            stream_dir = (
                                cache_book_dir / "streams" / "cli" / f"chapter_{label_safe}"
                            )
                            if stream_dir.exists():
                                shutil.rmtree(stream_dir, ignore_errors=True)
                                cleared_audio += 1
                            # Remove final output MP3 from all engine output dirs.
                            # Also drop the per-output ._resume_state.json so the
                            # next invocation re-scans instead of trusting a stale
                            # listing hash that still includes the cleared chapter.
                            if output_base.exists():
                                for out_dir in output_base.iterdir():
                                    if out_dir.is_dir() and (
                                        out_dir.name == sanitized_title
                                        or out_dir.name.startswith(f"{sanitized_title}_")
                                    ):
                                        for f in out_dir.glob(f"{chapter_label} - *.mp3"):
                                            f.unlink(missing_ok=True)
                                            cleared_audio += 1
                                        with contextlib.suppress(OSError):
                                            (out_dir / "._resume_state.json").unlink(
                                                missing_ok=True
                                            )

                        if cleared_text > 0:
                            print(f"   ✅ Text cache cleared ({cleared_text} file(s))")
                        if cleared_audio > 0:
                            print(f"   ✅ Audio cache cleared ({cleared_audio} file(s))")
                        if cleared_text == 0 and cleared_audio == 0:
                            print("   ℹ️  No cached files found for selected chapters")

                        print()
                        print("🔄 Starting conversion...")
                        print()
                    else:
                        # Clear entire book cache and output
                        print()
                        print(f"🗑️  Removing cache and output for: {display_name}")
                        print()

                        cleared_cache = cache_manager.clear_cache(input_path, title=reader.title)
                        if cleared_cache:
                            print("   ✅ Cache removed")

                        # Look for all directories that start with the book title
                        # (ex: "Book_edge", "Book_piper", "Book_coqui")
                        removed_count = 0
                        if output_base.exists():
                            for output_dir in output_base.iterdir():
                                if output_dir.is_dir() and (
                                    output_dir.name == sanitized_title
                                    or output_dir.name.startswith(f"{sanitized_title}_")
                                ):
                                    try:
                                        shutil.rmtree(output_dir, ignore_errors=True)
                                        removed_count += 1
                                    except Exception as e:
                                        print(f"   ⚠️  Error removing {output_dir.name}: {e}")

                        if removed_count > 0:
                            print(f"   ✅ Output removed ({removed_count} director(ies))")
                        else:
                            print("   ℹ️  No output directories found")

                        cache_manager.clear_checkpoint(input_path)

                        print()
                        print(f"✅ Cleanup complete for: {display_name}")
                        print("🔄 Starting conversion...")
                        print()
                else:
                    # No file specified — confirm and remove everything
                    return self._handle_clear_cache()

            cache_dir = self._resolve_cache_dir(reader)
            cache_dir.mkdir(parents=True, exist_ok=True)
            setattr(args, "cache_dir", cache_dir)

            # Set temp directory to .cache/{book name}
            book_name = Path(args.input_file).stem
            temp_dir = self.cache_root / book_name

            if getattr(args, "no_cache", False):
                # Completely clear the .cache directory
                if self.cache_root.exists():
                    shutil.rmtree(self.cache_root)
                self.cache_root.mkdir(exist_ok=True)
                print("🗑️ .cache directory cleared due to --no-cache")

            # Ensure the temp directory is inside .cache
            book_name = Path(args.input_file).stem
            temp_dir = self.cache_root / book_name
            temp_dir.mkdir(parents=True, exist_ok=True)

            # Auto-cache: conversion resumes automatically if .txt files exist
            # No longer need to ask the user — system detects automatically

            self._interactive_mode = bool(getattr(args, "menu", False))

            # For verify/fix mode: skip expensive language detection and go straight
            # to config setup — book title is all we need to locate the output dir.
            if getattr(args, "verify_only", False) or getattr(args, "fix_mode", False):
                config = self._get_conversion_config(args, reader)
                if not config:
                    return 1
                if getattr(args, "verify_only", False):
                    return self._run_verify_only(input_path, config, interactive=True)
                return self._run_fix_mode(input_path, config)

            # Prepare language profile AFTER displaying initial metadata
            verbose = self._resolve_verbose(args)
            language_override = self._normalize_language_override(getattr(args, "language", None))
            if language_override:
                self.language_profile = LanguageProfile(
                    primary=language_override,
                    languages=[language_override],
                    predictions=[],
                    analysed_chars=0,
                )
            else:
                self.language_profile = self._prepare_language_profile(
                    reader, structure_items, verbose=verbose
                )

            # Update display with language detection results
            self._update_metadata_display_language()

            # Configure conversion (only once)
            config = self._get_conversion_config(args, reader)
            if not config:
                return 1
            config.verbose = self._resolve_verbose(args)
            self._announce_footnote_mode(config)

            # Pre-flight: confirm language detection on an independent
            # sample and surface engine/voice/fallback choices before
            # synthesis starts. Aborts on language mismatch unless the
            # user forced --language. (Carl regression guard.)
            if not self._preflight_language_and_config_check(reader, structure_items, config, args):
                return 1

            if subset_requested:
                selected_indices = [str(item.index) for item in structure_items]
                if selected_indices:
                    config.extra["selected_indices"] = ",".join(selected_indices)
                config.extra["partial_selection"] = "1"

            # Configure temp directory using the existing method with `config`
            temp_dir = self.converter._setup_temp_directory(config)

            print(f"📁 Cache: {temp_dir}")
            if not getattr(args, "clear_cache", False):
                if temp_dir.exists() and (temp_dir / "text").exists():
                    txt_files = list((temp_dir / "text").glob("*_tts_input.txt"))
                    if txt_files:
                        print(f"♻️ Cache detected: {len(txt_files)} chapters already processed")
                        print("   Already converted chapters will be skipped automatically")

            structure_items = self._apply_text_transforms(structure_items, config, reader)
            self._apply_structure_to_reader(reader, structure_items)

            if getattr(args, "engine_chain_fallback", False):
                os.environ["ENGINE_CHAIN_FALLBACK"] = "1"
                try:
                    import src.converter as _cv

                    _cv.ENGINE_CHAIN_FALLBACK = True
                except Exception:
                    pass

            fallback_pref = _resolve_cli_fallback_engine(
                getattr(args, "fallback_engine", "auto"),
                os.getenv("FALLBACK_ENGINE_OVERRIDE"),
            )
            if fallback_pref:
                self.converter._cli_fallback_engine = fallback_pref

            if getattr(args, "prewarm_kokoro", False):
                _prewarm_kokoro_pipeline(getattr(config, "primary_language", None))
            if getattr(args, "prewarm_edge", False):
                _prewarm_edge_pipeline(getattr(config, "voice", None))
            if getattr(args, "prewarm_piper", False):
                _prewarm_piper_pipeline(getattr(config, "primary_language", None))

            # Reuse: skip synthesis entirely when the audiobook is
            # already on disk (≥90% of chapters present). Saves the
            # user a 20-minute Edge run on the second invocation.
            existing_output = self._detect_reusable_existing_output(
                reader, structure_items, config, args
            )
            if existing_output is not None:
                mp3s_now = sum(
                    1 for p in existing_output.glob("*.mp3") if p.is_file() and p.stat().st_size > 0
                )
                print()
                print(
                    f"♻️  Reusing existing output: {mp3s_now} MP3(s) found in "
                    f"{existing_output}. Skipping conversion."
                )
                print("   Use --clear-cache to force re-synthesis or --force " "to override.")
                # Re-apply ID3 metadata + cover art on reuse path. The
                # post-synthesis silence injection step
                # (`inject_silence_at_offset`) uses ffmpeg concat-copy,
                # which strips embedded JPEG cover art and ID3 tags.
                # Without this re-stamp, reuse runs leave the user with
                # cover-less MP3s on the iPhone audiobook player.
                try:
                    cover_art = self.converter._extract_cover_art(reader)
                    book_title_for_tags = config.book_title or reader.title or existing_output.name
                    book_author_for_tags = getattr(reader, "author", "") or None
                    self.converter._apply_final_id3_tags(
                        sorted(existing_output.glob("*.mp3")),
                        default_album=book_title_for_tags,
                        artist=book_author_for_tags,
                        cover_art=cover_art,
                    )
                    if cover_art:
                        print("   🖼️  Re-applied ID3 tags + cover art")
                except Exception as _exc:
                    print(f"   ⚠️ ID3 re-stamp on reuse failed: {_exc}")
                result = ConversionResult(
                    success=True,
                    converted_chapters=mp3s_now,
                    total_chapters=len(structure_items),
                    output_files=[str(p) for p in sorted(existing_output.glob("*.mp3"))],
                    errors=[],
                )
            else:
                # Drop stale cache MP3s from prior editions before any
                # chapter loop reuses them.
                self._maybe_clean_obsolete_cache(reader, structure_items, config)

                # Convert
                result = asyncio.run(self.converter.convert(reader, config))

            elapsed = time.time() - conversion_start
            print(f"⏱️ Total conversion time: {self._format_hms(elapsed)}")

            # Log persistent conversion session record
            try:
                import json as _json
                from datetime import datetime, timezone

                from src.session_logger import log_session

                _converted = (
                    result.converted_chapters if isinstance(result, ConversionResult) else 0
                )
                _total = (
                    result.total_chapters
                    if isinstance(result, ConversionResult)
                    else len(structure_items)
                )
                _failed = _total - _converted
                _success = (
                    result.success
                    if isinstance(result, ConversionResult)
                    else (isinstance(result, int) and result == 0)
                )
                _outcome = "success" if _success else ("partial" if _converted > 0 else "failed")

                # Read per-chapter details from runtime metrics file
                _chapter_details: list = []
                _output_dir = getattr(config, "output_dir", None)
                if _output_dir:
                    _metrics_path = Path(_output_dir) / "_runtime_metrics.jsonl"
                    if _metrics_path.exists():
                        try:
                            with open(_metrics_path, encoding="utf-8") as _mf:
                                for _line in _mf:
                                    _line = _line.strip()
                                    if not _line:
                                        continue
                                    _ev = _json.loads(_line)
                                    if _ev.get("event") == "chapter_complete":
                                        _detail = {
                                            "index": _ev.get("chapter"),
                                            "engine": _ev.get("engine", ""),
                                            "chars": _ev.get("chars"),
                                            "elapsedSeconds": round(
                                                float(_ev.get("elapsed_s") or 0), 1
                                            ),
                                            "status": "completed"
                                            if _ev.get("success")
                                            else "failed",
                                            "retryCount": max(0, int(_ev.get("attempt", 1)) - 1),
                                        }
                                        if _ev.get("error"):
                                            _detail["error"] = _ev["error"]
                                        _chapter_details.append(_detail)
                        except Exception:
                            pass

                log_session(
                    book_title=reader.title or Path(args.input_file).stem,
                    book_author=getattr(reader, "author", "") or "",
                    language=getattr(self.language_profile, "primary", "")
                    if self.language_profile
                    else "",
                    engine=getattr(config, "engine", ""),
                    voice=getattr(config, "voice", ""),
                    chapters_total=_total,
                    chapters_converted=_converted,
                    chapters_failed=_failed,
                    duration_seconds=elapsed,
                    outcome=_outcome,
                    output_dir=str(_output_dir or ""),
                    started_at=datetime.fromtimestamp(
                        conversion_start, tz=timezone.utc
                    ).isoformat(),
                    chapter_details=_chapter_details or None,
                )
            except Exception:
                pass  # Never let logging break a conversion
            if getattr(args, "show_metrics_summary", False):
                self._print_metrics_summary(temp_dir)
            if getattr(args, "show_metrics_dashboard", False):
                self._print_metrics_dashboard_path(temp_dir)
            if getattr(args, "open_metrics_dashboard", False):
                self._open_metrics_dashboard(temp_dir)
            if getattr(args, "export_metrics_bundle", False):
                self._export_metrics_bundle(temp_dir)

            # iPhone export (opt-in): copy the finished audiobook into
            # the MP3AudioBookPlayer iCloud Drive container so it
            # syncs to the device. Done last so a failed export never
            # affects the conversion exit code — the audio is on disk
            # regardless. macOS-only.
            cli_flag = getattr(args, "export_to_iphone", None)
            if cli_flag is None:
                from src.iphone_export import parse_env_flag

                want_export = parse_env_flag(os.environ.get("EXPORT_TO_IPHONE"))
            else:
                want_export = bool(cli_flag)
            if want_export and isinstance(result, ConversionResult) and result.success:
                from src.iphone_export import export_book_to_iphone, is_macos

                if not is_macos():
                    print(
                        "⚠️  --export-to-iphone is macOS-only (iCloud Drive "
                        "container path); skipping export."
                    )
                else:
                    # `_output_dir` is the *root* output directory (e.g.
                    # `output/`); MP3s live in `<root>/<sanitised title>/`.
                    # Use the same sanitiser the converter used so we
                    # land on the correct sub-folder instead of an empty
                    # parent (the v0.3.20 fix).
                    book_title_for_export = (
                        getattr(reader, "title", "") or Path(args.input_file).stem
                    )
                    output_dir_for_export = None
                    if _output_dir:
                        safe_book_dir = FileManager.sanitize_filename(
                            book_title_for_export or "default"
                        )
                        output_dir_for_export = Path(_output_dir) / safe_book_dir
                    if output_dir_for_export:
                        ok, error = export_book_to_iphone(
                            output_dir_for_export,
                            book_title=book_title_for_export,
                            log=print,
                        )
                        if not ok:
                            print(f"⚠️  iPhone export skipped: {error}")

            if isinstance(result, ConversionResult):
                return 0 if result.success else 1
            if isinstance(result, int):
                return result
            if isinstance(result, bool):
                return 0 if result else 1
            return 0

        except Exception as e:
            traceback.print_exc()
            print(self.localization.t("unexpected_error", error=e))
            return 1

    @staticmethod
    def _format_hms(seconds: float) -> str:
        total = max(0, int(seconds or 0))
        hours, rem = divmod(total, 3600)
        minutes, secs = divmod(rem, 60)
        parts: list[str] = []
        if hours:
            parts.append(f"{hours:02d}h")
        if minutes or hours:
            parts.append(f"{minutes:02d}m")
        parts.append(f"{secs:02d}s")
        return " ".join(parts)

    def _run_verify_only(
        self, input_path: Path, config: ConversionConfig, interactive: bool = False
    ) -> int:
        """Validate existing output/cache against the source EPUB without synthesizing audio."""
        safe_name = self.converter.file_manager.sanitize_filename(config.book_title or "default")
        output_dir = Path(config.output_dir) / safe_name
        cache_dir = Path(config.cache_dir) if getattr(config, "cache_dir", None) else None

        if not output_dir.exists():
            print(f"❌ Output not found for validation: {output_dir}")
            print(f"   Expected output directory derived from book title: {output_dir}")
            print("   Run a conversion first, or pass --output-dir if you used a custom path.")
            return 1

        print("🔍 Verify mode: no new audio will be generated.")
        print(f"📁 Output: {output_dir}")
        if cache_dir:
            print(f"📁 Cache: {cache_dir}")
        try:
            from validate_conversion import validate_book

            _, issues = validate_book(input_path, output_dir=output_dir, cache_dir=cache_dir)
        except Exception as exc:
            print(f"❌ Validation failed: {exc}")
            return 1

        if issues:
            print(f"❌ Verification failed: {len(issues)} issue(s) found.")
            if interactive:
                print("\nIssues:")
                for issue in issues:
                    print(f"  • {issue}")
                # Default Y: most users want to fix the issues they just
                # saw — the legacy [y/N] forced an extra keypress for the
                # common case and the user reported that pressing `y`
                # didn't register on their terminal. Empty input now
                # confirms; only an explicit `n`/`no` cancels.
                # Strip Windows-style \r and any trailing whitespace
                # so a CR-only line (common over SSH) still confirms.
                try:
                    raw = input("\n🔧 Do you want to fix the issues now? [Y/n] ")
                except (EOFError, KeyboardInterrupt):
                    raw = ""
                answer = (raw or "").strip().rstrip("\r").lower()
                if answer in ("", "y", "yes", "s", "sim"):
                    return self._run_fix_mode(input_path, config)
            return 1
        print("✅ Verification completed with no issues.")
        return 0

    def _run_fix_mode(self, input_path: Path, config: ConversionConfig) -> int:
        """Verify then fix: rename bad files, then reconvert problematic chapters until 100% intact."""
        import asyncio
        import os

        safe_name = self.converter.file_manager.sanitize_filename(config.book_title or "default")
        output_dir = Path(config.output_dir) / safe_name
        cache_dir = Path(config.cache_dir) if getattr(config, "cache_dir", None) else None

        if not output_dir.exists():
            print(f"❌ Output not found: {output_dir}")
            print(f"   Expected output directory derived from book title: {output_dir}")
            print("   Run a conversion first, or pass --output-dir if you used a custom path.")
            return 1

        print("🔧 Fix mode: validating and fixing the conversion...")
        print(f"📁 Output: {output_dir}")
        if cache_dir:
            print(f"📁 Cache: {cache_dir}")

        fix_summary: list[str] = []

        # Step 1: Fix file naming issues (HTML in names, illegal characters)
        try:
            from validate_conversion import fix_output_filenames

            renamed = fix_output_filenames(output_dir, cache_dir=cache_dir)
            if renamed:
                print(f"\n✏️  Fixed {len(renamed)} filename(s) with HTML/invalid characters.")
                fix_summary.append(f"Renamed {len(renamed)} file(s) with bad names")
        except Exception as exc:
            print(f"⚠️  Filename fix skipped: {exc}")

        # Step 2: Validate
        try:
            from validate_conversion import validate_book

            _, issues = validate_book(input_path, output_dir=output_dir, cache_dir=cache_dir)
        except Exception as exc:
            print(f"❌ Validation failed: {exc}")
            return 1

        if not issues:
            if fix_summary:
                print("\n✅ Fix completed:")
                for item in fix_summary:
                    print(f"   • {item}")
            else:
                print("✅ No issues found — book is already 100% intact.")
            return 0

        issues_before = len(issues)
        print(f"\n🔧 {issues_before} issue(s) found. Starting reconversion loop...")

        # Step 3: Reconvert bad chapters until clean
        fix_config = config
        fix_config.auto_fix_output = False  # prevent re-entry
        fix_config.auto_validate_output = False
        self.converter._active_config = fix_config

        try:
            max_retries = int(os.getenv("MAX_VALIDATION_RETRIES", "8"))
            success = asyncio.run(
                self.converter._auto_validate_and_retry_async(
                    output_dir, input_path, cache_dir, max_retries=max_retries
                )
            )
        except Exception as exc:
            print(f"❌ Fix failed: {exc}")
            import traceback

            traceback.print_exc()
            return 1

        print("\n" + "=" * 60)
        print("🔧 FIX SUMMARY")
        print("=" * 60)
        for item in fix_summary:
            print(f"  • {item}")
        if success:
            print(f"  • Resolved {issues_before} validation issue(s) via reconversion")
            print("=" * 60)
            print("✅ Fix completed: book is 100% intact!")
            return 0
        else:
            print(f"  • Started with {issues_before} issue(s) — some may remain")
            print("=" * 60)
            print("⚠️  Fix completed with remaining issues. Run --verify to see details.")
            return 1

    @staticmethod
    def _print_metrics_summary(temp_dir: Optional[Path]) -> None:
        if not temp_dir:
            return
        summary_path = Path(temp_dir) / "metrics-summary.json"
        if not summary_path.exists():
            print("📊 Metrics summary: not found")
            return
        try:
            payload = json.loads(summary_path.read_text(encoding="utf-8"))
        except Exception as exc:
            print(f"⚠️ Metrics summary read failed: {exc}")
            return

        chapters = payload.get("chapters", {}) if isinstance(payload, dict) else {}
        total_events = payload.get("total_events", 0) if isinstance(payload, dict) else 0
        print("\n📊 Runtime metrics summary")
        print(f"   events: {total_events}")
        print(
            "   chapters: "
            f"{chapters.get('successful', 0)}/{chapters.get('total', 0)} ok, "
            f"{chapters.get('failed', 0)} failed"
        )
        optimization = payload.get("optimization_metrics", {}) if isinstance(payload, dict) else {}
        if isinstance(optimization, dict) and optimization:
            print(
                "   optimization: "
                f"prefetch_hit_rate={float(optimization.get('prefetch_hit_rate', 0.0) or 0.0) * 100:.1f}% | "
                f"ab_explorations={int(optimization.get('ab_explorations', 0) or 0)} | "
                f"budget_caps={int(optimization.get('budget_caps_applied', 0) or 0)} | "
                f"adaptive_restores={int(optimization.get('adaptive_state_restores', 0) or 0)}"
            )
        seg_summary_path = Path(temp_dir) / "segment-metrics-summary.json"
        if seg_summary_path.exists():
            try:
                seg_payload = json.loads(seg_summary_path.read_text(encoding="utf-8"))
                engines = seg_payload.get("engines", {}) if isinstance(seg_payload, dict) else {}
                if isinstance(engines, dict) and engines:
                    best_engine = None
                    best_cps = 0.0
                    for engine_name, row in engines.items():
                        if not isinstance(row, dict):
                            continue
                        avg = float(row.get("avg_chars_per_second", 0.0) or 0.0)
                        if avg > best_cps:
                            best_cps = avg
                            best_engine = str(engine_name)
                    if best_engine:
                        print(
                            f"   segments: best_engine={best_engine} avg_chars_per_second={best_cps:.1f}"
                        )
            except Exception:
                pass
        rec_path = Path(temp_dir) / "metrics-recommendations.txt"
        if rec_path.exists():
            try:
                rec_lines = rec_path.read_text(encoding="utf-8").splitlines()
                recommendation = next(
                    (
                        line.strip()
                        for line in rec_lines
                        if line.strip().startswith("- ") and line.strip()
                    ),
                    "",
                )
                if recommendation:
                    print(f"   recommendation: {recommendation[2:]}")
            except Exception:
                pass
        print(f"   file: {summary_path}")

    @staticmethod
    def _print_metrics_dashboard_path(temp_dir: Optional[Path]) -> None:
        if not temp_dir:
            return
        dashboard_path = Path(temp_dir) / "metrics-dashboard.html"
        if dashboard_path.exists():
            print(f"📈 Metrics dashboard: {dashboard_path}")
        else:
            print("📈 Metrics dashboard: not found")

    @staticmethod
    def _open_metrics_dashboard(temp_dir: Optional[Path]) -> None:
        if not temp_dir:
            return
        dashboard_path = Path(temp_dir) / "metrics-dashboard.html"
        if not dashboard_path.exists():
            print("📈 Metrics dashboard: not found")
            return
        try:
            subprocess.Popen(
                ["open", str(dashboard_path)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            print(f"📈 Opened metrics dashboard: {dashboard_path}")
        except Exception as exc:
            print(f"⚠️ Could not open metrics dashboard: {exc}")
            print(f"   file: {dashboard_path}")

    @staticmethod
    def _export_metrics_bundle(temp_dir: Optional[Path]) -> None:
        if not temp_dir:
            return
        base = Path(temp_dir)
        candidates = [
            "metrics-summary.json",
            "metrics-chapter-engine.csv",
            "metrics-dashboard.html",
            "segment-metrics-summary.json",
            "segment-metrics-engine-chapter.csv",
            "segment-metrics-dashboard.html",
            "metrics-recommendations.txt",
            "_runtime_metrics.jsonl",
            "_segment_metrics.jsonl",
            "_failure_checkpoint.json",
            "_adaptive_state_checkpoint.json",
        ]
        existing = [base / name for name in candidates if (base / name).exists()]
        if not existing:
            print("📦 Metrics bundle: no metric files found")
            return
        bundle_path = base / f"metrics-bundle-{int(time.time())}.zip"
        try:
            with zipfile.ZipFile(bundle_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
                for path in existing:
                    zf.write(path, arcname=path.name)
            print(f"📦 Metrics bundle: {bundle_path}")
        except Exception as exc:
            print(f"⚠️ Could not export metrics bundle: {exc}")

    def _generate_structure_items(
        self, reader: EbookReader, *, filter_chapters: bool = True
    ) -> List[ChapterStructureItem]:
        """Prepare structured information for chapters shared across features"""

        try:
            chapters = list(reader.get_chapters())
        except TypeError:
            return []

        if not chapters:
            return []

        book_title = reader.title
        book_author = reader.author
        toc_map = self._build_toc_map(reader)
        toc_outline_map = self._build_toc_outline_map(reader)
        toc_outline_enabled = bool(toc_outline_map)

        structure_items: List[ChapterStructureItem] = []
        division_counters: Dict[int, int] = {}
        fallback_division = 0
        fallback_counter = 0
        fallback_label: Optional[str] = None
        last_toc_split_group: Optional[str] = None

        division_remap: Dict[int, int] = {}
        next_division_index = 1

        def remap_division(original: Optional[int]) -> int:
            nonlocal next_division_index
            if original is None or original <= 0:
                value = next_division_index
                next_division_index += 1
                return value
            if original not in division_remap:
                division_remap[original] = next_division_index
                next_division_index += 1
            return division_remap[original]

        def allocate_division() -> int:
            nonlocal next_division_index
            value = next_division_index
            next_division_index += 1
            return value

        for i, chapter in enumerate(chapters):
            speak_heading = True
            if filter_chapters and self._should_skip_chapter(chapters, i, toc_map):
                continue

            href_key = self._normalize_href(str(getattr(chapter, "source_path", "")))
            split_group_key = self._split_group_key(href_key)
            toc_outline_entries = self._resolve_toc_outline_entries(href_key, toc_outline_map)
            if toc_outline_entries:
                generated_items = self._create_items_from_toc_outline_entries(
                    chapter,
                    toc_outline_entries,
                    book_title,
                    book_author,
                )
                if generated_items:
                    structure_items.extend(generated_items)
                    last_toc_split_group = split_group_key
                    last_item = generated_items[-1]
                    try:
                        division_index = int(str(last_item.index).split(".", 1)[0])
                    except (ValueError, TypeError):
                        division_index = fallback_division
                    fallback_division = division_index
                    fallback_counter = division_counters.get(division_index, fallback_counter)
                    fallback_label = last_item.main_title
                    continue
                if toc_outline_enabled:
                    continue
            elif (
                split_group_key
                and last_toc_split_group
                and split_group_key == last_toc_split_group
                and structure_items
            ):
                # Some EPUBs have extra split files with no TOC entry.
                # To keep numbering equal to TOC, append this content to the
                # last TOC chapter in the same split group instead of creating
                # a synthetic chapter label.
                extra_text = str(getattr(chapter, "text", "") or "").strip()
                if extra_text:
                    last_item = structure_items[-1]
                    base_text = (
                        str(last_item.text_override)
                        if last_item.text_override is not None
                        else str(getattr(last_item.chapter, "text", "") or "")
                    ).strip()
                    last_item.text_override = (
                        f"{base_text}\n\n{extra_text}" if base_text else extra_text
                    )
                continue
            elif toc_outline_enabled:
                # When TOC exists, keep output strictly aligned with TOC labels
                # — BUT preserve chapters with substantive text (dedicatórias,
                # epigraphs, etc.) even if they lack a TOC entry.
                orphan_text = str(getattr(chapter, "text", "") or "").strip()
                if len(orphan_text) <= 12:
                    continue
                # Fall through to create a synthetic item for this orphan chapter

            toc_entries = self._resolve_toc_entries(href_key, toc_map)
            last_toc_split_group = None

            if toc_entries:
                generated_items = self._create_items_from_toc_entries(
                    chapter, toc_entries, book_title, division_counters, remap_division, book_author
                )

                if generated_items:
                    structure_items.extend(generated_items)

                    last_item = generated_items[-1]
                    try:
                        division_index = int(str(last_item.index).split(".", 1)[0])
                    except (ValueError, TypeError):
                        division_index = fallback_division

                    fallback_division = division_index
                    fallback_counter = division_counters.get(division_index, fallback_counter)
                    fallback_label = last_item.main_title
                    continue

            toc_entry = self._select_toc_entry(toc_entries)

            clean_name = self._clean_chapter_name(str(getattr(chapter, "name", "")))

            try:
                main_name, sub_name, first_words = self._format_chapter_display(
                    chapter, chapters, i, book_title, book_author
                )[1:]
            except Exception:
                text = str(getattr(chapter, "text", ""))
                main_name = self._clean_chapter_name(
                    str(getattr(chapter, "name", f"Chapter {i + 1}"))
                )
                sub_name = None
                first_words = self._extract_first_words(text, self.PREVIEW_WORD_LIMIT)

            if toc_entry:
                division_index, division_label, child_title = toc_entry
                division_index = remap_division(division_index)
                division_counters.setdefault(division_index, 0)

                if child_title:
                    division_counters[division_index] += 1
                    index = f"{division_index}.{division_counters[division_index]}"
                    main_name = division_label
                    sub_name = child_title
                else:
                    division_counters[division_index] = 0
                    index = f"{division_index}.0"
                    main_name = division_label
                    sub_name = None

                fallback_division = division_index
                fallback_counter = division_counters[division_index]
                fallback_label = division_label

                preview = self._extract_smart_first_words(
                    str(getattr(chapter, "text", "")),
                    clean_name,
                    division_label,
                    max_words=self.PREVIEW_WORD_LIMIT,
                )
                if preview:
                    first_words = preview
            else:
                is_division = self._is_division_candidate(chapter, chapters, i)
                if fallback_division == 0 or is_division:
                    fallback_division = allocate_division()
                    division_counters[fallback_division] = 0
                    fallback_counter = 0
                    index = f"{fallback_division}.0"
                    fallback_label = main_name or fallback_label
                    main_name = fallback_label or main_name
                    sub_name = None
                    speak_heading = True
                else:
                    fallback_counter += 1
                    division_counters[fallback_division] = fallback_counter
                    index = f"{fallback_division}.{fallback_counter}"
                    if fallback_label:
                        if main_name and main_name.lower() != fallback_label.lower():
                            sub_name = sub_name or main_name
                        main_name = fallback_label
                    speak_heading = False

            main_name, sub_name, first_words = self._sanitize_display_values(
                main_name, sub_name, first_words, book_title, book_author
            )

            first_words = self._remove_duplicate_prefix(first_words, main_name, sub_name)

            display_name = index
            ordered_values = [value for value in (main_name, sub_name, first_words) if value]

            for idx_value, value in enumerate(ordered_values):
                separator = " - "
                if idx_value == len(ordered_values) - 1 and value[:1].islower():
                    separator = " "
                if value[:1] in {",", ";", ":", ".", "!", "?"}:
                    separator = " "

                if separator == " ":
                    display_name = f"{display_name} {value}"
                else:
                    display_name = f"{display_name}{separator}{value}"

            structure_items.append(
                ChapterStructureItem(
                    chapter=chapter,
                    index=index,
                    main_title=main_name,
                    sub_title=sub_name,
                    preview=first_words,
                    display_name=display_name,
                    speak_heading=speak_heading,
                )
            )

        # Store expected chapter count from TOC for later validation
        if hasattr(reader, "_toc_expected_chapters"):
            delattr(reader, "_toc_expected_chapters")
        expected_count = self._count_toc_chapters(reader)
        if expected_count > 0:
            reader._toc_expected_chapters = expected_count

        # Assign unique sub-indices to split chapters that share the same index.
        # When a large chapter is split at paragraph boundaries or CSS markers, all
        # resulting parts initially receive the same TOC-derived index (e.g. "4.3").
        # Rename them to "4.3.1", "4.3.2", etc. so each part has a unique,
        # addressable index for file naming and resume logic.
        index_counts: Dict[str, int] = {}
        for item in structure_items:
            index_counts[item.index] = index_counts.get(item.index, 0) + 1

        index_seen: Dict[str, int] = {}
        resolved: List[ChapterStructureItem] = []
        for item in structure_items:
            if index_counts[item.index] > 1:
                index_seen[item.index] = index_seen.get(item.index, 0) + 1
                section_num = str(index_seen[item.index])
                new_idx = f"{item.index}.{section_num}"
                # Include the section number as visible text (not just in the
                # numeric prefix) so it appears in filenames and show-structure.
                new_sub = f"{item.sub_title} - {section_num}" if item.sub_title else section_num
                # Rebuild display_name from components using the same separator
                # rules as the original builder: " - " between title parts,
                # space before a preview that starts with lowercase or punctuation.
                parts = [v for v in (item.main_title, new_sub, item.preview) if v]
                new_display = new_idx
                for i, val in enumerate(parts):
                    if (i == len(parts) - 1) and (val[:1].islower() or val[:1] in ",;:.!?"):
                        new_display = f"{new_display} {val}"
                    else:
                        new_display = f"{new_display} - {val}"
                item = _dc_replace(item, index=new_idx, sub_title=new_sub, display_name=new_display)
            resolved.append(item)

        return resolved

    def _count_toc_chapters(self, reader: EbookReader) -> int:
        """Count expected chapters from TOC (leaf entries with href)."""
        get_toc = getattr(reader, "get_toc", None)
        if not callable(get_toc):
            return 0

        try:
            toc_entries = list(get_toc() or [])
        except Exception:
            return 0

        count = 0

        def walk(entries):
            nonlocal count
            for entry in entries:
                children = list(getattr(entry, "children", []) or [])
                if getattr(entry, "href", "") and not children:
                    count += 1
                if children:
                    walk(children)

        walk(toc_entries)
        return count

    def _build_toc_outline_map(self, reader: EbookReader) -> Dict[str, List[Dict[str, Any]]]:
        """Build href -> hierarchical TOC entries map with full numbering path."""
        mapping: Dict[str, List[Dict[str, Any]]] = {}
        get_toc = getattr(reader, "get_toc", None)
        if not callable(get_toc):
            return mapping

        try:
            toc_entries = list(get_toc() or [])
        except Exception:
            return mapping

        def register(href: str, payload: Dict[str, Any]) -> None:
            if not href:
                return
            keys = {href}
            name = Path(href).name
            if name:
                keys.add(name.lower())
            for key in keys:
                mapping.setdefault(key, []).append(payload)

        def walk(entries, path_indices: Tuple[int, ...], path_titles: Tuple[str, ...]) -> None:
            for position, entry in enumerate(entries, start=1):
                title = (getattr(entry, "title", "") or "").strip()
                href = self._normalize_href(str(getattr(entry, "href", "") or ""))
                current_indices = path_indices + (position,)
                current_titles = path_titles + ((title,) if title else tuple())

                payload: Dict[str, Any] = {
                    "path_indices": current_indices,
                    "path_titles": current_titles,
                    "title": title,
                    "level": len(current_indices),
                }
                if href:
                    register(href, payload)

                children = list(getattr(entry, "children", []) or [])
                if children:
                    walk(children, current_indices, current_titles)

        walk(toc_entries, tuple(), tuple())
        return mapping

    def _resolve_toc_outline_entries(
        self, href_key: str, outline_map: Dict[str, List[Dict[str, Any]]]
    ) -> Optional[List[Dict[str, Any]]]:
        if not href_key:
            return None

        candidates = []
        lowered = href_key.lower()
        candidates.append(lowered)
        if "/" in lowered:
            parts = lowered.split("/")
            for start in range(1, len(parts)):
                candidates.append("/".join(parts[start:]))
        candidates.append(Path(lowered).name)

        seen = set()
        for candidate in candidates:
            candidate = candidate.strip()
            if not candidate or candidate in seen:
                continue
            seen.add(candidate)
            entries = outline_map.get(candidate)
            if entries:
                return entries
        return None

    def _create_items_from_toc_outline_entries(
        self,
        chapter: Chapter,
        toc_outline_entries: List[Dict[str, Any]],
        book_title: str,
        book_author: str = "",
    ) -> List[ChapterStructureItem]:
        """Expand chapter entries preserving exact TOC hierarchy (1, 1.2, 1.2.3...)."""
        text = str(getattr(chapter, "text", ""))
        if not toc_outline_entries:
            return []

        deduped: List[Dict[str, Any]] = []
        seen_paths: set[Tuple[int, ...]] = set()
        for entry in toc_outline_entries:
            path = tuple(entry.get("path_indices") or tuple())
            if not path or path in seen_paths:
                continue
            seen_paths.add(path)
            deduped.append(entry)
        if not deduped:
            return []

        path_set = {tuple(entry.get("path_indices") or tuple()) for entry in deduped}

        # Skip parent entries if descendants share the same href; this avoids duplicate content.
        leaf_entries: List[Dict[str, Any]] = []
        for entry in deduped:
            path = tuple(entry.get("path_indices") or tuple())
            has_descendant = any(
                other != path and len(other) > len(path) and other[: len(path)] == path
                for other in path_set
            )
            if has_descendant:
                continue
            leaf_entries.append(entry)

        if not leaf_entries:
            leaf_entries = deduped

        titles_for_split = [str(entry.get("title", "") or "").strip() for entry in leaf_entries]
        valid_titles = [title for title in titles_for_split if title]
        segments_by_title: Dict[str, str] = {}
        if len(valid_titles) > 1 and text:
            segments = self._split_text_by_titles(text, valid_titles)
            for title, segment in zip(valid_titles, segments):
                if title and segment:
                    segments_by_title[title] = segment

        items: List[ChapterStructureItem] = []
        for entry in leaf_entries:
            path = tuple(entry.get("path_indices") or tuple())
            if not path:
                continue
            title = str(entry.get("title", "") or "").strip()
            titles_path = tuple(entry.get("path_titles") or tuple())
            index = ".".join(str(part) for part in path)

            segment_text = segments_by_title.get(title) if title else None
            if not segment_text:
                segment_text = text
            if not str(segment_text).strip():
                segment_text = title or str(getattr(chapter, "name", "") or "")
            if not str(segment_text).strip():
                continue

            main_name = str(titles_path[0]).strip() if titles_path else title
            sub_parts = [str(part).strip() for part in titles_path[1:] if str(part).strip()]
            sub_name = " - ".join(sub_parts) if sub_parts else None

            clean_name = self._clean_chapter_name(title or getattr(chapter, "name", ""))
            preview = self._extract_smart_first_words(
                segment_text,
                clean_name,
                main_name,
                max_words=self.PREVIEW_WORD_LIMIT,
            )

            main_name, sub_name, preview = self._sanitize_display_values(
                main_name, sub_name, preview, book_title, book_author
            )
            preview = self._remove_duplicate_prefix(preview, main_name, sub_name)

            display_name = index
            ordered_values = [value for value in (main_name, sub_name, preview) if value]
            for idx_value, value in enumerate(ordered_values):
                separator = " - "
                if idx_value == len(ordered_values) - 1 and value[:1].islower():
                    separator = " "
                if value[:1] in {",", ";", ":", ".", "!", "?"}:
                    separator = " "
                if separator == " ":
                    display_name = f"{display_name} {value}"
                else:
                    display_name = f"{display_name}{separator}{value}"

            items.append(
                ChapterStructureItem(
                    chapter=chapter,
                    index=index,
                    main_title=main_name,
                    sub_title=sub_name,
                    preview=preview,
                    display_name=display_name,
                    text_override=segment_text,
                    speak_heading=True,
                )
            )

        return items

    def _validate_chapter_count(
        self, chapters: List[Any], reader: EbookReader, duplicates_removed: int = 0
    ) -> Tuple[List[Any], bool]:
        """Validate chapter count against TOC and auto-correct if needed.

        Returns:
            Tuple of (chapters_list, was_corrected)
        """
        expected_count = getattr(reader, "_toc_expected_chapters", 0)

        # Skip validation if no TOC info or too few chapters in TOC
        if expected_count == 0 or expected_count < 3:
            return chapters, False

        actual_count = len(chapters)

        # If counts match or differ by 1 (common due to cover/title pages), everything is good
        diff = abs(actual_count - expected_count)
        if diff == 0:
            return chapters, False

        if diff == 1:
            # Small difference (likely cover page, title page, etc.) - just warn
            print(f"\nℹ️  TOC: {expected_count} chapters | Detected: {actual_count} chapters")
            if actual_count < expected_count:
                print(f"💡 Difference: {diff} (likely cover page or title page ignored)")
            return chapters, False

        # Significant count mismatch - attempt auto-correction
        print(
            f"\n⚠️  VALIDAÇÃO: TOC indica {expected_count} capítulos, mas foram detectados {actual_count}"
        )

        # If we removed duplicates and that caused the mismatch, restore original
        if duplicates_removed > 0 and (actual_count + duplicates_removed) == expected_count:
            print(
                f"🔄 Auto-correction: restoring {duplicates_removed} chapter(s) removed as duplicate"
            )
            print("💡 Reason: deduplication removed valid chapters")

            # Return the chapters WITHOUT deduplication
            # Note: we need to re-generate or get the original list
            # For now, we'll signal that deduplication should be skipped
            return chapters, True

        # If actual > expected, deduplication might help
        if actual_count > expected_count:
            print(f"💡 Detected {actual_count - expected_count} more chapters than expected")
            print("✓ Keeping current result (possible sub-chapters in TOC)")
        else:
            print(f"⚠️  Missing {expected_count - actual_count} chapter(s)!")
            print("💡 Verifique se o EPUB tem estrutura complexa ou TOC incorreto")

        return chapters, False

    def _create_items_from_toc_entries(
        self,
        chapter: Chapter,
        toc_entries: List[Tuple[int, str, Optional[str]]],
        book_title: str,
        division_counters: Dict[int, int],
        remap_division,
        book_author: str = "",
    ) -> List[ChapterStructureItem]:
        """Expand a chapter into structure items using TOC anchors"""

        if not toc_entries:
            return []

        text = str(getattr(chapter, "text", ""))
        has_child_entries = any(
            entry[2] is not None and str(entry[2]).strip() and str(entry[2]).lower() != "none"
            for entry in toc_entries
        )

        # Filter entries that have child_title (excluding None and 'None' string)
        entries_with_titles = [
            entry
            for entry in toc_entries
            if entry[2] is not None and str(entry[2]).lower() != "none"
        ]
        segments_map: Dict[str, str] = {}

        # If we have multiple entries for the same file but only one has content (others are None),
        # we should use division_label as the split key instead
        if not entries_with_titles and len(toc_entries) > 1:
            # Use division_label (entry[1]) as title for splitting
            titles_for_split = [entry[1] for entry in toc_entries if entry[1]]
            if titles_for_split:
                segments = self._split_text_by_titles(text, titles_for_split)
                for entry, segment in zip(toc_entries, segments):
                    if segment and entry[1]:
                        # Map by division_label since child_title is None
                        segments_map[entry[1]] = segment

        if entries_with_titles and not segments_map:
            titles = [entry[2] for entry in entries_with_titles]
            segments = self._split_text_by_titles(text, titles)
            for entry, segment in zip(entries_with_titles, segments):
                if segment:
                    segments_map[entry[2]] = segment

        parent_title: Optional[str] = None
        items: List[ChapterStructureItem] = []

        for division_index, division_label, child_title in toc_entries:
            # When TOC has parent + children pointing to the same file, keeping the
            # parent item duplicates the first child segment. Skip the parent item.
            if has_child_entries and not child_title:
                continue

            normalized_division = remap_division(division_index)
            division_counters.setdefault(normalized_division, 0)

            if child_title:
                division_counters[normalized_division] += 1
                index = f"{normalized_division}.{division_counters[normalized_division]}"
            else:
                division_counters[normalized_division] = 0
                index = f"{normalized_division}.0"

            if child_title and not parent_title and not child_title.strip().startswith("§"):
                parent_title = child_title.strip()

            # Try to get segment from map (check both child_title and division_label)
            segment_text = None
            if child_title:
                segment_text = segments_map.get(child_title)
            elif division_label:
                segment_text = segments_map.get(division_label)
            if not segment_text:
                segment_text = text
            if not str(segment_text).strip():
                continue

            clean_name = self._clean_chapter_name(child_title or getattr(chapter, "name", ""))
            main_name = division_label or clean_name
            sub_name = child_title if child_title else None

            if parent_title and child_title and child_title.strip().startswith("§"):
                sub_name = f"{parent_title} - {child_title.strip()}"

            preview = (
                self._extract_smart_first_words(
                    segment_text, clean_name, division_label, max_words=self.PREVIEW_WORD_LIMIT
                )
                if child_title
                else self._extract_first_words(segment_text, self.PREVIEW_WORD_LIMIT)
            )

            main_name, sub_name, preview = self._sanitize_display_values(
                main_name, sub_name, preview, book_title, book_author
            )

            preview = self._remove_duplicate_prefix(preview, main_name, sub_name)

            display_name = index
            ordered_values = [value for value in (main_name, sub_name, preview) if value]
            for idx_value, value in enumerate(ordered_values):
                separator = " - "
                if idx_value == len(ordered_values) - 1 and value[:1].islower():
                    separator = " "
                if value[:1] in {",", ";", ":", ".", "!", "?"}:
                    separator = " "

                if separator == " ":
                    display_name = f"{display_name} {value}"
                else:
                    display_name = f"{display_name}{separator}{value}"

            items.append(
                ChapterStructureItem(
                    chapter=chapter,
                    index=index,
                    main_title=main_name,
                    sub_title=sub_name,
                    preview=preview,
                    display_name=display_name,
                    text_override=segment_text,
                )
            )

        return items

    def _split_text_by_titles(self, text: str, titles: List[str]) -> List[str]:
        """Split chapter text according to the provided titles"""

        if not titles:
            return []

        lowered = text.lower()
        positions: List[int] = []
        cursor = 0

        for title in titles:
            if not title:
                positions.append(-1)
                continue

            normalized = re.sub(r"\s+", " ", title.strip().lower())

            # Headings appear at line start - look for title after newline or at text start
            # Search in full text and find first match >= cursor to avoid ^ matching substring start
            pattern = r"(^|\n)\s*" + re.escape(normalized) + r"\b"
            idx = -1
            for match in re.finditer(pattern, lowered):
                # Calculate actual position (skip newline if present, then skip whitespace)
                temp_idx = match.start() + (1 if match.group(1) == "\n" else 0)
                while temp_idx < len(lowered) and lowered[temp_idx] in " \t":
                    temp_idx += 1

                # Use first match that comes at or after cursor
                if temp_idx >= cursor:
                    idx = temp_idx
                    break

            if idx == -1 and normalized.startswith("§"):
                section_marker = normalized.split(" ", 1)[0]
                idx = lowered.find(section_marker, cursor)
                if idx == -1:
                    idx = lowered.find(section_marker)

            positions.append(idx)

            if idx != -1:
                cursor = idx + 1

        starts: List[int] = []
        last_valid = 0
        for pos in positions:
            if pos is None or pos < 0:
                starts.append(last_valid)
            else:
                starts.append(pos)
                last_valid = pos

        for idx in range(1, len(starts)):
            if starts[idx] < starts[idx - 1]:
                starts[idx] = starts[idx - 1]

        segments: List[str] = []
        for idx, start in enumerate(starts):
            end = starts[idx + 1] if idx + 1 < len(starts) else len(text)
            segments.append(text[start:end].strip())

        return segments

    def _apply_structure_to_reader(
        self, reader: EbookReader, structure_items: List[ChapterStructureItem]
    ) -> None:
        """Replace reader chapters with structured output for conversion"""

        if not reader.book:
            return

        new_chapters: List[Chapter] = []
        formatter = TextFormattingProcessor()

        for item in structure_items:
            chapter = item.chapter
            formatting_segments = getattr(chapter, "formatting_segments", None)
            if getattr(chapter, "footnotes", None):
                formatting_segments = None

            # Determine text content and ensure headings are spoken
            final_text = item.text_override if item.text_override is not None else chapter.text
            final_text = final_text or ""

            heading_text = self._build_heading_text(item)
            if heading_text:
                normalized_body = final_text.lstrip()
                if not normalized_body.lower().startswith(heading_text.lower()):
                    final_text = f"{heading_text}\n\n{normalized_body}"
                else:
                    final_text = normalized_body
            else:
                final_text = final_text.lstrip()

            # Recompute formatting markers after injecting headings or transforms
            fresh_segments = formatter.parse_formatted_text(final_text)
            formatting_segments = fresh_segments or None

            if PRESERVE_TTS_LAYOUT:
                speech_text = final_text
            else:
                speech_text = formatter.to_audible_text(final_text, formatting_segments)

            # Re-stamp structural speech cues — title announcement
            # ("Capítulo 1...") and "<N> |" / "## N" / bare-number
            # chapter markers — onto speech_text. _apply_text_transforms
            # already did this once on its own copy of speech_text, but
            # this method REBUILDS chapter objects from scratch, so
            # without the second call the brand-new Chapter objects get
            # the cue-less text and the pre-tts cache loses every pause.
            _raw_html_for_cues = getattr(chapter, "raw_html", None)
            _title_for_cues = getattr(chapter, "name", None) or item.display_name
            if _raw_html_for_cues is not None and not isinstance(_raw_html_for_cues, str):
                _raw_html_for_cues = None
            if _title_for_cues is not None and not isinstance(_title_for_cues, str):
                _title_for_cues = None
            speech_text = TextProcessor.apply_structural_speech_cues(
                speech_text,
                raw_html=_raw_html_for_cues,
                chapter_title=_title_for_cues,
            )

            new_chapters.append(
                Chapter(
                    index=item.index,
                    name=item.display_name,
                    source_path=chapter.source_path,
                    text=final_text,
                    level=getattr(chapter, "level", 1),
                    raw_html=getattr(chapter, "raw_html", None),
                    formatting_segments=formatting_segments,
                    footnotes=getattr(chapter, "footnotes", None),
                    speech_text=speech_text,
                )
            )

        reader.book.chapters = new_chapters

    def _build_heading_text(self, item: ChapterStructureItem) -> Optional[str]:
        """Return a clean heading string that should be spoken before the chapter."""

        if not getattr(item, "speak_heading", True):
            return None

        def normalize(value: Optional[str]) -> str:
            return re.sub(r"\s+", " ", value or "").strip()

        main = normalize(item.main_title)
        sub = normalize(item.sub_title)
        parts: List[str] = []

        if sub:
            if main and sub.lower().startswith(main.lower()):
                parts.append(sub)
            else:
                if main:
                    parts.append(main)
                parts.append(sub)
        elif main:
            parts.append(main)
        else:
            fallback = normalize(item.display_name)
            if fallback:
                parts.append(fallback)

        heading = "\n".join(parts).strip()
        return heading or None

    def _apply_text_transforms(
        self,
        items: List[ChapterStructureItem],
        config: ConversionConfig,
        reader: EbookReader,
    ) -> List[ChapterStructureItem]:
        footnote_mode = (getattr(config, "footnote_mode", "inline") or "inline").lower()
        if footnote_mode not in {"inline", "skip", "chapter_end"}:
            footnote_mode = "inline"
        context_words = getattr(config, "footnote_context_words", 8)
        try:
            context_words = max(int(context_words), 0)
        except (TypeError, ValueError):
            context_words = 8

        processed_data: List[dict] = []
        primary_language = getattr(config, "primary_language", None) or self.localization.language
        phrases = self._footnote_phrases(primary_language)

        def build_inline_replacements(footnotes_list: List[Dict[str, str]]) -> dict[str, str]:
            if not footnotes_list or footnote_mode != "inline":
                return {}
            prefix = phrases.get("prefix", "\n")
            template = phrases.get("template", "nota de rodapé {number}: {text}")
            suffix_text = phrases.get("suffix_text", " fim da nota de rodapé")
            closing = phrases.get("closing", "")
            replacements_map: dict[str, str] = {}
            for footnote in footnotes_list:
                intro = template.format(number=footnote["number"], text=footnote["text"])
                suffix_part = suffix_text.format(number=footnote["number"], text=footnote["text"])
                replacements_map[footnote["marker"]] = f"{prefix}{intro}{suffix_part}{closing}"
            return replacements_map

        for chapter_num, item in enumerate(items, 1):
            chapter = item.chapter
            raw_html = getattr(chapter, "raw_html", None)
            if raw_html is not None and not isinstance(raw_html, str):
                raw_html = None
            chapter_footnotes = getattr(chapter, "footnotes", None)
            if chapter_footnotes is not None and not isinstance(chapter_footnotes, list):
                chapter_footnotes = None
            text_source = (
                item.text_override
                if item.text_override is not None
                else getattr(chapter, "text", "")
            )
            if text_source is None or not isinstance(text_source, str):
                text_source = str(text_source or "")
            if item.text_override is not None:
                raw_html = None

            # Reuse text already enriched with footnotes when mode is inline
            if footnote_mode == "inline" and chapter_footnotes:
                raw_html = None

            chapter_label = str(
                item.display_name
                or getattr(chapter, "name", None)
                or (item.index if isinstance(item.index, str) else None)
                or ""
            )
            # Show ordinal number (1/179) + structural identifier (4.23)
            index_display = (
                f"{chapter_num}/{len(items)} [{item.index}]"
                if item.index
                else f"{chapter_num}/{len(items)}"
            )
            print(
                self.localization.t(
                    "preprocess_chapter",
                    index=index_display,
                    title=chapter_label,
                ),
                flush=True,
            )

            if raw_html:
                markup_with_markers, footnotes = TextProcessor.inject_footnotes(
                    raw_html,
                    mode=footnote_mode,
                    context_words=context_words,
                )
                text_with_formatting, formatting_segments = (
                    TextProcessor.html_to_plain_text_with_formatting(markup_with_markers)
                )
                updated_text = TextProcessor._render_footnotes(
                    text_with_formatting,
                    footnotes,
                    mode=footnote_mode,
                    context_words=context_words,
                    phrases=phrases,
                )
                updated_text = TextProcessor.add_pause_before_dash(updated_text)
                if footnotes:
                    setattr(chapter, "footnotes", list(footnotes))
                replacements = build_inline_replacements(footnotes or [])
                if formatting_segments:
                    updated_segments: list[FormattingSegment] = []
                    markers = [fn["marker"] for fn in (footnotes or [])]
                    for segment in formatting_segments:
                        segment_text = segment.text
                        if replacements:
                            for marker, replacement in replacements.items():
                                segment_text = segment_text.replace(marker, replacement)
                        elif markers:
                            for marker in markers:
                                segment_text = segment_text.replace(marker, "")
                        updated_segments.append(
                            FormattingSegment(
                                text=segment_text,
                                formatting=segment.formatting,
                                language=segment.language,
                            )
                        )
                    chapter.formatting_segments = updated_segments
                else:
                    chapter.formatting_segments = None
            else:
                footnotes = list(chapter_footnotes or [])
                if footnote_mode == "skip":
                    updated_text = self._remove_inline_footnotes(text_source)
                else:
                    needs_render = (
                        "[[FOOTNOTE_" in text_source or "[[footnote_" in text_source.lower()
                    )
                    if footnotes and needs_render:
                        updated_text = TextProcessor._render_footnotes(
                            text_source,
                            footnotes,
                            mode=footnote_mode,
                            context_words=context_words,
                            phrases=phrases,
                        )
                    else:
                        updated_text = text_source
                formatting_segments = getattr(chapter, "formatting_segments", None)
                if formatting_segments is not None and not isinstance(formatting_segments, list):
                    formatting_segments = None
                replacements = build_inline_replacements(footnotes or [])
                if formatting_segments:
                    updated_segments: list[FormattingSegment] = []
                    markers = [fn["marker"] for fn in (footnotes or [])]
                    for segment in formatting_segments:
                        segment_text = segment.text
                        if replacements:
                            for marker, replacement in replacements.items():
                                segment_text = segment_text.replace(marker, replacement)
                        elif markers:
                            for marker in markers:
                                segment_text = segment_text.replace(marker, "")
                        updated_segments.append(
                            FormattingSegment(
                                text=segment_text,
                                formatting=segment.formatting,
                                language=segment.language,
                            )
                        )
                    chapter.formatting_segments = updated_segments
                else:
                    chapter.formatting_segments = None

            book_title = config.book_title or reader.title
            final_text = self._prepare_chapter_text(
                updated_text,
                display_name=chapter_label,
                book_title=book_title,
            )
            if not final_text:
                continue

            # Strip inline markdown for speech (remove *, _, etc.)
            processor = TextFormattingProcessor()
            processor.apply_inline_formatting(final_text)
            speech_text = processor.strip_inline_markdown(final_text)

            # Re-apply structural speech cues over the cleaned text so
            # chapter title announcements ("Capítulo 1...") and "<N> |"
            # number markers survive the markdown stripping. The
            # ebook_reader.TextProcessor runs this once during parse,
            # but `_apply_text_transforms` regenerates speech_text from
            # the raw `chapter.text` (which has no cues) — without this
            # second pass the pre-tts cache loses every pause and Edge
            # reads "Capítulo 1 1 a transformação..." in one breath.
            _raw_html = getattr(item.chapter, "raw_html", None)
            _chapter_title = getattr(item.chapter, "name", None)
            if _raw_html is not None and not isinstance(_raw_html, str):
                _raw_html = None
            if _chapter_title is not None and not isinstance(_chapter_title, str):
                _chapter_title = None
            from src.ebook_reader import TextProcessor as _EReader_TP

            speech_text = _EReader_TP.apply_structural_speech_cues(
                speech_text,
                raw_html=_raw_html,
                chapter_title=_chapter_title,
            )

            # **NEW**: Apply automatic language detection if enabled
            if getattr(config, "use_language_detection", True):
                try:
                    from src.language import LanguageMarkup

                    markup = LanguageMarkup()
                    speech_text = markup.annotate(
                        speech_text,
                        primary_language,
                        prioritize_primary_language=getattr(
                            config, "prioritize_primary_language", True
                        ),
                    )
                except (ImportError, Exception) as e:
                    # Silent failure — continue without detection
                    if config.verbose:
                        print(f"⚠️ Language detection disabled: {e}")

            chapter.speech_text = speech_text  # Clean text for TTS

            lines = [line.strip() for line in final_text.splitlines() if line.strip()]
            if not lines:
                continue

            processed_data.append(
                {
                    "item": item,
                    "lines": lines,
                    "line_sigs": [self._text_signature(line) for line in lines],
                    "text": "\n".join(lines),
                }
            )

        index_to_data: dict[str, dict] = {}
        for data in processed_data:
            index = getattr(data["item"], "index", None)
            if isinstance(index, str):
                index_to_data[index] = data

        children_map: dict[str, list[dict]] = {}
        for data in processed_data:
            index = getattr(data["item"], "index", None)
            if not isinstance(index, str) or "." not in index:
                continue
            parent_index = index.rsplit(".", 1)[0]
            parent_data = index_to_data.get(parent_index)
            if parent_data is None and parent_index:
                parent_data = index_to_data.get(f"{parent_index}.0")
            if parent_data is data:
                continue
            if parent_data is None:
                continue
            children_map.setdefault(parent_index, []).append(data)

        for parent_index, child_list in children_map.items():
            parent_data = index_to_data.get(parent_index)
            if parent_data is None and parent_index:
                parent_data = index_to_data.get(f"{parent_index}.0")
            if not parent_data:
                continue
            child_signatures = {sig for child in child_list for sig in child["line_sigs"] if sig}
            parent_lines = parent_data["lines"]
            parent_sigs = parent_data["line_sigs"]
            new_lines = [
                line
                for line, sig in zip(parent_lines, parent_sigs)
                if sig and sig not in child_signatures
            ]
            if child_list:
                if new_lines:
                    first_child = child_list[0]
                    existing = set(first_child["line_sigs"])
                    prepended: list[str] = []
                    for line in new_lines:
                        sig = self._text_signature(line)
                        if sig and sig not in existing:
                            prepended.append(line)
                            existing.add(sig)
                    # **FIXED**: Remove content duplication bug - don't prepend parent content to children
                    # This was causing chapters 1.1 and 1.2 to have identical content
                    if False:  # Disabled to prevent content duplication
                        first_child_lines = prepended + first_child["lines"]
                        first_child["lines"] = first_child_lines
                        first_child["line_sigs"] = [
                            self._text_signature(line) for line in first_child_lines
                        ]
                        first_child["text"] = "\n".join(first_child_lines)
                # **FIXED**: Only skip parent if it has no remaining content after removing children content
                if not new_lines:
                    parent_data["skip"] = True
                else:
                    parent_data["lines"] = new_lines
                    parent_data["line_sigs"] = [self._text_signature(line) for line in new_lines]
                    parent_data["text"] = "\n".join(new_lines)
            else:
                if not new_lines:
                    parent_data["skip"] = True
                else:
                    parent_data["lines"] = new_lines
                    parent_data["line_sigs"] = [self._text_signature(line) for line in new_lines]
                    parent_data["text"] = "\n".join(new_lines)

        transformed_items: List[ChapterStructureItem] = []
        seen_signatures: set[str] = set()

        for data in processed_data:
            if data.get("skip"):
                continue
            text = data["text"].strip()
            if not text:
                continue

            # Preserve top-level chapters ("1") and legacy ".0" main chapters.
            item = data["item"]
            item_index = str(getattr(item, "index", "") or "")
            is_main_chapter = ("." not in item_index) or item_index.endswith(".0")

            # Skip length filter for main chapters to preserve all content
            if not is_main_chapter and len(text) < 20:
                continue

            lines = data["lines"]

            text_signature = self._text_signature(text)

            # Less aggressive filtering for main chapters.
            if not is_main_chapter:
                if text_signature == self._text_signature(item.display_name):
                    continue

                name_parts = [part.strip() for part in item.display_name.split("-") if part.strip()]
                trailing_part = name_parts[-1] if name_parts else item.display_name
                if len(lines) == 1 and self._text_signature(lines[0]) == self._text_signature(
                    trailing_part
                ):
                    continue

                if text_signature in seen_signatures:
                    continue

            seen_signatures.add(text_signature)
            item.text_override = text
            transformed_items.append(item)

        return transformed_items

    def _resolve_book_output_dir(self, reader: EbookReader, config: ConversionConfig) -> Path:
        """The directory the converter writes MP3s into.

        Mirrors the path the converter assembles:
        ``<output_root>/<sanitised(book_title)>/``. Used for both
        existing-output detection (skip re-conversion when the book is
        already there) and the iPhone export step.
        """
        title = getattr(config, "book_title", "") or getattr(reader, "title", "") or "default"
        output_root = Path(getattr(config, "output_dir", None) or OUTPUT_DIR)
        return output_root / FileManager.sanitize_filename(title)

    def _detect_reusable_existing_output(
        self,
        reader: EbookReader,
        items: List[ChapterStructureItem],
        config: ConversionConfig,
        args,
    ) -> Optional[Path]:
        """Return the output dir if it already contains the book's MP3s.

        We don't want to re-synthesise an audiobook the user already has
        on disk just because they re-ran the command. The check is
        deliberately permissive — count distinct MP3s in the target dir
        and accept >=90% of expected chapters as reuse-eligible. The
        per-chapter cache layer below still re-fills any small gap
        without resynthesising the rest.

        Skipped when the user explicitly asked for a fresh run via
        ``--clear-cache``, when ``--chapter`` selects a subset (we can
        only confirm full-book reuse here), or when ``--force`` is set.
        """
        if getattr(args, "clear_cache", False) or getattr(args, "force", False):
            return None
        # Subset selectors (--chapter, ranges) target a different
        # workflow; reuse only applies to full-book runs.
        if getattr(args, "chapter", None):
            return None
        if getattr(args, "from_chapter_to_chapter", None) or getattr(
            args, "from_chapter_to_end", None
        ):
            return None

        try:
            output_dir = self._resolve_book_output_dir(reader, config)
        except Exception:
            return None
        if not output_dir.exists() or not output_dir.is_dir():
            return None

        # Resume-state cache: avoids the per-chapter stat() storm on
        # repeated runs. Originally keyed on output_dir mtime, but writing
        # the state file itself bumped mtime, so the cache only kicked in
        # on the third call. Now keyed on a hash of the sorted MP3 names —
        # stable as long as the file *list* hasn't changed, regardless of
        # how many times we re-write the state file or re-read the dir.
        #
        # The state file lives *inside the output dir itself*, not the
        # parsing cache, because (a) it is intrinsic to the output and
        # should travel with it (b) it avoids colliding with shared cache
        # directories that may already exist for unrelated books.
        expected = len(items)
        cache_state_path = output_dir / "._resume_state.json"

        def _mp3_listing_hash() -> Tuple[int, str]:
            """Return (count, sha1 of sorted "name|size" listing)."""
            entries: List[str] = []
            count = 0
            for path in output_dir.glob("*.mp3"):
                try:
                    if not path.is_file():
                        continue
                    size = path.stat().st_size
                except OSError:
                    continue
                if size <= 0:
                    continue
                entries.append(f"{path.name}|{size}")
                count += 1
            entries.sort()
            # blake2b: faster than sha1 on the small listing strings we
            # hash here, and the resume-state cache key has no
            # cryptographic requirement.
            digest = hashlib.blake2b("\n".join(entries).encode("utf-8"), digest_size=20).hexdigest()
            return count, digest

        cached_count: Optional[int] = None
        if cache_state_path.exists():
            try:
                state = json.loads(cache_state_path.read_text(encoding="utf-8"))
                cached_listing = state.get("listing_hash") if isinstance(state, dict) else None
                if (
                    isinstance(state, dict)
                    and isinstance(cached_listing, str)
                    and isinstance(state.get("mp3_count"), int)
                    and isinstance(state.get("expected"), int)
                    and int(state.get("expected") or 0) == expected
                ):
                    fresh_count, fresh_hash = _mp3_listing_hash()
                    if fresh_hash == cached_listing and fresh_count == int(state["mp3_count"]):
                        cached_count = fresh_count
            except Exception:
                cached_count = None

        if cached_count is not None:
            mp3_count = cached_count
        else:
            mp3_count, listing_hash = _mp3_listing_hash()
            try:
                cache_state_path.write_text(
                    json.dumps(
                        {
                            "listing_hash": listing_hash,
                            "mp3_count": mp3_count,
                            "expected": expected,
                        }
                    ),
                    encoding="utf-8",
                )
            except Exception:
                pass

        if expected == 0 or mp3_count == 0:
            return None
        # 90% threshold: tolerates the case where one or two chapters
        # were skipped but the bulk of the book is already synthesised.
        if mp3_count < int(expected * 0.9):
            return None
        return output_dir

    def _maybe_clean_obsolete_cache(
        self,
        reader: EbookReader,
        items: List[ChapterStructureItem],
        config: ConversionConfig,
    ) -> None:
        """Remove cached audio that does not match any current chapter.

        Edition swaps (different EPUB → same book title) leave the
        previous run's MP3s in the cache dir. The chapter loop happily
        reuses them by filename, so a chapter that was 5,000 chars in
        the old edition gets a 5,000-char MP3 even when the new edition
        has 7,000 chars. This pre-pass deletes any cached MP3 whose
        filename does not correspond to a chapter index in the current
        structure list — a cheap structural check that catches the
        common edition-swap case without parsing chapter content.
        """
        try:
            cache_dir = self.cache_root / FileManager.sanitize_filename(
                getattr(reader, "title", "") or "default"
            )
            if not cache_dir.exists() or not cache_dir.is_dir():
                return
            valid_indices = {str(item.index) for item in items}
            removed = 0
            for path in cache_dir.glob("*.mp3"):
                # Cache filenames look like "<index> - <title>.mp3".
                stem = path.stem.split(" - ", 1)[0].strip()
                if stem and stem not in valid_indices:
                    with contextlib.suppress(OSError):
                        path.unlink()
                        removed += 1
            if removed:
                print(
                    f"🧹 Cache cleanup: removed {removed} stale MP3(s) that no "
                    "longer match the current chapter list"
                )
        except Exception:
            pass

    def _preflight_language_and_config_check(
        self,
        reader: EbookReader,
        items: List[ChapterStructureItem],
        config: ConversionConfig,
        args,
    ) -> bool:
        """Second-pass verification before TTS starts.

        The Carl regression (v0.3.20→v0.3.21) shipped pt-BR audiobook
        narrated by an English Piper model. The first-pass detection
        had agreed on pt-BR; the bug was downstream. But "two
        independent confirmations are better than one" — running a
        second detection over a *different* sample window catches the
        case where the first sample was unrepresentative (e.g. a book
        whose first 5 chapters are all front-matter in English while
        the body is Portuguese).

        Also surfaces the final engine + voice + fallback decisions so
        the user can spot a misconfigured run BEFORE 10 minutes of
        synthesis. Honours `--language` override (the user's choice
        wins, we only warn). Returns True to proceed, False to abort.
        """

        primary = (config.primary_language or "").lower()
        primary_root = primary.split("-", 1)[0]
        user_language_override = bool(
            self._normalize_language_override(getattr(args, "language", None))
        )

        # Independent re-detection over a different sample window:
        # take chapters from the *middle* of the book, not the priority
        # positions used by `_prepare_language_profile`. Mid-book is
        # almost always main content, free of front-matter noise.
        sample_texts: List[str] = []
        total_chars = 0
        if items:
            mid_start = max(0, len(items) // 4)
            mid_end = min(len(items), max(mid_start + 5, (3 * len(items)) // 4))
            for item in items[mid_start:mid_end]:
                source_text = (
                    item.text_override
                    if item.text_override is not None
                    else getattr(item.chapter, "text", "")
                )
                if not source_text and getattr(item.chapter, "raw_html", None):
                    source_text = TextProcessor.html_to_plain_text(item.chapter.raw_html)
                if source_text and len(source_text.strip()) > 200:
                    sample_texts.append(source_text)
                    total_chars += len(source_text)
                    if total_chars >= 5000:
                        break

        verified_lang = ""
        if sample_texts:
            try:
                second_profile = self.language_detector.detect_profile(sample_texts)
                if second_profile and second_profile.primary:
                    verified_lang = second_profile.primary.lower()
            except Exception:
                verified_lang = ""

        verified_root = verified_lang.split("-", 1)[0] if verified_lang else ""

        print()
        print("🔎 Pre-flight check (idioma + parâmetros)")
        print(f"   • Idioma detectado (1ª passagem): {primary or '?'}")
        if verified_lang:
            match = "✓ Match" if verified_root == primary_root else "✗ MISMATCH"
            print(
                f"   • Idioma detectado (2ª passagem, amostra independente): {verified_lang}  {match}"
            )
        else:
            print("   • Idioma detectado (2ª passagem): inconclusivo (texto insuficiente)")
        engine_choice = getattr(args, "engine", "auto") or "auto"
        fallback_choice = getattr(args, "fallback_engine", "auto") or "auto"
        print(f"   • Engine pedido pelo usuário: {engine_choice}")
        print(f"   • Fallback engine: {fallback_choice}")
        if config.voice:
            print(f"   • Voice: {config.voice}")

        if verified_root and primary_root and verified_root != primary_root:
            if user_language_override:
                print(
                    f"   ⚠️  Override do usuário (--language={primary}) difere da 2ª detecção "
                    f"({verified_lang}). Respeitando o pedido do usuário."
                )
            else:
                print()
                print(
                    f"❌ Discrepância de idioma: 1ª passagem disse '{primary}', "
                    f"2ª passagem (amostra independente) disse '{verified_lang}'."
                )
                print(
                    "   Conversão abortada para não gerar áudio em idioma errado. "
                    f"Force com --language {primary} ou --language {verified_lang}."
                )
                return False

        return True

    def _prepare_language_profile(
        self,
        reader: EbookReader,
        items: List[ChapterStructureItem],
        verbose: bool = False,
        *,
        allow_prompt: bool = True,
    ) -> LanguageProfile:
        print(self.localization.t("language_profile_start"), flush=True)
        sample_texts: List[str] = []

        # **FIXED**: Improve language detection for books with empty/short chapters
        # Collect text until we have at least 2000 chars or 20 chapters
        total_chars = 0
        items_checked = 0
        max_items = min(20, len(items))  # Up to 20 chapters
        # IMPROVED: Increased minimum chars for more confident detection (was 2000)
        # This ensures we have enough text to reliably detect the book's primary language
        min_chars = 5000  # Minimum 5000 chars for more reliable detection
        min_chapters = 5  # Minimum 5 chapters (was 3)

        total_items = len(items)
        if total_items <= max_items:
            sample_positions = list(range(total_items))
        else:
            sample_positions = sorted(
                {round(i * (total_items - 1) / (max_items - 1)) for i in range(max_items)}
            )

        for pos in sample_positions:
            if pos >= len(items):
                continue
            item = items[pos]
            source_text = (
                item.text_override
                if item.text_override is not None
                else getattr(item.chapter, "text", "")
            )
            if not source_text and getattr(item.chapter, "raw_html", None):
                source_text = TextProcessor.html_to_plain_text(item.chapter.raw_html)
            if source_text and len(source_text.strip()) > 10:  # Ignorar textos muito pequenos
                sample_texts.append(source_text)
                total_chars += len(source_text)
                items_checked += 1

                # Stop if we already have enough characters AND enough chapters
                if total_chars >= min_chars and items_checked >= min_chapters:
                    break

        if verbose:
            print(
                f"🔍 [VERBOSE] Language: analysed {items_checked} chapter(s), {total_chars} chars"
            )

        ascii_ratio = self._ascii_ratio(sample_texts)
        language_votes = self._collect_language_votes(sample_texts)
        profile = self.language_detector.detect_profile(sample_texts)
        profile = self._rebalance_language_profile(profile, ascii_ratio, language_votes)
        if profile.primary == "pt":
            profile = LanguageProfile(
                primary="pt-BR",
                languages=[
                    "pt-BR" if self._normalise_lang_code(lang) == "pt" else lang
                    for lang in profile.languages
                ],
                predictions=profile.predictions,
                analysed_chars=profile.analysed_chars,
            )

        # Always show detected language
        print(
            f"🌍 Idioma detectado: {profile.primary or '?'} "
            f"({items_checked} capítulos, {total_chars} chars analisados)"
        )

        if not profile.languages or not profile.primary:
            if not allow_prompt:
                return LanguageProfile(
                    primary=None,
                    languages=[],
                    predictions=profile.predictions or [],
                    analysed_chars=sum(len(text) for text in sample_texts),
                )
            languages = self._prompt_for_languages(reader)
            primary = languages[0] if languages else None
            return LanguageProfile(
                primary=primary,
                languages=languages,
                predictions=[],
                analysed_chars=sum(len(text) for text in sample_texts),
            )

        return profile

    @staticmethod
    def _ascii_ratio(texts: List[str]) -> float:
        joined = " ".join(texts)
        if not joined:
            return 0.0
        ascii_chars = sum(1 for ch in joined if 32 <= ord(ch) <= 126)
        return ascii_chars / max(len(joined), 1)

    def _collect_language_votes(self, sample_texts: List[str]) -> dict[str, float]:
        votes: dict[str, float] = {}
        detector = self.language_detector
        for sample in sample_texts:
            if not sample or len(sample.strip()) < 20:
                continue
            local_profile = detector.detect_profile([sample])
            if not local_profile.predictions:
                continue
            weight = len(sample)
            for prediction in local_profile.predictions:
                code = ConverterApplication._normalise_lang_code(prediction.code)
                if not code:
                    continue
                votes[code] = votes.get(code, 0.0) + (prediction.probability * weight)
        return votes

    @staticmethod
    def _normalise_lang_code(code: Optional[str]) -> str:
        if not code:
            return ""
        return code.split("-", 1)[0].lower()

    def _rebalance_language_profile(
        self,
        profile: LanguageProfile,
        ascii_ratio: float,
        language_votes: dict[str, float],
    ) -> LanguageProfile:
        if not profile.predictions:
            return profile

        top_prediction = profile.predictions[0]
        top_code = self._normalise_lang_code(top_prediction.code)
        en_prediction = next(
            (pred for pred in profile.predictions if self._normalise_lang_code(pred.code) == "en"),
            None,
        )

        if (
            en_prediction
            and top_code != "en"
            and ascii_ratio >= 0.65
            and (top_prediction.probability - en_prediction.probability) <= 0.22
        ):
            languages = ["en"] + [
                lang for lang in profile.languages if self._normalise_lang_code(lang) != "en"
            ]
            return LanguageProfile(
                primary="en",
                languages=languages,
                predictions=profile.predictions,
                analysed_chars=profile.analysed_chars,
            )
        total_votes = sum(language_votes.values())
        if total_votes > 0:
            best_code, best_votes = max(language_votes.items(), key=lambda item: item[1])
            vote_ratio = best_votes / total_votes
            normalized_primary = self._normalise_lang_code(profile.primary)
            if vote_ratio >= 0.55 and best_code and normalized_primary != best_code:
                languages = [best_code] + [
                    lang
                    for lang in profile.languages
                    if self._normalise_lang_code(lang) != best_code
                ]
                return LanguageProfile(
                    primary=best_code,
                    languages=languages,
                    predictions=profile.predictions,
                    analysed_chars=profile.analysed_chars,
                )
        return profile

    def _prompt_for_languages(self, reader: EbookReader) -> List[str]:
        default_language = self._infer_language_from_metadata(reader)
        fallback_language = default_language or (
            "pt" if self.localization.language == "pt" else "en"
        )

        if not self._interactive_mode or not sys.stdin.isatty():
            return [fallback_language]

        try:
            raw = input(self.localization.t("language_prompt", default=fallback_language))
        except EOFError:
            return [fallback_language]

        if not raw.strip():
            return [fallback_language]

        languages = [self._normalise_language_code(part) for part in raw.split(",")]
        languages = [lang for lang in languages if lang]
        if not languages:
            languages = [fallback_language]
        return languages

    def _infer_language_from_metadata(self, reader: EbookReader) -> Optional[str]:
        title = (reader.title or "").lower()
        if any(token in title for token in ("portug", "brasil", "brasile")):
            return "pt"
        if any(token in title for token in ("english", "angl", "ingl")):
            return "en"
        return None

    @staticmethod
    def _normalise_language_code(raw: str) -> str:
        if not raw:
            return ""
        clean = raw.strip().lower()
        if not clean:
            return ""
        return clean.split("-", 1)[0]

    def _apply_language_preferences(self, config: ConversionConfig) -> None:
        profile = self.language_profile
        fallback_lang = self.localization.language or "pt"
        if profile is None:
            profile = LanguageProfile(
                primary=config.primary_language,
                languages=[config.primary_language],
                predictions=[],
                analysed_chars=0,
            )
        elif not profile.is_confident:
            profile = LanguageProfile(
                primary=fallback_lang,
                languages=[fallback_lang],
                predictions=profile.predictions,
                analysed_chars=profile.analysed_chars,
            )

        languages = [lang for lang in profile.languages if lang and lang not in {"unknown", "auto"}]
        if not languages and profile.primary and profile.primary not in {"unknown", "auto"}:
            languages = [profile.primary]
        if not languages:
            languages = (
                [config.primary_language]
                if config.primary_language and config.primary_language != "auto"
                else []
            )

        primary_language = profile.primary if profile.primary not in {None, "", "unknown"} else None
        if not primary_language and languages:
            primary_language = languages[0]
        if not primary_language or primary_language in {"", "unknown"}:
            primary_language = (
                config.primary_language
                if config.primary_language not in {None, "", "auto"}
                else "auto"
            )

        config.primary_language = primary_language or "auto"
        config.languages = languages or (
            [config.primary_language] if config.primary_language not in {None, "auto"} else []
        )

        language_roots = {
            self._normalise_language_code(lang) for lang in (config.languages or []) if lang
        }
        language_roots.discard("")
        len(language_roots) == 1
        # Always prefer ThalitaMultilingualNeural — it is the highest quality
        # Edge voice for pt-BR and handles mixed-language text seamlessly.
        # Monolingual voices (Francisca, etc.) are only used when explicitly
        # requested via --voice.
        config.prefer_monolingual_edge = False

        voice_auto_raw = config.extra.get("voice_auto", False)

        def _to_bool(value) -> bool:
            if isinstance(value, bool):
                return value
            if value is None:
                return False
            text = str(value).strip().lower()
            if text in {"1", "true", "yes", "on"}:
                return True
            if text in {"0", "false", "no", "off"}:
                return False
            return bool(text)

        voice_auto = _to_bool(voice_auto_raw)
        if primary_language and (not config.voice or voice_auto):
            suggested_voice = self.config.voice_configs.get_voice(config.engine, primary_language)
            if suggested_voice:
                config.voice = suggested_voice
        if voice_auto and not config.voice:
            for lang in languages:
                suggested_voice = self.config.voice_configs.get_voice(config.engine, lang)
                if suggested_voice:
                    config.voice = suggested_voice
                    break

        prefer_piper = bool(
            language_roots == {"pt"}
            and profile.is_confident
            and self.config.voice_configs.has_piper_model(primary_language)
        )
        config.auto_prefer_piper = prefer_piper

        language_voice_map = self.config.voice_configs.build_language_voice_map(
            config.engine,
            config.languages
            or ([config.primary_language] if config.primary_language not in {None, "auto"} else []),
            config.voice,
            primary_language=config.primary_language,
        )

        config.language_voices = language_voice_map

        if not self._voice_supports_multilingual(config.engine, config.voice):
            if primary_language and primary_language not in {"", "unknown", "auto"}:
                config.languages = [primary_language]
            else:
                fallback = fallback_lang if fallback_lang not in {"", "unknown"} else None
                config.primary_language = fallback or "auto"
                config.languages = (
                    [config.primary_language] if config.primary_language not in {"", "auto"} else []
                )
            config.language_voices = {}

    @staticmethod
    def _remove_inline_footnotes(text: str) -> str:
        if not text:
            return ""
        pattern = re.compile(
            r"\s*nota de rodapé\s+\d+:[^\n]*?fim da nota de rodapé\s+\d+\s*",
            re.IGNORECASE,
        )
        cleaned = pattern.sub(" ", text)
        return re.sub(r"\s+", " ", cleaned).strip()

    @staticmethod
    def _strip_book_title_prefix(text: str, book_title: Optional[str]) -> str:
        if not text:
            return ""
        if not book_title:
            return text.lstrip()

        title = str(book_title).strip()
        if not title:
            return text.lstrip()

        cleaned = text.lstrip()
        suffix_chars = " \t\r\n,.:;-–—“”\"'"
        title_folded = title.casefold()
        while cleaned[: len(title)].casefold() == title_folded:
            cleaned = cleaned[len(title) :].lstrip(suffix_chars)

        def normalise(value: str) -> str:
            value = value or ""
            value = unicodedata.normalize("NFKD", value).casefold()
            return "".join(ch for ch in value if ch.isalnum())

        title_norm = normalise(title)
        lines = cleaned.splitlines()
        while lines and title_norm and normalise(lines[0]) == title_norm:
            lines.pop(0)
        cleaned = "\n".join(lines).lstrip()
        return cleaned

    @staticmethod
    def _voice_supports_multilingual(engine: Optional[str], voice: Optional[str]) -> bool:
        engine_name = (engine or "").lower()
        voice_name = (voice or "").lower()
        if not voice_name:
            return False
        if engine_name == "edge":
            return "multilingual" in voice_name
        if engine_name == "coqui":
            return "xtts" in voice_name or "multi" in voice_name
        if engine_name == "piper":
            return True
        return False

    def _prepare_chapter_text(
        self, raw_text: str, *, display_name: str, book_title: Optional[str]
    ) -> str:
        """Normalise chapter text to ensure parity between cache and audio."""
        text = raw_text or ""
        text = text.replace("\r\n", "\n").replace("\r", "\n")
        text = self._strip_book_title_prefix(text, book_title)
        text = self._deduplicate_heading(text, display_name)
        lines = [line.strip() for line in text.split("\n")]

        display_parts = [part.strip() for part in display_name.split(" - ") if part.strip()]
        ignored_candidates = [display_name] + display_parts[:-1]
        ignored_norms = {self._normalize_lookup(part) for part in ignored_candidates if part}
        if book_title:
            ignored_norms.add(self._normalize_lookup(book_title))

        # Remove redundant consecutive headings and empty lines
        cleaned_lines: list[str] = []
        for line in lines:
            if not line:
                if cleaned_lines and cleaned_lines[-1] != "":
                    cleaned_lines.append("")
                continue

            normalised_line = self._normalize_lookup(line)
            if normalised_line in ignored_norms:
                continue

            if cleaned_lines:
                last = cleaned_lines[-1]
                # Only deduplicate short heading-like lines (≤8 words).
                # Long body sentences may naturally contain the same words as a
                # preceding heading (e.g. "Quarto de Eddie" followed by
                # "...subiram para o quarto de Eddie.") — do not drop the heading.
                _MAX_HEADING_WORDS = 8
                line_is_heading = len(line.split()) <= _MAX_HEADING_WORDS
                last_is_heading = len(last.split()) <= _MAX_HEADING_WORDS
                if last_is_heading and line_is_heading and self._heading_contains(line, last):
                    cleaned_lines[-1] = line
                    continue
                if last_is_heading and line_is_heading and self._heading_contains(last, line):
                    # Skip current line if previous already more descriptive
                    continue

            cleaned_lines.append(line)

        while cleaned_lines and not cleaned_lines[0]:
            cleaned_lines.pop(0)
        while cleaned_lines and not cleaned_lines[-1]:
            cleaned_lines.pop()

        if cleaned_lines and cleaned_lines[-1].lower() in {"notas", "nota"}:
            cleaned_lines.pop()

        text = "\n".join(cleaned_lines)
        text = re.sub(r"\n{3,}", "\n\n", text)
        text = re.sub(r"[\t ]+\n", "\n", text)
        text = re.sub(r"\n[\t ]+", "\n", text)
        text = re.sub(r"\)\s+\.", ").", text)
        text = re.sub(r"\s+\)", ")", text)
        return text.strip()

    @staticmethod
    def _heading_contains(value: str, candidate: str) -> bool:
        value_norm = ConverterApplication._normalize_lookup(value)
        candidate_norm = ConverterApplication._normalize_lookup(candidate)
        if not value_norm or not candidate_norm:
            return False
        return value_norm != candidate_norm and (
            value_norm in candidate_norm or candidate_norm in value_norm
        )

    @staticmethod
    def _text_signature(text: str) -> str:
        if not text:
            return ""
        import re

        return re.sub(r"\s+", " ", text).strip().lower()

    def _footnote_phrases(self, language: Optional[str]) -> Dict[str, str]:
        lang = (language or "").split("-", 1)[0].lower()
        if lang != "en" and lang != "pt":
            lang = "pt"
        if lang == "en":
            return {
                "prefix": "\n",
                "template": "footnote {number}: {text}",
                "suffix_text": " end of footnote",
                "closing": "",
                "chapter_end_template": "footnote {number}: {snippet} - {text} end of footnote",
            }

        return {
            "prefix": "\n",
            "template": "nota de rodapé {number}: {text}",
            "suffix_text": " fim da nota de rodapé",
            "closing": "",
            "chapter_end_template": "nota de rodapé {number}: {snippet} - {text} fim da nota de rodapé",
        }

    @staticmethod
    def _deduplicate_heading(text: str, display_name: str) -> str:
        if not text:
            return text

        lines = text.splitlines()
        if not lines:
            return text

        def normalise(value: str) -> str:
            value = value or ""
            value = unicodedata.normalize("NFKD", value).casefold()
            return "".join(ch for ch in value if ch.isalnum())

        display_norm = normalise(display_name)

        for idx, line in enumerate(lines):
            stripped = line.strip()
            if not stripped:
                continue
            if display_norm and normalise(stripped) == display_norm:
                lines.pop(idx)
            break

        cleaned: list[str] = []
        previous_norm = None
        for line in lines:
            stripped = line.strip()
            if not stripped:
                cleaned.append(line)
                previous_norm = None
                continue
            current_norm = normalise(stripped)
            if previous_norm and current_norm == previous_norm:
                continue
            cleaned.append(line)
            previous_norm = current_norm

        return "\n".join(cleaned).strip()

    @staticmethod
    def _resolve_footnote_mode(args: argparse.Namespace) -> str:
        if getattr(args, "no_footnote", False):
            return "skip"
        if getattr(args, "footnote_chapter_end", False):
            return "chapter_end"
        return "inline"

    def _resolve_cache_dir(self, reader: EbookReader) -> Path:
        """Resolve shared cache directory path for this book."""
        base_name = getattr(reader, "title", None) or getattr(reader, "file_path", None) or "livro"
        sanitized = FileManager.sanitize_filename(base_name) or "livro"
        return resolve_cache_root() / sanitized

    def _handle_clear_cache(self, args: Optional[argparse.Namespace] = None) -> int:
        """Clear cache/output for a specific book, or globally with confirmation."""
        from src.cache_manager import CacheManager

        book_arg = getattr(args, "book", None) if args else None
        if book_arg:
            return self._handle_clear_cache_for_book(book_arg)

        cache_manager = CacheManager(cache_dir=resolve_cache_root())
        cache_root = resolve_cache_root()
        output_dir = OUTPUT_DIR

        # Calculate what will be removed
        cache_info = cache_manager.get_cache_info()
        total_cache_mb = cache_info.get("cache_size_mb", 0)
        total_books = cache_info.get("total_cached_books", 0)

        # Calcular tamanho do output
        output_size_mb = 0.0
        output_file_count = 0
        if output_dir.exists():
            try:
                for item in output_dir.rglob("*"):
                    if item.is_file():
                        output_file_count += 1
                        output_size_mb += item.stat().st_size / (1024 * 1024)
            except Exception:
                pass

        # Show what will be removed
        print("╔══════════════════════════════════════════════════════════╗")
        print("║  🗑️  Complete Cache and Output Cleanup                 ║")
        print("╚══════════════════════════════════════════════════════════╝")
        print()
        print("📊 The following will be removed:")
        print()
        print("  📁 Cache (.cache/):")
        print(f"     • {total_books} cached book(s)")
        print(f"     • {total_cache_mb:.1f} MB")
        print(f"     • Location: {cache_root}")
        print()
        print("  📁 Output (output/):")
        print(f"     • {output_file_count} file(s)")
        print(f"     • {output_size_mb:.1f} MB")
        print(f"     • Location: {output_dir}")
        print()
        print(f"  📦 Total: {total_cache_mb + output_size_mb:.1f} MB")
        print()
        print("⚠️ WARNING: This action CANNOT be undone!")
        print("   • TTS models will be preserved")
        print("   • All converted MP3 files will be removed")
        print("   • All processing cache will be removed")
        print()

        # Request user confirmation
        try:
            response = input("Continue? (type 'yes' to confirm): ").strip().lower()
        except (KeyboardInterrupt, EOFError):
            print("\n❌ Operation cancelled by user.")
            return 1

        if response not in ["sim", "s", "yes", "y"]:
            print("❌ Operation cancelled.")
            return 0

        print()
        print("🧹 Cleaning...")
        print()

        # Remove cache (always attempt, even if no metadata found)
        removed_items = 0
        print("🗑️ Removing book cache...")
        success = cache_manager.clear_cache()
        if success:
            print("   ✅ Book cache removed successfully")
            removed_items += 1
        else:
            print("   ⚠️ No cache found or error removing it")

        # Remove output
        if output_dir.exists():
            print("🗑️ Removing output directory...")
            try:
                shutil.rmtree(output_dir, ignore_errors=True)
                print(f"   ✅ Output directory removed: {output_dir}")
                removed_items += 1
            except Exception as e:
                print(f"   ⚠️ Error removing output: {e}")

        # Remove queues/persistent states
        residual_dirs = [
            JOBS_DIR,
            UPLOADS_DIR,
            JOB_INPUTS_DIR,
            Path.cwd() / ".jobs",
            Path.cwd() / ".uploads",
            Path.cwd() / ".job_inputs",
        ]
        residual_removed = 0
        seen_residual_dirs: Set[str] = set()
        for residual in residual_dirs:
            key = str(residual.resolve()) if residual.exists() else str(residual)
            if key in seen_residual_dirs:
                continue
            seen_residual_dirs.add(key)
            if residual.exists():
                try:
                    shutil.rmtree(residual, ignore_errors=True)
                    residual_removed += 1
                except Exception:
                    pass

        if residual_removed > 0:
            print(f"🗑️ {residual_removed} auxiliary director(y/ies) removed")

        print()
        if removed_items > 0:
            print("╔══════════════════════════════════════════════════════════╗")
            print("║  ✅ Cleanup Completed Successfully                     ║")
            print("╚══════════════════════════════════════════════════════════╝")
            return 0
        else:
            print("❌ No items were removed.")
            return 1

    def _handle_clear_cache_for_book(self, book_path_str: str) -> int:
        """Remove .cache and output entries for a specific book."""
        import shutil

        from src.cache_manager import CacheManager
        from src.utils import FileManager

        book_path = Path(book_path_str)
        if not book_path.exists():
            print(f"❌ File not found: {book_path}")
            return 1

        # Try to extract title from EPUB/PDF metadata; fall back to stem
        title: Optional[str] = None
        try:
            from src.ebook_reader import EbookReader

            reader = EbookReader(book_path)
            title = reader.title or book_path.stem
        except Exception:
            title = book_path.stem

        display_name = title or book_path.stem
        print(f"Removing cache and output for: {display_name}")

        cache_manager = CacheManager(cache_dir=resolve_cache_root())
        cache_manager.clear_cache(book_path, title=title)

        # Remove output directories that match the sanitized title (with or without engine suffix)
        output_base = OUTPUT_DIR
        sanitized_title = FileManager.sanitize_filename(display_name)
        removed_dirs = 0
        if output_base.exists():
            for entry in output_base.iterdir():
                if entry.is_dir() and (
                    entry.name == sanitized_title or entry.name.startswith(f"{sanitized_title}_")
                ):
                    try:
                        shutil.rmtree(entry, ignore_errors=True)
                        removed_dirs += 1
                    except Exception as e:
                        print(f"  Warning: could not remove {entry.name}: {e}")

        print(f"Done. {removed_dirs} output director(y/ies) removed.")
        return 0

    @staticmethod
    def _normalize_lookup(value: Optional[str]) -> str:
        if not value:
            return ""
        normalised = unicodedata.normalize("NFKD", value)
        stripped = "".join(ch for ch in normalised if not unicodedata.combining(ch))
        return stripped.lower().strip()

    def _filter_structure_selection(
        self, items: List[ChapterStructureItem], selectors: Optional[List[str]]
    ) -> Tuple[List[ChapterStructureItem], bool]:
        if not selectors:
            return items, False

        normalised_selectors = [self._normalize_lookup(sel) for sel in selectors if sel]
        normalised_selectors = [sel for sel in normalised_selectors if sel]
        if not normalised_selectors:
            return items, False

        matched: List[ChapterStructureItem] = []
        for item in items:
            matched_selector = False
            for selector in normalised_selectors:
                if self._selector_matches(item, selector):
                    matched_selector = True
                    break

            if not matched_selector:
                continue

            source_key = (
                self._normalize_lookup(str(item.index)),
                self._normalize_lookup(item.display_name),
            )
            if source_key in matched:
                continue
            matched.append(item)

        if not matched:
            selector_preview = ", ".join(selectors)
            available = ", ".join(str(item.index) for item in items[:10])
            print(
                self.localization.t(
                    "selectors_not_found", selectors=selector_preview, available=available
                )
            )
            return [], True

        return matched, True

    def _filter_structure_range(
        self,
        items: List[ChapterStructureItem],
        start_selector: Optional[str],
        end_selector: Optional[str],
    ) -> Tuple[List[ChapterStructureItem], bool]:
        if not start_selector and not end_selector:
            return items, False

        start_selector = (start_selector or "").strip()
        end_selector = (end_selector or "").strip()
        if not start_selector:
            return items, False

        start_norm = self._normalize_lookup(start_selector)
        end_norm = self._normalize_lookup(end_selector) if end_selector else ""

        start_idx = self._find_selector_index(items, start_norm, 0)
        if start_idx is None:
            self._print_selector_not_found(items, start_selector)
            return [], True

        if not end_norm:
            return items[start_idx:], True

        end_idx = self._find_selector_index(items, end_norm, start_idx)
        if end_idx is None:
            self._print_selector_not_found(items, end_selector)
            return [], True

        return items[start_idx : end_idx + 1], True

    def _selector_matches(self, item: ChapterStructureItem, selector_norm: str) -> bool:
        if not selector_norm:
            return False
        index_str = str(item.index)
        index_norm = self._normalize_lookup(index_str)
        base_index_norm = self._normalize_lookup(index_str.split(".", 1)[0]) if index_str else ""
        display_norm = self._normalize_lookup(item.display_name)
        chapter_name_norm = self._normalize_lookup(getattr(item.chapter, "name", ""))

        if selector_norm == index_norm:
            return True
        if selector_norm == base_index_norm and base_index_norm:
            return True
        if index_norm and selector_norm and index_norm.startswith(f"{selector_norm}."):
            return True
        if any(ch.isalpha() for ch in selector_norm):
            if selector_norm in display_norm or selector_norm in chapter_name_norm:
                return True
        return False

    def _find_selector_index(
        self,
        items: List[ChapterStructureItem],
        selector_norm: str,
        start_at: int,
    ) -> Optional[int]:
        for idx in range(max(start_at, 0), len(items)):
            if self._selector_matches(items[idx], selector_norm):
                return idx
        return None

    def _print_selector_not_found(self, items: List[ChapterStructureItem], selector: str) -> None:
        available = ", ".join(str(item.index) for item in items[:10])
        print(self.localization.t("selectors_not_found", selectors=selector, available=available))

    @staticmethod
    def _parse_range_selector(value: Optional[str]) -> Optional[Tuple[str, str]]:
        if not value:
            return None
        raw = str(value).strip()
        if not raw:
            return None
        separator_index = -1
        separator_width = 1
        for token in ("..", ":", ","):
            index = raw.find(token)
            if index >= 0 and (separator_index < 0 or index < separator_index):
                separator_index = index
                separator_width = len(token)
        if separator_index < 0:
            return None
        start = raw[:separator_index].strip()
        end = raw[separator_index + separator_width :].strip()
        if not start or not end:
            return None
        return start, end

    @staticmethod
    def _expand_selector_args(values: Optional[List[str]]) -> List[str]:
        """Allow comma/semicolon separated selectors in a single flag use."""
        expanded: List[str] = []
        for raw in values or []:
            if raw is None:
                continue
            text = str(raw)
            for part in text.replace(";", ",").split(","):
                cleaned = part.strip()
                if cleaned:
                    expanded.append(cleaned)
        return expanded

    def _show_structure(self, reader: EbookReader, *, filter_chapters: bool = True):
        """Display book structure and save cache txt files"""
        print(f"{self.localization.t('book_label')}: {reader.title}")
        print(f"{self.localization.t('author_label')}: {reader.author}")
        structure_items = self._generate_structure_items(reader, filter_chapters=filter_chapters)

        preview_config = self.config.create_conversion_config(
            engine="edge",
            output_dir=str(self.cache_root),
            book_title=reader.title,
        )
        preview_config.footnote_mode = "inline"
        preview_config.footnote_context_words = self.FOOTNOTE_CONTEXT_WORDS

        structure_items = self._apply_text_transforms(structure_items, preview_config, reader)

        # Store original before deduplication for potential restoration
        original_items = structure_items.copy()

        structure_items, duplicates_removed = deduplicate_chapters_by_content(structure_items)
        if duplicates_removed:
            print(f"🧹 {duplicates_removed} duplicate chapter(s) hidden")

        # Validate chapter count against TOC
        structure_items, was_corrected = self._validate_chapter_count(
            structure_items, reader, duplicates_removed
        )

        # If correction was needed, restore original without deduplication
        if was_corrected:
            print(
                f"✅ Restoring {duplicates_removed} chapter(s) — using version without deduplication\n"
            )
            structure_items = original_items

        print(f"{self.localization.t('chapters_label')}: {len(structure_items)}")

        # **Save text cache** when showing structure
        from src.cache_manager import CacheManager

        cache_manager = CacheManager(cache_dir=self.cache_root)

        chapters_data = {
            "title": reader.title or "Unknown",
            "author": reader.author or "Unknown",
            "chapters": [],
        }

        for item in structure_items:
            cleaned_text = str(item.text_override or "")
            text_length = len(cleaned_text)
            print(
                self.localization.t(
                    "structure_item_entry", name=item.display_name, chars=text_length
                )
            )

            # Add chapter to cache data
            chapters_data["chapters"].append({"title": item.display_name, "text": cleaned_text})

        # Save to cache
        if hasattr(reader, "file_path") and reader.file_path:
            success = cache_manager.save_chapters_to_cache(reader.file_path, chapters_data)
            if success:
                # **FIXED**: Do not use override_name to avoid duplicate directories
                cache_txt_path = cache_manager._get_cache_path(Path(reader.file_path)) / "txt"
                print(f"\n💾 Text cache saved to: {cache_txt_path}")
            else:
                print("\n⚠️  Error saving text cache")

    def _should_skip_chapter(
        self,
        chapters: List[Chapter],
        index: int,
        toc_map: Dict[str, List[Tuple[int, str, Optional[str]]]],
    ) -> bool:
        """Heuristically skip duplicate heading fragments that lack TOC links"""

        if index < 0 or index >= len(chapters):
            return True

        chapter = chapters[index]
        href_key = self._normalize_href(str(getattr(chapter, "source_path", "")))
        if self._resolve_toc_entries(href_key, toc_map):
            return False

        text = str(getattr(chapter, "text", "")).strip()
        if not text:
            return True

        # Only skip very short fragments (stray headings, HTML residue).
        # Dedicatórias and epigraphs are typically 50-500 chars and must
        # NOT be dropped — they are real book content.
        if len(text) <= 12:
            return True

        source_path = str(getattr(chapter, "source_path", "")).lower()
        if "_split_000" in source_path and len(text) < 400:
            return True

        clean_name = self._clean_chapter_name(str(getattr(chapter, "name", "")))

        if len(text) <= 120:
            if self._is_heading_like(clean_name):
                return True

            next_chapter = chapters[index + 1] if index + 1 < len(chapters) else None
            if next_chapter:
                next_key = self._normalize_href(str(getattr(next_chapter, "source_path", "")))
                if self._resolve_toc_entries(next_key, toc_map):
                    next_name = self._clean_chapter_name(str(getattr(next_chapter, "name", "")))
                    if next_name:
                        stem_current = self._heading_stem(clean_name)
                        stem_next = self._heading_stem(next_name)
                        if (
                            stem_current
                            and stem_next
                            and (stem_current in stem_next or stem_next in stem_current)
                        ):
                            return True

        return False

    def _is_heading_like(self, name: str) -> bool:
        if not name:
            return False
        lowered = name.lower()
        keywords = (
            "capítulo",
            "capitulo",
            "livro",
            "prefácio",
            "prefacio",
            "posfácio",
            "posfacio",
            "post-scriptum",
            "post scriptum",
            "pos-scriptum",
            "imagem",
        )
        return any(keyword in lowered for keyword in keywords)

    def _heading_stem(self, name: str) -> str:
        if not name:
            return ""
        lowered = name.lower()
        lowered = re.sub(r"cap[íi]tulo\s*\d+", "", lowered)
        lowered = re.sub(r"livro\s*[ivx]+", "", lowered)
        lowered = lowered.replace("post-scriptum", "")
        lowered = lowered.replace("post scriptum", "")
        lowered = lowered.replace("pos-scriptum", "")
        lowered = lowered.replace("prefácio", "")
        lowered = lowered.replace("prefacio", "")
        lowered = lowered.replace("posfácio", "")
        lowered = lowered.replace("posfacio", "")
        lowered = lowered.replace("imagem", "")
        lowered = lowered.replace("§", " ")
        lowered = re.sub(r"\s+", " ", lowered)
        return lowered.strip()

    def _build_toc_map(
        self, reader: EbookReader
    ) -> Dict[str, List[Tuple[int, str, Optional[str]]]]:
        mapping: Dict[str, List[Tuple[int, str, Optional[str]]]] = {}
        get_toc = getattr(reader, "get_toc", None)
        if not callable(get_toc):
            return mapping

        try:
            toc_entries = list(get_toc() or [])
        except Exception:
            return mapping

        counter = 0

        def walk(entries, parent: Optional[Tuple[int, str]] = None):
            nonlocal counter
            for entry in entries:
                href = self._normalize_href(entry.href)
                title = entry.title.strip() if entry.title else ""
                if parent is None:
                    counter += 1
                    division_index = counter
                    division_title = title
                    if href:
                        mapping.setdefault(href, []).append((division_index, division_title, None))
                        alt_key = Path(href).name
                        if alt_key and alt_key != href:
                            alt_key_lower = alt_key.lower()
                            mapping.setdefault(alt_key_lower, []).append(
                                (division_index, division_title, None)
                            )
                    walk(entry.children, (division_index, division_title))
                else:
                    division_index, division_title = parent
                    if href:
                        mapping.setdefault(href, []).append((division_index, division_title, title))
                        alt_key = Path(href).name
                        if alt_key and alt_key != href:
                            alt_key_lower = alt_key.lower()
                            mapping.setdefault(alt_key_lower, []).append(
                                (division_index, division_title, title)
                            )
                    walk(entry.children, parent)

        walk(toc_entries)
        return mapping

    @staticmethod
    def _select_toc_entry(
        entries: Optional[List[Tuple[int, str, Optional[str]]]],
    ) -> Optional[Tuple[int, str, Optional[str]]]:
        if not entries:
            return None
        for entry in entries:
            if entry[2]:
                return entry
        return entries[0]

    @staticmethod
    def _normalize_href(href: str) -> str:
        if not href:
            return ""
        base = href.split("#", 1)[0]
        normalized = base.lstrip("./")
        normalized = normalized.strip()
        normalized = unquote(normalized)
        return normalized.lower()

    @staticmethod
    def _split_group_key(href_key: str) -> Optional[str]:
        if not href_key:
            return None
        match = re.search(r"^(.*)_split_\d{3}(\.[a-z0-9]+)$", href_key, flags=re.IGNORECASE)
        if not match:
            return None
        return f"{match.group(1)}{match.group(2)}".lower()

    def _resolve_toc_entries(
        self, href_key: str, toc_map: Dict[str, List[Tuple[int, str, Optional[str]]]]
    ) -> Optional[List[Tuple[int, str, Optional[str]]]]:
        if not href_key:
            return None

        candidates = []
        lowered = href_key.lower()
        candidates.append(lowered)

        if "/" in lowered:
            parts = lowered.split("/")
            for start in range(1, len(parts)):
                candidates.append("/".join(parts[start:]))

        candidates.append(Path(lowered).name)

        seen = set()
        for candidate in candidates:
            candidate = candidate.strip()
            if not candidate or candidate in seen:
                continue
            seen.add(candidate)
            entries = toc_map.get(candidate)
            if entries:
                return entries
        return None

    def _clean_chapter_name(self, name: str) -> str:
        """Clean up chapter name to avoid redundancy"""
        if not name:
            return ""

        import re

        # Remove redundant patterns like "0.7 -  - Livro primeiro - livro primeiro DUNA"
        # Split by " - " and remove empty parts and redundant parts
        parts = [part.strip() for part in name.split(" - ") if part.strip()]

        cleaned_parts = []
        seen_parts = set()

        for part in parts:
            # Skip parts that look like indices (e.g., "0.7", "1.0")
            if re.match(r"^\d+\.\d+$", part):
                continue
            # Skip empty or very short parts (but allow single characters for important parts)
            if len(part) == 0:
                continue
            if len(part) == 1 and part in ["@", "#", "*", "-"]:
                continue
            # Skip parts that are duplicates (case-insensitive)
            part_lower = part.lower()
            if part_lower not in seen_parts:
                seen_parts.add(part_lower)
                cleaned_parts.append(part)

        # Final cleanup for specific redundancies
        result = " - ".join(cleaned_parts) if cleaned_parts else name

        # Remove specific redundancies like "Livro primeiro - livro primeiro DUNA"
        if "Livro primeiro" in result and "livro primeiro" in result.lower():
            # Keep only the properly capitalized version
            result = re.sub(r" - livro primeiro.*?$", "", result, flags=re.IGNORECASE)

        return result

    def _is_main_division(self, name: str) -> bool:
        """Check if this is a main division (like Livro primeiro, Capítulo X)"""
        if not name:
            return False

        import re

        name_lower = name.lower()

        # Look for book divisions
        division_patterns = [
            r"livro\s+(primeiro|segundo|terceiro|quarto|quinto)",
            r"livro\s+[ivx]+",
            r"book\s+(first|second|third|fourth|fifth)",
            r"book\s+[ivx]+",
            r"parte\s+[ivx\d]+",
            r"seção\s+[ivx\d]+",
            r"capítulo\s+\d+",  # Matches "Capítulo 1", "Capítulo 2", etc.
            r"chapter\s+\d+",  # Chapter 1, 2, etc.
        ]

        for pattern in division_patterns:
            if re.search(pattern, name_lower):
                return True

        return False

    def _clean_main_division_name(self, name: str) -> str:
        """Clean up main division name to remove redundancy"""
        if not name:
            return name

        import re

        # For "Livro primeiro - livro primeiro DUNA", keep just "Livro primeiro"
        parts = [part.strip() for part in name.split(" - ") if part.strip()]

        # Find the best representative part
        best_part = ""
        for part in parts:
            part_lower = part.lower()
            if re.search(r"livro\s+(primeiro|segundo|terceiro)", part_lower) or re.search(
                r"capítulo\s+\d+", part_lower
            ):
                # Prefer the capitalized version
                if part[0].isupper():
                    best_part = part
                elif not best_part:
                    best_part = part

        return best_part if best_part else parts[0] if parts else name

    def _remove_redundant_main_name(self, chapter_name: str, main_name: str) -> str:
        """Remove redundant main name from chapter name"""
        if not chapter_name or not main_name:
            return chapter_name

        # Remove main name parts from chapter name
        main_lower = main_name.lower()
        parts = [part.strip() for part in chapter_name.split(" - ") if part.strip()]

        # Filter out parts that are redundant with main name
        filtered_parts = []
        for part in parts:
            part_lower = part.lower()
            if part_lower != main_lower and main_lower not in part_lower:
                filtered_parts.append(part)

        return " - ".join(filtered_parts) if filtered_parts else chapter_name

    def _is_division_candidate(self, chapter, chapters, index) -> bool:
        text = str(getattr(chapter, "text", "")).strip()
        if index < 3:
            return False
        if len(text) > 400:
            return False
        if index + 1 >= len(chapters):
            return False
        next_text = str(getattr(chapters[index + 1], "text", "")).strip()
        return len(next_text) > 1500

    def _is_substantial_chapter(self, text: str) -> bool:
        """Check if chapter has substantial content"""
        return len(text.strip()) > 5000  # At least 5000 characters

    def _find_main_chapter_for(self, chapters, current_index):
        """Find the main chapter number this subchapter belongs to"""
        # Look backwards for the last main division
        main_counter = 0
        for i in range(current_index):
            chapter = chapters[i]
            clean_name = self._clean_chapter_name(chapter.name)
            if self._is_main_division(clean_name) and len(chapter.text.strip()) >= 10:
                main_counter += 1

        return main_counter if main_counter > 0 else 1

    def _count_subchapters_before(self, chapters, current_index, main_chapter_num):
        """Count how many subchapters exist before this one for the same main chapter"""
        # Find the start index of this main chapter
        main_counter = 0
        main_start_index = 0

        for i in range(current_index):
            chapter = chapters[i]
            clean_name = self._clean_chapter_name(chapter.name)
            if self._is_main_division(clean_name) and len(chapter.text.strip()) >= 10:
                main_counter += 1
                if main_counter == main_chapter_num:
                    main_start_index = i
                    break

        # Count substantial subchapters between main chapter and current
        subchapter_count = 1
        for i in range(main_start_index + 1, current_index):
            chapter = chapters[i]
            if self._is_substantial_chapter(chapter.text):
                subchapter_count += 1

        return subchapter_count

    def _get_main_chapter_name(self, chapters, main_chapter_num):
        """Get the name of the main chapter by number"""
        main_counter = 0
        for chapter in chapters:
            clean_name = self._clean_chapter_name(chapter.name)
            if self._is_main_division(clean_name) and len(chapter.text.strip()) >= 10:
                main_counter += 1
                if main_counter == main_chapter_num:
                    return clean_name
        return None

    def _extract_first_words(self, text: str, max_words: int = PREVIEW_WORD_LIMIT) -> str:
        """Extract first words from text content"""
        if not text or not text.strip():
            return ""

        import re

        # Remove language tags [[lang:xx]] and [[/lang]] before extracting words
        clean_text = re.sub(r"\[\[lang:[a-zA-Z\-]+\]\]", "", text, flags=re.IGNORECASE)
        clean_text = re.sub(r"\[\[/lang\]\]", "", clean_text, flags=re.IGNORECASE)
        clean_text = re.sub(r"\s+", " ", clean_text.strip())
        words = clean_text.split()[:max_words]
        return " ".join(words)

    def _extract_smart_first_words(
        self, text: str, clean_name: str, main_div_name: str, max_words: int = 15
    ) -> str:
        """Extract first words avoiding repetition of chapter/section titles"""
        if not text or not text.strip():
            return ""

        import re

        # Remove language tags [[lang:xx]] and [[/lang]] before extracting words
        clean_text = re.sub(r"\[\[lang:[a-zA-Z\-]+\]\]", "", text, flags=re.IGNORECASE)
        clean_text = re.sub(r"\[\[/lang\]\]", "", clean_text, flags=re.IGNORECASE)
        clean_text = re.sub(r"\s+", " ", clean_text.strip())

        # Remove common patterns that repeat the title information
        patterns_to_remove = []

        # Add patterns based on clean_name
        if clean_name:
            # Remove exact matches
            patterns_to_remove.append(re.escape(clean_name.lower()))

            # Extract key parts of the clean name for removal
            if "§" in clean_name:
                # For sections like "§1 Introduction", remove both the heading and section references
                section_parts = clean_name.split(" ")
                for part in section_parts:
                    if len(part) > 3 and part not in ["§1", "§2", "§3", "§4", "§5"]:
                        patterns_to_remove.append(re.escape(part.lower()))

            if "Capítulo" in clean_name:
                # Remove "capítulo X" (chapter heading) references
                patterns_to_remove.append(r"capítulo\s+\d+")

        # Always strip generic "capitulo X" patterns from previews
        patterns_to_remove.append(r"cap[íi]tulo\s+\d+")

        # Add patterns based on main_div_name
        if main_div_name:
            patterns_to_remove.append(re.escape(main_div_name.lower()))

        # Clean the text by removing these patterns
        text_lower = clean_text.lower()
        for pattern in patterns_to_remove:
            if pattern:
                text_lower = re.sub(pattern, "", text_lower, flags=re.IGNORECASE)

        # Clean up extra spaces and get the result
        text_lower = re.sub(r"\s+", " ", text_lower.strip())

        # If we removed too much, fall back to original approach
        if len(text_lower.strip()) < 10:
            return self._extract_first_words(clean_text, max_words)

        # Extract words from cleaned text
        words = text_lower.split()[:max_words]
        result = " ".join(words)

        # Capitalize first letter
        if result:
            result = result[0].upper() + result[1:] if len(result) > 1 else result.upper()

        return result if result else self._extract_first_words(clean_text, max_words)

    def _display_ebook_metadata(self, reader: EbookReader) -> None:
        """Display ebook metadata at application startup."""
        print("=" * 60)
        print("📚 METADADOS DO EBOOK")
        print("=" * 60)

        # Basic metadata
        print(f"📜 Title: {reader.title or 'N/A'}")
        print(f"✍️ Autor: {reader.author or 'N/A'}")

        # Chapter count
        chapters = list(reader.get_chapters())
        print(f"📊 Chapters: {len(chapters)}")

        # Calculate total text statistics
        total_chars = sum(len(chapter.text or "") for chapter in chapters)
        total_words = sum(len((chapter.text or "").split()) for chapter in chapters)

        print(f"📝 Total de caracteres: {total_chars:,}")
        print(f"💬 Total de palavras: {total_words:,}")

        # File info
        if reader.file_path:
            file_size = reader.file_path.stat().st_size
            file_size_mb = file_size / (1024 * 1024)
            print(f"💾 File size: {file_size_mb:.1f} MB")
            print(f"🗺 Formato: {reader.file_path.suffix.upper()[1:]}")

        # TOC info
        try:
            toc_items = list(reader.get_toc())
            if toc_items:
                print(f"🗺 TOC: {len(toc_items)} entries")
        except Exception:
            pass

        print("=" * 60)
        print()

    def _update_metadata_display_language(self) -> None:
        """Update the terminal with language detection results."""
        if self.language_profile:
            print("🌐 LANGUAGE DETECTION")
            print("-" * 30)
            if self.language_profile.primary:
                confidence = "High" if self.language_profile.is_confident else "Low"
                print(
                    f"🌐 Primary language: {self.language_profile.primary} (confidence: {confidence})"
                )
                if len(self.language_profile.predictions) > 0:
                    best_prediction = self.language_profile.predictions[0]
                    print(f"   Accuracy: {best_prediction.probability:.1%}")
                if len(self.language_profile.languages) > 1:
                    other_langs = ", ".join(
                        self.language_profile.languages[1:3]
                    )  # Show up to 2 more
                    print(f"🌍 Secondary languages: {other_langs}")
            print(f"🔍 Caracteres analisados: {self.language_profile.analysed_chars:,}")
            print()

    def _announce_footnote_mode(self, config: ConversionConfig) -> None:
        """Display the chosen footnote handling mode once per run."""
        if self._footnote_summary_printed:
            return

        mode = (getattr(config, "footnote_mode", "inline") or "inline").lower()
        raw_context = getattr(config, "footnote_context_words", self.FOOTNOTE_CONTEXT_WORDS)
        try:
            context_words = max(int(raw_context), 0)
        except (TypeError, ValueError):
            context_words = self.FOOTNOTE_CONTEXT_WORDS
        if context_words == 0:
            context_words = self.FOOTNOTE_CONTEXT_WORDS

        label_keys = {
            "inline": "footnote_option_inline",
            "chapter_end": "footnote_option_chapter_end",
            "skip": "footnote_option_skip",
        }
        label_key = label_keys.get(mode, "footnote_option_inline")
        mode_label = self.localization.t(label_key)
        print(self.localization.t("footnote_selected", option=mode_label))

        if mode == "inline":
            print(self.localization.t("footnote_inline_context", value=context_words))
        elif mode == "chapter_end":
            print(self.localization.t("footnote_chapter_end_context", value=context_words))

        self._footnote_summary_printed = True

    def _sanitize_first_words(self, first_words: str, *phrases: str) -> str:
        """Remove redundant leading phrases from extracted first words"""
        if not first_words:
            return ""

        cleaned = first_words.strip()
        if not cleaned:
            return ""

        import re

        for phrase in phrases:
            if not phrase:
                continue
            phrase_clean = phrase.strip()
            if not phrase_clean:
                continue

            pattern = rf"^{re.escape(phrase_clean)}[\s\-–—,:;]*"
            cleaned = re.sub(pattern, "", cleaned, flags=re.IGNORECASE)

        return cleaned.strip(" -—–,:;!?\"'()[]{}")

    def _sanitize_display_values(
        self, main_name, sub_name, first_words, book_title, book_author=None
    ):
        """Clean display values to avoid repeating the book title or duplicates"""

        book_title_clean = (book_title or "").strip()
        book_author_clean = (book_author or "").strip()

        def cleanse(value: Optional[str]) -> str:
            if not value:
                return ""
            cleaned = str(value).strip()
            if not cleaned:
                return ""
            if book_title_clean and cleaned.lower() == book_title_clean.lower():
                return ""
            if book_author_clean and cleaned.lower() == book_author_clean.lower():
                return ""
            if book_title_clean:
                title_pattern = re.escape(book_title_clean)
                # Remove parenthetical fragments that still reference the book title
                cleaned = re.sub(
                    rf"\(\s*[^)]*{title_pattern}[^)]*\)",
                    "",
                    cleaned,
                    flags=re.IGNORECASE,
                )
                pattern = re.compile(title_pattern, re.IGNORECASE)
                cleaned = pattern.sub("", cleaned)
                cleaned = re.sub(r"\s+", " ", cleaned)
                cleaned = cleaned.strip()
                cleaned = re.sub(r"\s+([)\]}])", r"\1", cleaned)
                cleaned = re.sub(r"([\(\[\{])\s+", r"\1", cleaned)
                cleaned = re.sub(r"\(\s*\)", "", cleaned)
                cleaned = re.sub(r"\[\s*\]", "", cleaned)
                cleaned = re.sub(r"\{\s*\}", "", cleaned)
            if book_author_clean:
                author_pattern = re.escape(book_author_clean)
                cleaned = re.sub(author_pattern, "", cleaned, flags=re.IGNORECASE)
                cleaned = re.sub(r"\s+", " ", cleaned)
                cleaned = cleaned.strip()
            cleaned = cleaned.strip(" -–—,:;")
            return cleaned

        main = cleanse(main_name)
        sub = cleanse(sub_name)
        first = cleanse(first_words)

        seen = set()

        def unique(value: str) -> str:
            if not value:
                return ""
            lowered = value.lower()
            if lowered in seen:
                return ""
            seen.add(lowered)
            return value

        main = unique(main)
        sub = unique(sub)
        first = unique(first)

        def normalise_case(value: Optional[str]) -> Optional[str]:
            if not value:
                return value
            stripped = value.strip()
            if not stripped:
                return None
            if stripped.lower() == stripped:
                return stripped[:1].upper() + stripped[1:]
            return stripped

        main = normalise_case(main)
        sub = normalise_case(sub)
        first = normalise_case(first)

        return (main or None, sub or None, first or None)

    def _remove_duplicate_prefix(self, preview: Optional[str], *references: Optional[str]):
        if not preview:
            return None

        import re

        cleaned = preview.strip()
        for ref in references:
            if not ref:
                continue
            ref_clean = str(ref).strip()
            if not ref_clean:
                continue

            # Remove exact matches at start
            if cleaned.lower().startswith(ref_clean.lower()):
                cleaned = cleaned[len(ref_clean) :].strip(" -–—,:;")

            # Remove partial word matches too
            ref_words = ref_clean.lower().split()
            for word in ref_words:
                if len(word) > 3:  # Only for significant words
                    pattern = r"\b" + re.escape(word) + r"\b"
                    cleaned = re.sub(pattern, "", cleaned, flags=re.IGNORECASE).strip()

        # Clean up multiple spaces and separators
        cleaned = re.sub(r"[-–—,:;\s]+", " ", cleaned).strip()

        cleaned = re.sub(r"^(?:\d+\s+){1,3}", "", cleaned).strip()

        return cleaned or None

    def _parse_leading_number(self, raw_index: str) -> Optional[int]:
        try:
            return int(raw_index.split()[0])
        except (ValueError, IndexError):
            return None

    def _format_chapter_display(
        self, chapter, chapters, current_index, book_title, book_author=None
    ):
        """Format chapter display generically without book-specific rules"""

        text = str(getattr(chapter, "text", ""))
        name = str(getattr(chapter, "name", "")).strip()

        if len(text.strip()) < 5 and not name:
            return None

        index = self._format_index_value(chapter, current_index)
        clean_name = self._clean_chapter_name(name)
        preview = self._extract_first_words(text, self.PREVIEW_WORD_LIMIT)

        main_name, sub_name, preview = self._sanitize_display_values(
            clean_name, None, preview, book_title, book_author
        )

        label = self._detect_section_label(clean_name, text, current_index)
        if label:
            main_name = label

        if not any((main_name, sub_name, preview)):
            fallback_preview = self._extract_first_words(text, min(self.PREVIEW_WORD_LIMIT, 20))
            main_name = clean_name or fallback_preview or f"Chapter {current_index + 1}"
            sub_name = None
            preview = None

        preview = self._remove_duplicate_prefix(preview, main_name, sub_name)

        return (index, main_name, sub_name, preview)

    def _detect_section_label(self, clean_name: str, text: str, position: int) -> Optional[str]:
        lower_name = (clean_name or "").lower()
        lower_text = (text or "").lower()

        if position <= 5:
            if any(
                keyword in lower_name or keyword in lower_text for keyword in ("sumário", "sumario")
            ):
                labels = []
                if (
                    "sumário" in lower_name
                    or "sumario" in lower_name
                    or "sumário" in lower_text
                    or "sumario" in lower_text
                ):
                    labels.append("Sumário")
                if "capa" in lower_name or "capa" in lower_text:
                    labels.append("Capa")
                if "folha de rosto" in lower_name or "folha de rosto" in lower_text:
                    labels.append("Folha de rosto")
                return "/".join(labels) if labels else "Sumário"
            if (
                any(keyword in lower_name for keyword in ("introdu", "prefácio"))
                or any(keyword in lower_text for keyword in ("introdu", "prefácio"))
                or (
                    len(lower_text) > 800
                    and "capítulo" not in lower_text
                    and "dedic" not in lower_text
                )
            ):
                return "Introdução"
            if "dedic" in lower_name or "dedic" in lower_text:
                return "Dedicatória"

        return None

    def _format_index_value(self, chapter, position):
        raw_index = getattr(chapter, "index", None)
        if isinstance(raw_index, str) and raw_index.strip():
            return raw_index.strip()
        if isinstance(raw_index, (int, float)):
            return str(raw_index)
        return str(position + 1)

    def _get_conversion_config(self, args: argparse.Namespace, reader: EbookReader):
        """Get conversion configuration"""
        formatting_cues_pref = getattr(args, "formatting_cues", None)
        if getattr(args, "menu", False):
            config = self.menu.get_conversion_config(
                reader,
                language_profile=self.language_profile,
                formatting_cues=formatting_cues_pref,
            )
            if config:
                if getattr(args, "listen", False):
                    config.listen = True
                cache_dir = getattr(args, "cache_dir", None)
                if cache_dir:
                    config.cache_dir = Path(cache_dir)
                config.clear_cache = getattr(args, "clear_cache", False)
                config.footnote_mode = self._resolve_footnote_mode(args)
                config.footnote_context_words = self.FOOTNOTE_CONTEXT_WORDS
                self._apply_language_preferences(config)
                cues_enabled = (
                    formatting_cues_pref
                    if formatting_cues_pref is not None
                    else getattr(config, "speak_formatting_cues", True)
                )
                config.speak_formatting_cues = bool(cues_enabled)
                config.formatting_locale = self.localization.language
                apply_benchmark_profile(config.engine, config=config)
                self._apply_cli_overrides(args, config)
            return config
        config = self._create_config_from_args(args, reader)
        self._apply_language_preferences(config)
        apply_benchmark_profile(config.engine, config=config)
        self._apply_cli_overrides(args, config)
        return config

    def _create_config_from_args(self, args: argparse.Namespace, reader: EbookReader):
        """Create config from command line arguments"""
        verbose = self._resolve_verbose(args)
        formatting_cues_pref = getattr(args, "formatting_cues", None)
        cues_enabled = True if formatting_cues_pref is None else bool(formatting_cues_pref)
        primary_language = self._normalize_language_override(getattr(args, "language", None))
        edge_chunk_chars = self._clamp_int(
            getattr(args, "edge_chunk_chars", None), min_value=4000, max_value=24000
        )
        edge_max_segment_seconds = self._clamp_int(
            getattr(args, "edge_max_segment_seconds", None), min_value=30, max_value=600
        )
        coqui_chunk_chars = self._clamp_int(
            getattr(args, "coqui_chunk_chars", None), min_value=800, max_value=8000
        )
        coqui_max_workers = self._clamp_int(
            getattr(args, "coqui_max_workers", None), min_value=1, max_value=12
        )
        piper_max_procs = self._clamp_int(
            getattr(args, "piper_max_procs", None), min_value=1, max_value=12
        )
        piper_chunk_chars = self._clamp_int(
            getattr(args, "piper_chunk_chars", None), min_value=800, max_value=12000
        )
        sample_rate = self._clamp_int(
            getattr(args, "sample_rate", None), min_value=8000, max_value=96000
        )
        channels = self._clamp_int(getattr(args, "channels", None), min_value=1, max_value=2)
        overrides: Dict[str, Any] = {}
        if primary_language:
            overrides["primary_language"] = primary_language
        if edge_chunk_chars is not None:
            overrides["edge_chunk_chars"] = edge_chunk_chars
        if edge_max_segment_seconds is not None:
            overrides["edge_max_segment_seconds"] = edge_max_segment_seconds
        if getattr(args, "edge_enable_parallel", None) is not None:
            overrides["edge_enable_parallel"] = bool(getattr(args, "edge_enable_parallel"))
        if getattr(args, "edge_auto_tune", None) is not None:
            overrides["edge_auto_tune"] = bool(getattr(args, "edge_auto_tune"))
        if coqui_chunk_chars is not None:
            overrides["coqui_chunk_chars"] = coqui_chunk_chars
        if coqui_max_workers is not None:
            overrides["coqui_max_workers"] = coqui_max_workers
        if getattr(args, "coqui_safe_mode", None) is not None:
            overrides["coqui_safe_mode"] = bool(getattr(args, "coqui_safe_mode"))
        if piper_max_procs is not None:
            overrides["piper_max_procs"] = piper_max_procs
        if piper_chunk_chars is not None:
            overrides["piper_chunk_chars"] = piper_chunk_chars
        if getattr(args, "bitrate", None):
            overrides["bitrate"] = str(getattr(args, "bitrate"))
        if sample_rate is not None:
            overrides["sample_rate"] = sample_rate
        if channels is not None:
            overrides["channels"] = channels

        # Validation settings
        if getattr(args, "verify_transcription", None) is not None:
            overrides["verify_transcription"] = bool(args.verify_transcription)
        if getattr(args, "transcription_model", None):
            overrides["transcription_model"] = str(args.transcription_model)
        if getattr(args, "validation_language", None):
            overrides["validation_language"] = str(args.validation_language)
        if getattr(args, "validate_during_conversion", False):
            overrides["validate_text"] = True
            overrides["validate_audio"] = True
        if getattr(args, "validate_text", None) is not None:
            overrides["validate_text"] = bool(getattr(args, "validate_text"))
        if getattr(args, "validate_audio", None) is not None:
            overrides["validate_audio"] = bool(getattr(args, "validate_audio"))
        if getattr(args, "strict_validate", False):
            overrides["strict_validate"] = True
        if getattr(args, "auto_validate_output", None) is not None:
            overrides["auto_validate_output"] = bool(getattr(args, "auto_validate_output"))
        if getattr(args, "auto_fix_output", None) is not None:
            overrides["auto_fix_output"] = bool(getattr(args, "auto_fix_output"))

        # "auto" is a UI-friendly alias kept for parity with the web form; it
        # means "let the default (Edge) engine handle it" at the CLI layer.
        engine_choice = args.engine or "edge"
        if engine_choice == "auto":
            engine_choice = "edge"
        config = self.config.create_conversion_config(
            engine=engine_choice,
            voice=args.voice,
            model=args.model,
            output_dir=args.output_dir or str(OUTPUT_DIR),
            book_title=reader.title,
            preserve_all_chapters=not getattr(args, "filter_chapters", False),
            use_simple_converter=False,
            listen=getattr(args, "listen", False),
            cache_dir=getattr(args, "cache_dir", None),
            clear_cache=getattr(args, "clear_cache", False),
            footnote_mode=self._resolve_footnote_mode(args),
            footnote_context_words=self.FOOTNOTE_CONTEXT_WORDS,
            verbose=verbose,
            priority_selectors=getattr(args, "priority", []) or [],
            speak_formatting_cues=cues_enabled,
            formatting_locale=self.localization.language,
            max_auto_retries=getattr(args, "retry_failed_rounds", None),
            manual_retry_failed=getattr(args, "retry_failed_manual", False),
            force_reprocess=bool(
                getattr(args, "force_reprocess", False) or getattr(args, "no_cache", False)
            ),
            **overrides,
        )
        # Optional title-pause injection (off by default, opt-in via
        # --inject-title-pause MS). 0 = disabled, any positive value
        # is the silence duration in milliseconds.
        try:
            config.inject_title_pause_ms = max(0, int(getattr(args, "inject_title_pause", 0) or 0))
        except (TypeError, ValueError):
            config.inject_title_pause_ms = 0
        char_voices_pref = getattr(args, "character_voices", None)
        if char_voices_pref is not None:
            config.enable_character_voices = bool(char_voices_pref)
        narrator_override = getattr(args, "narrator_voice", None)
        if narrator_override:
            config.narrator_voice = narrator_override
        character_override = getattr(args, "character_voice", None)
        if character_override:
            config.character_voice = character_override
        use_language_detection = getattr(args, "use_language_detection", None)
        if use_language_detection is not None:
            config.use_language_detection = bool(use_language_detection)
        prioritize_primary = getattr(args, "prioritize_primary_language", None)
        if prioritize_primary is not None:
            config.prioritize_primary_language = bool(prioritize_primary)
        return config

    def _apply_cli_overrides(self, args: argparse.Namespace, config: ConversionConfig) -> None:
        if config is None:
            return
        use_language_detection = getattr(args, "use_language_detection", None)
        if use_language_detection is not None:
            config.use_language_detection = bool(use_language_detection)
        prioritize_primary = getattr(args, "prioritize_primary_language", None)
        if prioritize_primary is not None:
            config.prioritize_primary_language = bool(prioritize_primary)

        if (
            getattr(args, "force_reprocess", False)
            or getattr(args, "no_cache", False)
            or getattr(args, "clear_cache", False)
        ):
            config.force_reprocess = True
        resume_from_failure = getattr(args, "resume_from_failure", None)
        if resume_from_failure is not None:
            config.extra["resume_from_failure"] = "1" if bool(resume_from_failure) else "0"
        chapter_prefetch = getattr(args, "chapter_prefetch", None)
        if chapter_prefetch is not None:
            config.extra["chapter_prefetch"] = "1" if bool(chapter_prefetch) else "0"
        auto_ab = getattr(args, "auto_ab", None)
        if auto_ab is not None:
            config.extra["auto_ab"] = "1" if bool(auto_ab) else "0"
        adaptive_checkpoint = getattr(args, "adaptive_checkpoint", None)
        if adaptive_checkpoint is not None:
            config.extra["adaptive_checkpoint"] = "1" if bool(adaptive_checkpoint) else "0"
        stage_pipeline = getattr(args, "stage_pipeline", None)
        if stage_pipeline is not None:
            config.extra["stage_pipeline"] = "1" if bool(stage_pipeline) else "0"
        stage_pipeline_depth = self._clamp_int(
            getattr(args, "stage_pipeline_depth", None), min_value=1, max_value=8
        )
        if stage_pipeline_depth is not None:
            config.extra["stage_pipeline_depth"] = str(stage_pipeline_depth)

        edge_chunk_chars = self._clamp_int(
            getattr(args, "edge_chunk_chars", None), min_value=4000, max_value=24000
        )
        edge_max_segment_seconds = self._clamp_int(
            getattr(args, "edge_max_segment_seconds", None), min_value=30, max_value=600
        )
        edge_parallel_override = getattr(args, "edge_enable_parallel", None)
        edge_auto_tune_override = getattr(args, "edge_auto_tune", None)
        coqui_chunk_chars = self._clamp_int(
            getattr(args, "coqui_chunk_chars", None), min_value=800, max_value=8000
        )
        coqui_max_workers = self._clamp_int(
            getattr(args, "coqui_max_workers", None), min_value=1, max_value=12
        )
        coqui_safe_mode = getattr(args, "coqui_safe_mode", None)
        piper_max_procs = self._clamp_int(
            getattr(args, "piper_max_procs", None), min_value=1, max_value=12
        )
        piper_chunk_chars = self._clamp_int(
            getattr(args, "piper_chunk_chars", None), min_value=800, max_value=12000
        )

        if edge_chunk_chars is not None:
            config.edge_chunk_chars = edge_chunk_chars
        if edge_max_segment_seconds is not None:
            config.edge_max_segment_seconds = edge_max_segment_seconds
        if edge_parallel_override is not None:
            config.edge_enable_parallel = bool(edge_parallel_override)
        if edge_auto_tune_override is not None:
            config.edge_auto_tune = bool(edge_auto_tune_override)
        if coqui_chunk_chars is not None:
            config.coqui_chunk_chars = coqui_chunk_chars
        if coqui_max_workers is not None:
            config.coqui_max_workers = coqui_max_workers
        if coqui_safe_mode is not None:
            config.coqui_safe_mode = bool(coqui_safe_mode)
        if piper_max_procs is not None:
            config.piper_max_procs = piper_max_procs
        if piper_chunk_chars is not None:
            config.piper_chunk_chars = piper_chunk_chars
            os.environ["PIPER_CHUNK_CHARS"] = str(piper_chunk_chars)

        edge_stable_mode = getattr(args, "edge_stable_mode", None)
        if edge_stable_mode is not None:
            config.extra["edge_stable_mode"] = "1" if edge_stable_mode else "0"
        if edge_stable_mode:
            if (config.engine or "").lower() == "edge":
                if edge_chunk_chars is None:
                    config.edge_chunk_chars = 4000
                if edge_max_segment_seconds is None:
                    config.edge_max_segment_seconds = 120
                if edge_auto_tune_override is None:
                    config.edge_auto_tune = False
                config.edge_enable_parallel = False
            os.environ["CHAPTER_PARALLEL_COUNT"] = "1"
            os.environ["CHAPTER_PARALLEL_MAX"] = "1"
            os.environ.setdefault("CHAPTER_STALL_SECONDS", "60")
            os.environ.setdefault("EDGE_NETWORK_TIER", "slow")

        bitrate = getattr(args, "bitrate", None)
        if bitrate:
            config.bitrate = str(bitrate)

        if getattr(args, "auto_validate_output", None) is not None:
            config.auto_validate_output = bool(getattr(args, "auto_validate_output"))
        if getattr(args, "auto_fix_output", None) is not None:
            config.auto_fix_output = bool(getattr(args, "auto_fix_output"))
        if getattr(args, "deep_validate", None) is not None:
            config.deep_validate = bool(getattr(args, "deep_validate"))
        sample_rate = self._clamp_int(
            getattr(args, "sample_rate", None), min_value=8000, max_value=96000
        )
        if sample_rate is not None:
            config.sample_rate = sample_rate
        channels = self._clamp_int(getattr(args, "channels", None), min_value=1, max_value=2)
        if channels is not None:
            config.channels = channels

        auto_engine_mode = (config.engine or "").lower() == "auto"
        if auto_engine_mode:
            # Auto mode should continuously tune for throughput in CLI runs.
            os.environ.setdefault("ENABLE_AUTO_TUNING", "1")
            os.environ.setdefault("ENABLE_ADAPTIVE_PERFORMANCE", "1")
            os.environ.setdefault("CHAPTER_STALL_SECONDS", "45")
            if edge_auto_tune_override is None:
                config.edge_auto_tune = True

        self._apply_speed_profile(args, config)

        max_performance = bool(getattr(args, "max_performance", False) or auto_engine_mode)
        if max_performance:
            profile = getattr(self.converter, "hardware_profile", None)
            cpu_physical = int(getattr(profile, "cpu_physical", 2) or 2)
            has_gpu = bool(getattr(profile, "has_gpu", False))
            ram_total = float(getattr(profile, "ram_total_gb", 0.0) or 0.0)
            if edge_chunk_chars is None:
                config.edge_chunk_chars = 24000
            if edge_max_segment_seconds is None:
                config.edge_max_segment_seconds = 300
            if edge_parallel_override is None:
                config.edge_enable_parallel = True
            if coqui_chunk_chars is None:
                config.coqui_chunk_chars = 8000
            if coqui_max_workers is None:
                if has_gpu:
                    config.coqui_max_workers = 3 if ram_total >= 8 else 2
                else:
                    config.coqui_max_workers = min(12, max(2, cpu_physical * 2))
            if piper_max_procs is None:
                config.piper_max_procs = min(6, max(1, cpu_physical))
            if piper_chunk_chars is None and getattr(config, "piper_chunk_chars", None) is None:
                config.piper_chunk_chars = 3000

        parallel_slots = self._clamp_int(
            getattr(args, "parallel_slots", None), min_value=1, max_value=12
        )
        if parallel_slots is None and max_performance and not getattr(args, "no_parallel", False):
            profile = getattr(self.converter, "hardware_profile", None)
            cpu_physical = int(getattr(profile, "cpu_physical", 2) or 2)
            parallel_slots = min(6, max(2, cpu_physical * 2))
        if parallel_slots is not None:
            os.environ["CHAPTER_PARALLEL_COUNT"] = str(parallel_slots)
            os.environ["CHAPTER_PARALLEL_MAX"] = str(parallel_slots)

        chapter_stall_seconds = self._clamp_float(
            getattr(args, "chapter_stall_seconds", None),
            min_value=10.0,
            max_value=900.0,
        )
        if chapter_stall_seconds is not None:
            os.environ["CHAPTER_STALL_SECONDS"] = str(chapter_stall_seconds)

        edge_network_tier = getattr(args, "edge_network_tier", None)
        if edge_network_tier:
            os.environ["EDGE_NETWORK_TIER"] = str(edge_network_tier)

        self._apply_healthcheck_env(args)

        if getattr(args, "no_parallel", False):
            config.edge_enable_parallel = False
            os.environ["CHAPTER_PARALLEL_COUNT"] = "1"
            os.environ["CHAPTER_PARALLEL_MAX"] = "1"

        if getattr(args, "multi_engine_parallel", False):
            config.extra["multi_engine_parallel"] = "1"

    def _apply_speed_profile(self, args: argparse.Namespace, config: ConversionConfig) -> None:
        profile_name = str(getattr(args, "profile", "") or "").strip().lower()
        if profile_name != "speed":
            return

        scenario = str(getattr(args, "speed_scenario", "auto") or "auto").strip().lower()
        hw_profile = getattr(self.converter, "hardware_profile", None)
        network_tier = str(getattr(hw_profile, "network_speed_estimate", "") or "").lower()
        cpu_physical = int(getattr(hw_profile, "cpu_physical", 2) or 2)
        ram_total = float(getattr(hw_profile, "ram_total_gb", 0.0) or 0.0)

        if scenario == "auto":
            if network_tier in {"slow", "medium"}:
                scenario = "offline-heavy"
            elif network_tier in {"fast", "ultra"} and cpu_physical >= 6 and ram_total >= 12:
                scenario = "edge-fast"
            else:
                scenario = "balanced"

        if getattr(config, "extra", None) is None:
            config.extra = {}
        config.extra["speed_profile"] = "speed"
        config.extra["speed_scenario"] = scenario

        if scenario == "offline-heavy":
            config.auto_prefer_piper = True
            config.edge_enable_parallel = False
            config.edge_chunk_chars = min(int(config.edge_chunk_chars or 12000), 8000)
            config.edge_max_segment_seconds = min(int(config.edge_max_segment_seconds or 85), 90)
            slots = max(1, min(3, cpu_physical // 2 if cpu_physical > 1 else 1))
            os.environ["CHAPTER_PARALLEL_COUNT"] = str(slots)
            os.environ["CHAPTER_PARALLEL_MAX"] = str(slots)
        elif scenario == "edge-fast":
            config.edge_enable_parallel = True
            config.edge_chunk_chars = max(int(config.edge_chunk_chars or 12000), 20000)
            config.edge_max_segment_seconds = max(int(config.edge_max_segment_seconds or 85), 180)
            config.edge_max_concurrency = max(int(config.edge_max_concurrency or 8), 12)
            slots = min(6, max(2, cpu_physical))
            os.environ["CHAPTER_PARALLEL_COUNT"] = str(slots)
            os.environ["CHAPTER_PARALLEL_MAX"] = str(slots)
        else:
            config.edge_enable_parallel = True
            config.edge_chunk_chars = max(12000, int(config.edge_chunk_chars or 12000))
            config.edge_max_segment_seconds = max(85, int(config.edge_max_segment_seconds or 85))
            config.edge_max_concurrency = max(int(config.edge_max_concurrency or 6), 8)
            slots = min(4, max(2, cpu_physical // 2 if cpu_physical > 2 else 2))
            os.environ["CHAPTER_PARALLEL_COUNT"] = str(slots)
            os.environ["CHAPTER_PARALLEL_MAX"] = str(slots)

    def _apply_healthcheck_env(self, args: argparse.Namespace) -> None:
        interval = self._clamp_float(
            getattr(args, "health_check_interval_seconds", None),
            min_value=10.0,
            max_value=300.0,
        )
        slow_edge = self._clamp_float(
            getattr(args, "health_check_slow_edge_cps", None),
            min_value=10.0,
            max_value=500.0,
        )
        slow_cps = self._clamp_float(
            getattr(args, "health_check_slow_cps", None),
            min_value=10.0,
            max_value=300.0,
        )
        high_cpu = self._clamp_float(
            getattr(args, "health_check_high_cpu", None),
            min_value=30.0,
            max_value=100.0,
        )
        high_mem = self._clamp_float(
            getattr(args, "health_check_high_mem", None),
            min_value=30.0,
            max_value=100.0,
        )
        ok_cpu = self._clamp_float(
            getattr(args, "health_check_ok_cpu", None),
            min_value=10.0,
            max_value=100.0,
        )
        ok_mem = self._clamp_float(
            getattr(args, "health_check_ok_mem", None),
            min_value=10.0,
            max_value=100.0,
        )
        slow_streak = self._clamp_int(
            getattr(args, "health_check_slow_streak", None), min_value=1, max_value=6
        )
        if interval is not None:
            os.environ["JOB_HEALTHCHECK_INTERVAL_SECONDS"] = str(interval)
        if slow_edge is not None:
            os.environ["JOB_HEALTHCHECK_SLOW_EDGE_CPS"] = str(slow_edge)
        if slow_cps is not None:
            os.environ["JOB_HEALTHCHECK_SLOW_CPS"] = str(slow_cps)
        if high_cpu is not None:
            os.environ["JOB_HEALTHCHECK_HIGH_CPU_PERCENT"] = str(high_cpu)
        if high_mem is not None:
            os.environ["JOB_HEALTHCHECK_HIGH_MEM_PERCENT"] = str(high_mem)
        if ok_cpu is not None:
            os.environ["JOB_HEALTHCHECK_OK_CPU_PERCENT"] = str(ok_cpu)
        if ok_mem is not None:
            os.environ["JOB_HEALTHCHECK_OK_MEM_PERCENT"] = str(ok_mem)
        if slow_streak is not None:
            os.environ["JOB_HEALTHCHECK_SLOW_STREAK"] = str(slow_streak)


def _apply_overnight_preset(args: argparse.Namespace) -> None:
    """Apply a stable high-throughput offline preset for long overnight runs."""
    if not bool(getattr(args, "overnight", False)):
        return
    args.engine = "piper"
    args.max_performance = True
    args.profile = "speed"
    args.speed_scenario = "offline-heavy"
    args.stage_pipeline = True
    args.stage_pipeline_depth = 3
    args.chapter_prefetch = True
    args.auto_ab = False
    args.adaptive_checkpoint = True
    args.verify_transcription = False
    args.deep_validate = False
    args.validate_text = False
    args.validate_audio = False
    args.auto_validate_output = False
    args.auto_fix_output = False
    args.fix_mode = False
    if getattr(args, "piper_chunk_chars", None) is None:
        args.piper_chunk_chars = 2200


def _add_conversion_arguments(
    parser: argparse.ArgumentParser,
    *,
    include_menu_flag: bool = True,
    input_required: bool = True,
) -> None:
    """Attach shared CLI arguments and optional tab completion metadata."""

    input_arg = parser.add_argument(
        "input_file",
        nargs="?",
        help="Input EPUB or PDF file",
    )
    parser.add_argument(
        "extra_inputs",
        nargs="*",
        help="Additional EPUB/PDF files to convert sequentially",
    )
    engine_arg = parser.add_argument(
        "--engine",
        choices=["auto", "edge", "coqui", "piper", "kokoro", "spark"],
        default="edge",
        help="TTS engine to use (default: edge). auto=edge (alias), edge=fast cloud, coqui=neural local, kokoro=fast local, spark=LLM-based",
    )
    parser.add_argument(
        "--fallback-engine",
        choices=["auto", "piper", "kokoro", "none"],
        default="none",
        help=(
            "Engine used to re-synthesize a single sentence if the primary engine hangs/fails. "
            "Default is 'none' — staying on the user-chosen engine instead of silently switching "
            "(the Carl regression: a pt-BR audiobook was narrated by an English Piper model "
            "because the previous default 'auto' fell through to Piper without telling the user). "
            "Set explicitly to 'piper' / 'kokoro' / 'auto' to opt back into per-sentence fallback."
        ),
    )
    parser.add_argument(
        "--engine-chain-fallback",
        action="store_true",
        help="Enable the legacy multi-engine cascade (Edge -> Kokoro -> Piper). Default is Edge-only with per-chunk fallback. Mirrors ENGINE_CHAIN_FALLBACK=1.",
    )
    parser.add_argument(
        "--prewarm-kokoro",
        action="store_true",
        help=(
            "Pre-load the Kokoro pipeline before the chapter loop starts (saves ~3-5s "
            "on the first chapter that triggers Kokoro). Off by default — only worth it "
            "for en/ja/zh books that actually use Kokoro fallback."
        ),
    )
    parser.add_argument(
        "--prewarm-edge",
        action="store_true",
        help=(
            "Open and drain a tiny Edge-TTS stream before the chapter loop starts so "
            "the first chapter does not pay the TLS handshake + first-request latency. "
            "Saves ~300-500ms on the first chapter. Best-effort: failures are silent."
        ),
    )
    parser.add_argument(
        "--prewarm-piper",
        action="store_true",
        help=(
            "Locate the Piper binary and resolve the model file for the primary "
            "language before the chapter loop starts. Useful when Piper is the "
            "expected fallback. Best-effort: failures are silent."
        ),
    )
    parser.add_argument(
        "--inject-title-pause",
        type=int,
        default=0,
        metavar="MS",
        help=(
            "Inject N ms of silence between the chapter title announcement and "
            "the body via ffmpeg post-processing. Off by default (a fixed-length "
            "pause sounds uniform across chapters of varying length). "
            "Try 1500 or 2000 to opt in."
        ),
    )
    parser.add_argument("--voice", help="Voice to use (engine-specific)")
    parser.add_argument("--model", help="Model path (for Piper/Coqui/Spark)")
    parser.add_argument("--output-dir", help="Output directory")
    parser.add_argument(
        "--show-structure",
        action="store_true",
        help="Print the detected book structure and exit",
    )
    parser.add_argument(
        "--detect-language",
        "--show-language",
        action="store_true",
        help="Detect book language and exit (prints primary language + precision)",
    )
    parser.add_argument(
        "--filter-chapters",
        action="store_true",
        help="Skip very short chapters when converting",
    )
    verbose_group = parser.add_mutually_exclusive_group()
    verbose_group.add_argument(
        "--verbose",
        dest="verbose",
        action="store_true",
        default=None,
        help="Enable verbose logging (default: enabled)",
    )
    verbose_group.add_argument(
        "--no-verbose",
        dest="verbose",
        action="store_false",
        default=None,
        help="Disable verbose logging",
    )
    cues_group = parser.add_mutually_exclusive_group()
    cues_group.add_argument(
        "--formatting-cues",
        dest="formatting_cues",
        action="store_true",
        default=None,
        help="Read formatting cues aloud (quotes, italics, bold)",
    )
    cues_group.add_argument(
        "--no-formatting-cues",
        dest="formatting_cues",
        action="store_false",
        default=None,
        help="Disable spoken formatting cues",
    )
    char_voices_group = parser.add_mutually_exclusive_group()
    char_voices_group.add_argument(
        "--character-voices",
        dest="character_voices",
        action="store_true",
        default=None,
        help="Use a separate voice for dialogue (default: on)",
    )
    char_voices_group.add_argument(
        "--no-character-voices",
        dest="character_voices",
        action="store_false",
        default=None,
        help="Read every line with the same voice (no narrator/character split)",
    )
    parser.add_argument(
        "--narrator-voice",
        dest="narrator_voice",
        default=None,
        help="Voice for narration (defaults to --voice when omitted)",
    )
    parser.add_argument(
        "--character-voice",
        dest="character_voice",
        default=None,
        help="Voice for dialogue spans (text inside quotes / em-dash lines)",
    )
    parser.add_argument(
        "--listen",
        action="store_true",
        help="Play each chapter immediately after conversion",
    )
    parser.add_argument(
        "--export-to-iphone",
        dest="export_to_iphone",
        action="store_true",
        default=None,
        help=(
            "After conversion, copy MP3s into the MP3AudioBookPlayer iCloud "
            "Drive container so they sync to the iPhone (macOS only). The "
            "files appear in 'Files > MP3AudioBookPlayer' on the device. "
            "Override the container path with IPHONE_EXPORT_DIR or enable "
            "globally with EXPORT_TO_IPHONE=1."
        ),
    )
    parser.add_argument(
        "--no-parallel",
        dest="no_parallel",
        action="store_true",
        help="Disable chapter/segment parallelism (1 chapter at a time)",
    )
    parser.add_argument(
        "--multi-engine",
        dest="multi_engine_parallel",
        action="store_true",
        help="Run Edge and a local engine (Piper/Kokoro) simultaneously on different chapters for maximum throughput. Disabled by default — local engines may misdetect language.",
    )
    parser.add_argument(
        "--no-footnote",
        action="store_true",
        help="Skip footnotes entirely",
    )
    parser.add_argument(
        "--footnote-chapter-end",
        action="store_true",
        help="Read footnotes at the end of the chapter instead of inline",
    )
    parser.add_argument(
        "--clear-cache",
        action="store_true",
        help="Remove cache and output for this book, then convert. Without a book, removes ALL cache/output (with confirmation)",
    )
    parser.add_argument(
        "--no-cache",
        dest="no_cache",
        action="store_true",
        help="Ignore existing cache/output and regenerate everything from scratch (also clears .cache for this run)",
    )
    resume_group = parser.add_mutually_exclusive_group()
    resume_group.add_argument(
        "--resume-from-failure",
        dest="resume_from_failure",
        action="store_true",
        default=None,
        help="When a failure checkpoint exists, retry only failed chapters first",
    )
    resume_group.add_argument(
        "--no-resume-from-failure",
        dest="resume_from_failure",
        action="store_false",
        default=None,
        help="Ignore failure checkpoint and process selected chapters normally",
    )
    parser.add_argument(
        "--verify",
        "--verify-only",
        dest="verify_only",
        action="store_true",
        help="Validate existing output/cache against EPUB only (no new conversion)",
    )
    parser.add_argument(
        "--fix",
        dest="fix_mode",
        action="store_true",
        help="Verify then auto-fix: reconvert problematic chapters until book is 100%% intact",
    )
    parser.add_argument(
        "--verify-transcription",
        "--audio-verify",
        action="store_true",
        default=None,
        dest="verify_transcription",
        help="Enable deep validation via speech-to-text transcription (disabled by default, requires faster-whisper)",
    )
    parser.add_argument(
        "--no-verify-transcription",
        "--no-audio-verify",
        action="store_false",
        dest="verify_transcription",
        help="Disable speech-to-text transcription verification",
    )
    parser.add_argument(
        "--deep-validate",
        action="store_true",
        dest="deep_validate",
        default=None,
        help="Enable deep validation (full text/audio comparison) after converting",
    )
    parser.add_argument(
        "--no-deep-validate",
        action="store_false",
        dest="deep_validate",
        help="Disable deep validation (default, faster)",
    )
    parser.add_argument(
        "--validate-during-conversion",
        action="store_true",
        help="Validate parsed text and MP3 output during conversion",
    )
    parser.add_argument(
        "--auto-validate-output",
        dest="auto_validate_output",
        action="store_true",
        default=None,
        help="Always run post-validation (enabled by default)",
    )
    parser.add_argument(
        "--no-auto-validate-output",
        dest="auto_validate_output",
        action="store_false",
        default=None,
        help="Disable automatic post-validation",
    )
    parser.add_argument(
        "--auto-fix-output",
        dest="auto_fix_output",
        action="store_true",
        default=None,
        help="Always auto-fix on validation errors (enabled by default)",
    )
    parser.add_argument(
        "--no-auto-fix-output",
        dest="auto_fix_output",
        action="store_false",
        default=None,
        help="Disable automatic auto-fix",
    )
    parser.add_argument(
        "--no-validate",
        action="store_true",
        help="Disable all validation (text and audio) during conversion",
    )
    parser.add_argument(
        "--validate-text",
        dest="validate_text",
        action="store_true",
        default=True,
        help="Validate parsed/pre-tts text during conversion (enabled by default)",
    )
    parser.add_argument(
        "--no-validate-text",
        dest="validate_text",
        action="store_false",
        help="Disable text validation during conversion",
    )
    parser.add_argument(
        "--validate-audio",
        dest="validate_audio",
        action="store_true",
        default=True,
        help="Validate MP3 integrity and duration during conversion (enabled by default)",
    )
    parser.add_argument(
        "--no-validate-audio",
        dest="validate_audio",
        action="store_false",
        help="Disable MP3 validation during conversion",
    )
    parser.add_argument(
        "--strict-validate",
        action="store_true",
        help="Stop conversion when validation fails",
    )
    parser.add_argument(
        "--transcription-model",
        default="small",
        choices=["tiny", "base", "small", "medium", "large"],
        help="Whisper model for transcription validation (default: small)",
    )
    parser.add_argument(
        "--validation-language",
        help="Language code for transcription validation (e.g., pt, en, es)",
    )
    parser.add_argument(
        "--chapter",
        action="append",
        dest="chapters",
        metavar="CHAPTER",
        help="Select chapters by index (supports dotted syntax like 3 or 1.2) or title snippet; repeat the flag or pass comma-separated values (e.g., 5.1,5.2,5.3)",
    )
    parser.add_argument(
        "--from-chapter-to-end",
        dest="from_chapter_to_end",
        metavar="CHAPTER",
        help="Convert starting from a chapter (same syntax as --chapter) to the end",
    )
    parser.add_argument(
        "--from-chapter-to-chapter",
        dest="from_chapter_to_chapter",
        metavar="RANGE",
        help="Convert from chapter A to chapter B (use A..B, e.g., 5.1..7.3)",
    )
    parser.add_argument(
        "--section",
        action="append",
        dest="sections",
        metavar="SECTION",
        help="Additional selectors for subsections or names (accepts dotted indices and text); repeat or use comma-separated values",
    )
    parser.add_argument(
        "--priority",
        action="append",
        dest="priority",
        metavar="PRIORITY",
        help="Prioritize chapters before the rest (same syntax as --chapter)",
    )
    parser.add_argument(
        "--language",
        help="Override primary language (e.g., pt, en, pt-BR). Use 'auto' to detect",
    )
    language_detection_group = parser.add_mutually_exclusive_group()
    language_detection_group.add_argument(
        "--use-language-detection",
        dest="use_language_detection",
        action="store_true",
        default=None,
        help="Enable automatic language markup for mixed-language text",
    )
    language_detection_group.add_argument(
        "--no-language-detection",
        dest="use_language_detection",
        action="store_false",
        default=None,
        help="Disable automatic language markup for mixed-language text",
    )
    prioritize_language_group = parser.add_mutually_exclusive_group()
    prioritize_language_group.add_argument(
        "--prioritize-primary-language",
        dest="prioritize_primary_language",
        action="store_true",
        default=None,
        help="Prefer the primary language when detections are ambiguous",
    )
    prioritize_language_group.add_argument(
        "--no-prioritize-primary-language",
        dest="prioritize_primary_language",
        action="store_false",
        default=None,
        help="Allow ambiguous language detections to override the primary language",
    )
    parser.add_argument(
        "--ui-language",
        dest="ui_language",
        help="Force CLI language (pt or en)",
    )
    parser.add_argument(
        "--max-performance",
        dest="max_performance",
        action="store_true",
        help="Use aggressive performance defaults (larger chunks and more parallelism)",
    )
    parser.add_argument(
        "--overnight",
        dest="overnight",
        action="store_true",
        help="Apply overnight preset: Piper + offline-heavy speed profile + staged pipeline + minimal validation",
    )
    parser.add_argument(
        "--profile",
        dest="profile",
        choices=["speed"],
        help="Apply predefined profile (speed)",
    )
    parser.add_argument(
        "--speed-scenario",
        dest="speed_scenario",
        choices=["auto", "balanced", "edge-fast", "offline-heavy"],
        default="auto",
        help="Scenario for --profile speed (auto|balanced|edge-fast|offline-heavy)",
    )
    parser.add_argument(
        "--parallel-slots",
        dest="parallel_slots",
        type=int,
        help="Override number of parallel chapters",
    )
    parser.add_argument(
        "--chapter-stall-seconds",
        dest="chapter_stall_seconds",
        type=float,
        help="Watchdog timeout before restarting a stalled chapter",
    )
    parser.add_argument(
        "--edge-chunk-chars",
        dest="edge_chunk_chars",
        type=int,
        help="Override Edge chunk size (chars)",
    )
    parser.add_argument(
        "--edge-max-segment-seconds",
        dest="edge_max_segment_seconds",
        type=int,
        help="Override Edge max segment duration (seconds)",
    )
    parser.add_argument(
        "--edge-network-tier",
        dest="edge_network_tier",
        choices=["slow", "medium", "fast", "ultra"],
        help="Override Edge network tier (slow/medium/fast/ultra)",
    )
    edge_parallel_group = parser.add_mutually_exclusive_group()
    edge_parallel_group.add_argument(
        "--edge-enable-parallel",
        dest="edge_enable_parallel",
        action="store_true",
        default=None,
        help="Enable Edge internal parallelism",
    )
    edge_parallel_group.add_argument(
        "--edge-disable-parallel",
        dest="edge_enable_parallel",
        action="store_false",
        default=None,
        help="Disable Edge internal parallelism",
    )
    edge_auto_tune_group = parser.add_mutually_exclusive_group()
    edge_auto_tune_group.add_argument(
        "--edge-auto-tune",
        dest="edge_auto_tune",
        action="store_true",
        default=None,
        help="Enable Edge auto-tuning (adaptive chunk/segment sizes)",
    )
    edge_auto_tune_group.add_argument(
        "--no-edge-auto-tune",
        dest="edge_auto_tune",
        action="store_false",
        default=None,
        help="Disable Edge auto-tuning",
    )
    edge_stable_group = parser.add_mutually_exclusive_group()
    edge_stable_group.add_argument(
        "--edge-stable-mode",
        dest="edge_stable_mode",
        action="store_true",
        default=None,
        help="Use a safer Edge profile (lower parallelism, longer timeouts)",
    )
    edge_stable_group.add_argument(
        "--no-edge-stable-mode",
        dest="edge_stable_mode",
        action="store_false",
        default=None,
        help="Disable Edge stable mode overrides",
    )
    parser.add_argument(
        "--coqui-chunk-chars",
        dest="coqui_chunk_chars",
        type=int,
        help="Override Coqui chunk size (chars)",
    )
    parser.add_argument(
        "--coqui-max-workers",
        dest="coqui_max_workers",
        type=int,
        help="Override Coqui worker pool size",
    )
    coqui_safe_group = parser.add_mutually_exclusive_group()
    coqui_safe_group.add_argument(
        "--coqui-safe-mode",
        dest="coqui_safe_mode",
        action="store_true",
        default=None,
        help="Enable Coqui safe mode (limit parallelism)",
    )
    coqui_safe_group.add_argument(
        "--no-coqui-safe-mode",
        dest="coqui_safe_mode",
        action="store_false",
        default=None,
        help="Disable Coqui safe mode",
    )
    parser.add_argument(
        "--piper-max-procs",
        "--piper-workers",
        dest="piper_max_procs",
        type=int,
        help="Override Piper concurrent process limit",
    )
    parser.add_argument(
        "--piper-chunk-chars",
        dest="piper_chunk_chars",
        type=int,
        help="Override Piper chunk size (chars)",
    )
    parser.add_argument(
        "--bitrate",
        dest="bitrate",
        help="Override output bitrate (e.g., 8k, 32k)",
    )
    parser.add_argument(
        "--sample-rate",
        dest="sample_rate",
        type=int,
        help="Override output sample rate (Hz)",
    )
    parser.add_argument(
        "--channels",
        dest="channels",
        type=int,
        help="Override output channels (1=mono, 2=stereo)",
    )
    parser.add_argument(
        "--force-reprocess",
        dest="force_reprocess",
        action="store_true",
        help="Ignore cached audio and regenerate all chapters",
    )
    parser.add_argument(
        "--health-check-interval-seconds",
        dest="health_check_interval_seconds",
        type=float,
        help="Healthcheck interval in seconds (server mode only)",
    )
    parser.add_argument(
        "--health-check-slow-edge-cps",
        dest="health_check_slow_edge_cps",
        type=float,
        help="Healthcheck Edge slow threshold (chars/s)",
    )
    parser.add_argument(
        "--health-check-slow-cps",
        dest="health_check_slow_cps",
        type=float,
        help="Healthcheck slow threshold for non-Edge engines (chars/s)",
    )
    parser.add_argument(
        "--health-check-high-cpu",
        dest="health_check_high_cpu",
        type=float,
        help="Healthcheck high CPU threshold (percent)",
    )
    parser.add_argument(
        "--health-check-high-mem",
        dest="health_check_high_mem",
        type=float,
        help="Healthcheck high memory threshold (percent)",
    )
    parser.add_argument(
        "--health-check-ok-cpu",
        dest="health_check_ok_cpu",
        type=float,
        help="Healthcheck OK CPU threshold (percent)",
    )
    parser.add_argument(
        "--health-check-ok-mem",
        dest="health_check_ok_mem",
        type=float,
        help="Healthcheck OK memory threshold (percent)",
    )
    parser.add_argument(
        "--health-check-slow-streak",
        dest="health_check_slow_streak",
        type=int,
        help="Healthcheck slow streak before reducing parallelism",
    )
    parser.add_argument(
        "--retry-failed",
        dest="retry_failed_rounds",
        metavar="N",
        type=int,
        help="Number of automatic retry rounds for failed chapters (default: auto). Use 0 to disable.",
    )
    parser.add_argument(
        "--retry-failed-manual",
        dest="retry_failed_manual",
        action="store_true",
        help="After auto retries, force one extra pass only for failed chapters.",
    )
    parser.add_argument(
        "--show-metrics-summary",
        dest="show_metrics_summary",
        action="store_true",
        help="Print runtime metrics summary from metrics-summary.json when conversion ends",
    )
    parser.add_argument(
        "--show-metrics-dashboard",
        dest="show_metrics_dashboard",
        action="store_true",
        help="Print metrics dashboard path (metrics-dashboard.html) when conversion ends",
    )
    parser.add_argument(
        "--open-metrics-dashboard",
        dest="open_metrics_dashboard",
        action="store_true",
        help="Open metrics-dashboard.html in default browser when conversion ends",
    )
    parser.add_argument(
        "--export-metrics-bundle",
        dest="export_metrics_bundle",
        action="store_true",
        help="Export metrics files into a ZIP bundle when conversion ends",
    )
    prefetch_group = parser.add_mutually_exclusive_group()
    prefetch_group.add_argument(
        "--prefetch",
        dest="chapter_prefetch",
        action="store_true",
        default=None,
        help="Enable chapter prefetch pipeline",
    )
    prefetch_group.add_argument(
        "--no-prefetch",
        dest="chapter_prefetch",
        action="store_false",
        default=None,
        help="Disable chapter prefetch pipeline",
    )
    stage_pipeline_group = parser.add_mutually_exclusive_group()
    stage_pipeline_group.add_argument(
        "--stage-pipeline",
        dest="stage_pipeline",
        action="store_true",
        default=None,
        help="Enable internal staged pipeline (prepare/synthesize/encode overlap)",
    )
    stage_pipeline_group.add_argument(
        "--no-stage-pipeline",
        dest="stage_pipeline",
        action="store_false",
        default=None,
        help="Disable internal staged pipeline",
    )
    parser.add_argument(
        "--stage-pipeline-depth",
        dest="stage_pipeline_depth",
        type=int,
        help="Prefetch depth for staged pipeline (default: 2)",
    )
    auto_ab_group = parser.add_mutually_exclusive_group()
    auto_ab_group.add_argument(
        "--ab-auto",
        dest="auto_ab",
        action="store_true",
        default=None,
        help="Enable online A/B exploration in auto-engine mode",
    )
    auto_ab_group.add_argument(
        "--no-ab-auto",
        dest="auto_ab",
        action="store_false",
        default=None,
        help="Disable online A/B exploration in auto-engine mode",
    )
    adaptive_checkpoint_group = parser.add_mutually_exclusive_group()
    adaptive_checkpoint_group.add_argument(
        "--adaptive-checkpoint",
        dest="adaptive_checkpoint",
        action="store_true",
        default=None,
        help="Enable adaptive-state checkpoint persistence",
    )
    adaptive_checkpoint_group.add_argument(
        "--no-adaptive-checkpoint",
        dest="adaptive_checkpoint",
        action="store_false",
        default=None,
        help="Disable adaptive-state checkpoint persistence",
    )
    parser.add_argument(
        "--batch",
        action="append",
        dest="batch_inputs",
        metavar="PATH",
        help="Additional EPUB/PDF files or directories to convert sequentially (accepts glob patterns)",
    )
    parser.add_argument(
        "--batch-file",
        dest="batch_manifest",
        metavar="FILE",
        help="Path to a text file containing one EPUB/PDF path per line for batch conversion",
    )
    parser.add_argument(
        "--stop-on-error",
        dest="batch_stop_on_error",
        action="store_true",
        help="Stop batch conversions after the first failed book (default: continue processing)",
    )

    if include_menu_flag:
        parser.add_argument(
            "--menu",
            action="store_true",
            help="Use interactive menu instead of CLI defaults",
        )

    # Configure tab completion (argcomplete adds 'completer' attribute dynamically)
    if FilesCompleter is not None:
        input_arg.completer = FilesCompleter(allowednames=(".epub", ".pdf"))  # type: ignore

    if ChoicesCompleter is not None:
        engine_arg.completer = ChoicesCompleter(engine_arg.choices)  # type: ignore

    def _parse_leading_number(raw_index: str) -> Optional[int]:
        try:
            return int(raw_index.split()[0])
        except (ValueError, IndexError):
            return None

    return parser


def create_argument_parser() -> "argparse.ArgumentParser":
    """Create command line argument parser."""

    parser = argparse.ArgumentParser(
        description="EBook to Audiobook Converter",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.set_defaults(command="convert")

    subparsers = parser.add_subparsers(dest="command", metavar="command")

    convert_parser = subparsers.add_parser(
        "convert",
        help="Convert ebook to audiobook",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    _add_conversion_arguments(convert_parser, include_menu_flag=True)
    convert_parser.set_defaults(command="convert", menu=False)

    menu_parser = subparsers.add_parser(
        "menu",
        help="Launch interactive menu",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    _add_conversion_arguments(menu_parser, include_menu_flag=False)
    menu_parser.set_defaults(command="menu", menu=True)

    # **NEW**: Clear cache subcommand for global cache cleanup
    cache_parser = subparsers.add_parser(
        "clear-cache",
        help="Clear cached ebook data. With a book file: removes only that book. Without: removes all (with confirmation).",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    cache_parser.add_argument(
        "book",
        nargs="?",
        default=None,
        help="EPUB/PDF file whose cache and output should be removed (optional; omit to clear all)",
    )
    cache_parser.set_defaults(command="clear_cache")

    return parser


def main() -> int:
    """Application entry point"""
    parser = create_argument_parser()

    if argcomplete is not None:
        argcomplete.autocomplete(parser)  # Enables shell tab completion when available

    argv = sys.argv[1:]
    if not argv:
        parser.print_help()
        return 0

    args = parser.parse_args(argv)
    _apply_overnight_preset(args)

    # Handle --no-validate flag to disable all validations
    if getattr(args, "no_validate", False):
        args.validate_text = False
        args.validate_audio = False

    if not hasattr(args, "chapters"):
        args.chapters = []
    if not hasattr(args, "sections"):
        args.sections = []
    if not hasattr(args, "extra_inputs"):
        args.extra_inputs = []
    if not hasattr(args, "batch_inputs") or args.batch_inputs is None:
        args.batch_inputs = []
    if not hasattr(args, "batch_manifest"):
        args.batch_manifest = None
    if not hasattr(args, "batch_stop_on_error"):
        args.batch_stop_on_error = False

    app = ConverterApplication(ui_language=getattr(args, "ui_language", None))
    return app.run(args)


if __name__ == "__main__":
    sys.exit(main())
