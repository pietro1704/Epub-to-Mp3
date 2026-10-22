# -*- coding: utf-8 -*-
"""Audio and text cache management helpers for AudioConverter."""

from __future__ import annotations

import contextlib
import re
import shutil
from collections import OrderedDict
from pathlib import Path
from typing import List, Optional, Tuple

from ._cache_helpers import hash_text
from .cache_artifact_persistence import CacheArtifactPersistence
from .config import ConversionConfig
from .ebook_reader import Chapter
from .utils import TextValidator

# Session-local LRU for pre-tts / cached chapter text reads. Keyed by
# (absolute path, mtime_ns) so a file rewritten on disk invalidates the entry
# automatically. Small bound — 64 entries ≈ one medium book's worth of
# chapters and keeps memory pressure negligible.
_CHAPTER_TEXT_LRU_MAX = 64
_chapter_text_lru: "OrderedDict[Tuple[str, int], str]" = OrderedDict()


def _read_chapter_text_cached(path: Path) -> str:
    """Read a chapter text file with an LRU, invalidated on file mtime change."""
    resolved = str(path)
    try:
        mtime_ns = path.stat().st_mtime_ns
    except OSError:
        return path.read_text(encoding="utf-8")
    key = (resolved, mtime_ns)
    hit = _chapter_text_lru.get(key)
    if hit is not None:
        _chapter_text_lru.move_to_end(key)
        return hit
    text = path.read_text(encoding="utf-8")
    _chapter_text_lru[key] = text
    while len(_chapter_text_lru) > _CHAPTER_TEXT_LRU_MAX:
        _chapter_text_lru.popitem(last=False)
    return text


class _CacheMixin(CacheArtifactPersistence):
    def _load_cached_payload(
        self,
        chapter: Chapter,
        index: int,
        temp_dir: Path,
    ) -> Optional[str]:
        try:
            index_label = self._chapter_index_label(chapter, index)
            pre_tts_path = self._find_pre_tts_path(
                cache_dir=None,
                output_dir=Path(temp_dir),
                index=index,
                chapter_name=getattr(chapter, "name", None),
                index_label=index_label,
            )
            if pre_tts_path and pre_tts_path.exists():
                return _read_chapter_text_cached(pre_tts_path)
        except OSError:
            pass
        return None

    def _resolve_pre_tts_payload(
        self,
        chapter: Chapter,
        index: int,
        output_dir: Optional[Path],
        config: Optional[ConversionConfig],
    ) -> tuple[str, Optional[Path], bool]:
        """Return payload text, its pre-tts path (if any), and whether payload is locked to file."""
        index_label = self._chapter_index_label(chapter, index)
        pre_tts_path = self._find_pre_tts_path(
            cache_dir=getattr(config, "cache_dir", None) if config else None,
            output_dir=output_dir,
            index=index,
            chapter_name=getattr(chapter, "name", None),
            index_label=index_label,
        )
        if pre_tts_path and pre_tts_path.exists():
            try:
                return _read_chapter_text_cached(pre_tts_path), pre_tts_path, True
            except OSError:
                pass
        return (self._speech_text(chapter) or ""), pre_tts_path, False

    def _prepare_chapter_payload(
        self,
        chapter: Chapter,
        index: int,
        output_dir: Optional[Path],
        config: Optional[ConversionConfig],
        *,
        cleanup_existing: bool = False,
    ) -> tuple[str, Optional[Path], bool]:
        """Prepare one chapter exactly once and return its explicit payload handoff."""
        payload = self._resolve_pre_tts_payload(chapter, index, output_dir, config)
        if payload[2]:
            return payload
        generate_all_text_files = getattr(self, "_generate_all_text_files")
        generate_all_text_files(
            [chapter],
            output_dir,
            config,
            cleanup_existing=cleanup_existing,
        )
        return self._resolve_pre_tts_payload(chapter, index, output_dir, config)

    def _prepare_truncation_retry_payload(
        self,
        chapter: Chapter,
        canonical_label: str,
        attempts_so_far: int,
        chapter_index: Optional[int] = None,
        output_dir: Optional[Path] = None,
        cache_dir: Optional[Path] = None,
    ) -> None:
        """Simplify chapter payload before a retry after truncated audio detection."""
        try:
            fallback_index = chapter_index or attempts_so_far
            index_label = self._chapter_index_label(chapter, fallback_index)
            pre_tts_path = self._find_pre_tts_path(
                cache_dir=cache_dir,
                output_dir=output_dir,
                index=self._chapter_number(chapter, fallback_index),
                chapter_name=getattr(chapter, "name", None),
                index_label=index_label,
            )
            if pre_tts_path and pre_tts_path.exists():
                # Keep payload locked to pre-tts text to avoid mismatches.
                return
        except Exception:
            pass
        baseline = self._retry_original_texts.get(canonical_label)
        if baseline is None:
            baseline = self._speech_text(chapter)
            self._retry_original_texts[canonical_label] = baseline

        updated_text: Optional[str] = None
        try:
            from ..language import LanguageMarkup
        except ImportError:
            LanguageMarkup = None  # type: ignore

        if attempts_so_far <= 1:
            if LanguageMarkup:
                stripped = LanguageMarkup.strip(baseline)  # type: ignore[attr-defined]
                if stripped and stripped.strip() and stripped != self._speech_text(chapter):
                    updated_text = stripped
        elif attempts_so_far == 2:
            stripped = LanguageMarkup.strip(baseline) if LanguageMarkup else baseline  # type: ignore[attr-defined]
            cleaned = re.sub(r"\[\[fmt:[^\]]+\]\]|\[\[/fmt\]\]", "", stripped or "")
            updated_text = cleaned.strip()
            chapter.formatting_segments = None
        else:
            stripped = LanguageMarkup.strip(baseline) if LanguageMarkup else baseline  # type: ignore[attr-defined]
            cleaned = re.sub(r"\[\[fmt:[^\]]+\]\]|\[\[/fmt\]\]", "", stripped or "")
            updated_text = cleaned.strip()
            chapter.formatting_segments = None

        if updated_text and updated_text != self._speech_text(chapter):
            chapter.speech_text = updated_text

    @staticmethod
    def _hash_text(value: str) -> str:
        return hash_text(value)


    def _collect_cached_audio(
        self,
        chapters: List[Chapter],
        output_dir: Path,
        config: ConversionConfig,
        allow_index_only: bool = False,
    ) -> Optional[List[Path]]:
        """
        If every chapter already has a valid MP3 (temp or final), return the list to skip synthesis.
        Otherwise, return None to proceed normally.
        """
        final_output_dir = self._setup_output_directory(config)
        cache_dir = getattr(config, "cache_dir", None)
        cache_index = self._load_cache_index(cache_dir)
        cached_paths: List[Path] = []
        for idx, chapter in enumerate(chapters, start=1):
            chapter_num = self._chapter_number(chapter, idx)
            temp_mp3 = self._expected_output_path(chapter, chapter_num, output_dir)
            final_mp3 = final_output_dir / temp_mp3.name
            candidate = temp_mp3 if temp_mp3.exists() else final_mp3
            if not candidate.exists() and cache_dir:
                cached_audio = self._find_cached_audio_path(
                    cache_dir, config, getattr(chapter, "name", None) or "", chapter_num
                )
                if cached_audio:
                    try:
                        final_mp3.parent.mkdir(parents=True, exist_ok=True)
                        if not final_mp3.exists():
                            shutil.copy2(cached_audio, final_mp3)
                        candidate = final_mp3
                    except Exception:
                        candidate = cached_audio
            try:
                size = candidate.stat().st_size if candidate.exists() else 0
            except OSError:
                size = 0
            if size <= 1000:
                return None

            index_label = self._chapter_index_label(chapter, idx)
            pre_tts_path = self._find_pre_tts_path(
                cache_dir,
                output_dir,
                chapter_num,
                getattr(chapter, "name", None),
                index_label=index_label,
            )
            pre_tts_hash = None
            if pre_tts_path and pre_tts_path.exists():
                with contextlib.suppress(Exception):
                    pre_tts_hash = self._hash_text(pre_tts_path.read_text(encoding="utf-8"))
            cache_key = index_label
            entry = cache_index.get(cache_key) or cache_index.get(str(chapter_num)) or {}
            entry_hash = entry.get("pre_tts_hash")
            hash_ok = pre_tts_hash and entry_hash == pre_tts_hash
            hash_missing = pre_tts_hash and not entry_hash
            duration_ok = True
            try:
                bitrate_bps = self._bitrate_to_bps(getattr(config, "bitrate", "8k")) or 8000
                approx_seconds = (size * 8) / max(bitrate_bps, 1)
                estimated_text = ""
                if pre_tts_path and pre_tts_path.exists():
                    estimated_text = pre_tts_path.read_text(encoding="utf-8")
                expected_seconds = TextValidator.estimate_duration(estimated_text)
                if expected_seconds > 0:
                    duration_ok = approx_seconds >= expected_seconds * 0.5
            except Exception:
                duration_ok = True

            if pre_tts_hash and duration_ok and (hash_ok or hash_missing):
                if hash_missing and cache_dir:
                    entry["path"] = str(candidate)
                    entry["size"] = size
                    entry["pre_tts_hash"] = pre_tts_hash
                    cache_index[cache_key] = entry
                    self._save_cache_index(cache_dir, cache_index)
                cached_paths.append(candidate)
                continue

            # Allow cache_index-only validation when explicitly requested
            if not pre_tts_path and allow_index_only:
                if entry_hash and size > 1000:
                    cached_paths.append(candidate)
                    continue

            return None

        return cached_paths

    def _split_cached_chapters(
        self,
        chapters: List[Chapter],
        output_dir: Path,
        config: ConversionConfig,
        *,
        allow_index_only: bool = False,
    ) -> tuple[List[Path], List[Chapter]]:
        """Return cached audio paths and pending chapters (partial cache-aware)."""
        final_output_dir = self._setup_output_directory(config)
        cache_dir = getattr(config, "cache_dir", None)
        cache_index = self._load_cache_index(cache_dir)
        cached_paths: List[Path] = []
        pending: List[Chapter] = []
        ignore_cached_audio = bool(
            getattr(config, "force_reprocess", False) or getattr(config, "clear_cache", False)
        )

        for idx, chapter in enumerate(chapters, start=1):
            if ignore_cached_audio:
                pending.append(chapter)
                continue
            chapter_num = self._chapter_number(chapter, idx)
            temp_mp3 = self._expected_output_path(chapter, chapter_num, output_dir)
            final_mp3 = final_output_dir / temp_mp3.name
            candidate: Optional[Path] = temp_mp3 if temp_mp3.exists() else None

            if candidate is None and final_mp3.exists():
                candidate = final_mp3

            # Discovery fallback: scan the final output directory for any
            # MP3 whose stem starts with this chapter's index label. The
            # filename truncate / sanitisation rules used by older runs
            # may have produced a slightly different name (different
            # truncate length, different EPUB metadata title casing) but
            # the index prefix `7.13 - ` is stable across all of them.
            # Without this, two runs that disagree on title casing
            # produced two parallel sets of MP3s — observed in the
            # 2026-04-29 Carl conversion that prompted this code path.
            if candidate is None and final_output_dir.exists():
                index_label = self._chapter_index_label(chapter, idx)
                prefix = f"{index_label} - "
                lowered_prefix = prefix.lower()
                for existing in final_output_dir.glob("*.mp3"):
                    if existing.name.lower().startswith(lowered_prefix):
                        try:
                            if existing.stat().st_size > 1000:
                                candidate = existing
                                break
                        except OSError:
                            continue

            if candidate is None and cache_dir:
                cached_audio = self._find_cached_audio_path(
                    cache_dir, config, getattr(chapter, "name", None) or "", chapter_num
                )
                if cached_audio:
                    try:
                        final_mp3.parent.mkdir(parents=True, exist_ok=True)
                        if not final_mp3.exists():
                            shutil.copy2(cached_audio, final_mp3)
                        candidate = final_mp3
                    except Exception:
                        candidate = cached_audio

            try:
                size = candidate.stat().st_size if candidate and candidate.exists() else 0
            except OSError:
                size = 0
            if size <= 1000:
                pending.append(chapter)
                continue

            index_label = self._chapter_index_label(chapter, idx)
            pre_tts_path = self._find_pre_tts_path(
                cache_dir,
                output_dir,
                chapter_num,
                getattr(chapter, "name", None),
                index_label=index_label,
            )
            pre_tts_hash = None
            if pre_tts_path and pre_tts_path.exists():
                with contextlib.suppress(Exception):
                    pre_tts_hash = self._hash_text(pre_tts_path.read_text(encoding="utf-8"))
            cache_key = index_label
            entry = cache_index.get(cache_key) or cache_index.get(str(chapter_num)) or {}
            entry_hash = entry.get("pre_tts_hash")
            hash_ok = pre_tts_hash and entry_hash == pre_tts_hash
            hash_missing = pre_tts_hash and not entry_hash
            duration_ok = True
            try:
                bitrate_bps = self._bitrate_to_bps(getattr(config, "bitrate", "8k")) or 8000
                approx_seconds = (size * 8) / max(bitrate_bps, 1)
                estimated_text = ""
                if pre_tts_path and pre_tts_path.exists():
                    estimated_text = pre_tts_path.read_text(encoding="utf-8")
                expected_seconds = TextValidator.estimate_duration(estimated_text)
                if expected_seconds > 0:
                    duration_ok = approx_seconds >= expected_seconds * 0.5
            except Exception:
                duration_ok = True

            cached_ok = False
            if pre_tts_hash and duration_ok and (hash_ok or hash_missing):
                cached_ok = True
                if hash_missing and cache_dir:
                    entry["path"] = str(candidate)
                    entry["size"] = size
                    entry["pre_tts_hash"] = pre_tts_hash
                    cache_index[cache_key] = entry
                    self._save_cache_index(cache_dir, cache_index)
            elif allow_index_only and entry_hash and size > 1000:
                cached_ok = True
            elif pre_tts_path is None and size > 1000 and duration_ok:
                # No pre-tts.txt available (older runs cleaned them up
                # post-conversion, or the MP3 was found via the
                # index-prefix scan rather than the canonical name).
                # The downstream `_detect_short_audio_output` check
                # already rejects audibly-short audio, so accept the
                # cache when we have a non-trivial MP3 that was
                # discovered for this chapter index. Without this branch,
                # any second run after a successful conversion that
                # cleared the txt sidecars would re-synthesise every
                # chapter from scratch — exactly the 2026-04-29 Carl bug.
                cached_ok = True

            if cached_ok and candidate is not None and candidate.exists():
                if pre_tts_path and pre_tts_path.exists():
                    cached_payload = self._load_cached_payload(chapter, chapter_num, output_dir)
                    if cached_payload:
                        truncation_warning = self._detect_short_audio_output(
                            candidate,
                            cached_payload,
                            config,
                            engine_label=(config.engine or "").lower(),
                        )
                        if truncation_warning:
                            cached_ok = False
                if cached_ok:
                    cached_paths.append(candidate)
                else:
                    pending.append(chapter)
            else:
                pending.append(chapter)

        return cached_paths, pending

    @staticmethod
    def _assign_progress_indices(chapters: List[Chapter]) -> None:
        """Attach a stable progress index used for UI/percentage counters."""
        for idx, chapter in enumerate(chapters, start=1):
            try:
                setattr(chapter, "_progress_index", idx)
            except Exception:
                pass
