# -*- coding: utf-8 -*-
"""Output file, ID3 tagging, audio validation, and chapter naming helpers for AudioConverter."""

from __future__ import annotations

import difflib
import re
import unicodedata
from pathlib import Path
from typing import Dict, List, Optional, Set

from ._output_file_helpers import (
    coerce_chapter_index as _coerce_chapter_index_helper,
)
from .config import ConversionConfig
from .ebook_reader import Chapter
from .output_audio_integrity import OutputAudioIntegrity
from .output_metadata import OutputMetadata
from .output_text_integrity import OutputTextIntegrity


class _OutputFileMixin(OutputTextIntegrity, OutputAudioIntegrity, OutputMetadata):

    @staticmethod
    def _cleanup_duplicate_files(directory: Path, verbose: bool = False) -> int:
        """Remove duplicate files with (dup-N) suffix from directory and subdirectories.

        Args:
            directory: Root directory to scan for duplicates
            verbose: Print cleanup information

        Returns:
            Number of duplicate files removed
        """
        if not directory.exists():
            return 0

        # Pattern to match files like "filename (dup-1).mp3", "filename (dup-2).mp3", etc.
        dup_pattern = re.compile(r"^(.+)\s+\(dup-\d+\)(\.\w+)$")
        removed_count = 0

        # Recursively scan directory
        for file_path in directory.rglob("*"):
            if not file_path.is_file():
                continue

            match = dup_pattern.match(file_path.name)
            if match:
                try:
                    file_path.unlink()
                    removed_count += 1
                    if verbose:
                        print(f"   🗑️ Removed duplicate: {file_path.name}")
                except OSError as e:
                    if verbose:
                        print(f"   ⚠️ Could not remove {file_path.name}: {e}")

        if removed_count > 0 and verbose:
            print(f"✓ Cleaned up {removed_count} duplicate file(s)")

        return removed_count

    @staticmethod
    def _coerce_chapter_index(raw: object, fallback: int) -> int:
        return _coerce_chapter_index_helper(raw, fallback)


    def _chapter_number(self, chapter: Chapter, fallback: int) -> int:
        return self._coerce_chapter_index(getattr(chapter, "index", None), fallback)

    @staticmethod
    def _chapter_index_label(chapter: Chapter, fallback: int) -> str:
        raw = getattr(chapter, "index", None)
        if isinstance(raw, str):
            value = raw.strip()
            return value or str(fallback)
        if raw is None:
            return str(fallback)
        try:
            return str(raw)
        except Exception:
            return str(fallback)

    @staticmethod
    def _remove_duplicate_chapter_prefix(chapter_label: str, chapter_name: str) -> str:
        """
        Remove duplicate numeric prefix from chapter name if it matches the label.

        Example:
        - label="4.5", name="4.5 - Parte 1" -> "Parte 1"
        - label="4.5", name="4.5 Parte 1" -> "Parte 1"
        - label="4.5", name="Parte 1" -> "Parte 1" (no change)

        Returns:
            Chapter name without duplicate prefix
        """
        chapter_name_clean = chapter_name.strip()
        label_str = str(chapter_label).strip()

        # Check if chapter_name starts with the label
        if chapter_name_clean.startswith(label_str):
            # Try to remove "4.5 - " format
            if chapter_name_clean.startswith(f"{label_str} - "):
                return chapter_name_clean[len(label_str) + 3 :].strip()
            # Try to remove "4.5 " format (space only)
            elif (
                len(chapter_name_clean) > len(label_str)
                and chapter_name_clean[len(label_str)] == " "
            ):
                return chapter_name_clean[len(label_str) :].strip()

        return chapter_name_clean

    def _expected_output_path(self, chapter: Chapter, chapter_num: int, directory: Path) -> Path:
        chapter_name = getattr(chapter, "name", None) or f"Chapter {chapter_num}"
        # Get chapter label to remove duplicate prefix
        chapter_label = self._chapter_index_label(chapter, chapter_num)
        chapter_name_clean = self._remove_duplicate_chapter_prefix(chapter_label, chapter_name)
        # Always prefix with the real TOC/index label (e.g. "5.5") to avoid
        # collisions like multiple files named "005 - ...".
        if chapter_name_clean.startswith(f"{chapter_label} - "):
            chapter_name_with_label = chapter_name_clean
        else:
            chapter_name_with_label = f"{chapter_label} - {chapter_name_clean}"
        filename = self.file_manager.build_output_filename(chapter_name_with_label, chapter_num)
        return Path(directory) / filename

    def _normalize_title_match(self, title: str) -> str:
        safe = self.file_manager.sanitize_filename(title)
        normalized = safe.replace("_", " ")
        normalized = unicodedata.normalize("NFKD", normalized)
        normalized = "".join(ch for ch in normalized if not unicodedata.combining(ch))
        normalized = re.sub(r"\s+", " ", normalized).strip().lower()
        return normalized

    def _build_title_index(self, directory: Path) -> Dict[str, List[Path]]:
        index: Dict[str, List[Path]] = {}
        dir_path = Path(directory)
        if not dir_path.exists():
            return index
        for candidate in dir_path.glob("*.mp3"):
            match = self._NUMBERED_FILENAME_RE.match(candidate.stem)
            if not match:
                continue
            key = self._normalize_title_match(match.group(2))
            if not key:
                continue
            index.setdefault(key, []).append(candidate)
        return index

    def _resolve_misnumbered_audio(
        self,
        chapter: Chapter,
        chapter_num: int,
        directory: Path,
        title_index: Dict[str, List[Path]],
    ) -> Optional[Path]:
        expected = self._expected_output_path(chapter, chapter_num, directory)
        if expected.exists():
            return expected
        chapter_name = getattr(chapter, "name", None) or f"Chapter {chapter_num}"
        chapter_label = self._chapter_index_label(chapter, chapter_num)
        chapter_name_clean = self._remove_duplicate_chapter_prefix(chapter_label, chapter_name)
        key = self._normalize_title_match(chapter_name_clean)
        candidates = title_index.get(key) or []
        if not candidates:
            return None
        if len(candidates) == 1:
            candidate = candidates[0]
            candidates = []
        else:

            def _candidate_key(path: Path) -> tuple[int, float, str]:
                try:
                    size = path.stat().st_size
                except OSError:
                    size = 0
                try:
                    mtime = path.stat().st_mtime
                except OSError:
                    mtime = 0.0
                return (size, mtime, path.name)

            candidates_sorted = sorted(candidates, key=_candidate_key, reverse=True)
            candidate = candidates_sorted[0]
            candidates = candidates_sorted[1:]
        if not candidate.exists():
            return None
        if expected.exists():
            return expected
        try:
            candidate.rename(expected)
            title_index[key] = []
            if candidates:
                for idx, leftover in enumerate(candidates, start=1):
                    if not leftover.exists():
                        continue
                    dup_name = f"{expected.stem} (dup-{idx}).mp3"
                    dup_path = expected.with_name(dup_name)
                    try:
                        leftover.rename(dup_path)
                    except OSError:
                        if self.verbose:
                            print(f"⚠️ Failed to move duplicate: {leftover.name} → {dup_name}")
            return expected
        except OSError:
            if self.verbose:
                print(f"⚠️ Failed to rename cache: {candidate.name} → {expected.name}")
            return candidate

    def _normalize_output_numbers(
        self,
        chapters: List[Chapter],
        output_dir: Path,
        config: ConversionConfig,
        *,
        temp_dir: Optional[Path] = None,
    ) -> List[Path]:
        output_index = self._build_title_index(output_dir)
        for idx, chapter in enumerate(chapters, start=1):
            chapter_num = self._chapter_number(chapter, idx)
            self._resolve_misnumbered_audio(chapter, chapter_num, output_dir, output_index)

        if temp_dir:
            temp_index = self._build_title_index(temp_dir)
            for idx, chapter in enumerate(chapters, start=1):
                chapter_num = self._chapter_number(chapter, idx)
                self._resolve_misnumbered_audio(chapter, chapter_num, temp_dir, temp_index)

        cache_root = getattr(config, "cache_dir", None)
        if cache_root:
            cache_dir = Path(cache_root)
            audio_dir = cache_dir / "audio"
            model_bucket = self._cache_model_bucket(config)
            if model_bucket:
                audio_dir = audio_dir / model_bucket
            audio_index = self._build_title_index(audio_dir)
            for idx, chapter in enumerate(chapters, start=1):
                chapter_num = self._chapter_number(chapter, idx)
                self._resolve_misnumbered_audio(chapter, chapter_num, audio_dir, audio_index)

        normalized_outputs: List[Path] = []
        expected_names: set[str] = set()
        for idx, chapter in enumerate(chapters, start=1):
            chapter_num = self._chapter_number(chapter, idx)
            expected = self._expected_output_path(chapter, chapter_num, output_dir)
            expected_names.add(expected.name)
            if expected.exists():
                normalized_outputs.append(expected)

        # Extra repair pass: use generated pre-tts labels (which preserve TOC indices
        # like "5.5", "7.2", etc.) to fix legacy/misnumbered files even when fully cached.
        text_dirs: List[Path] = []
        candidate_text = output_dir / "text"
        if candidate_text.exists():
            text_dirs.append(candidate_text)
        if temp_dir:
            temp_text = Path(temp_dir) / "text"
            if temp_text.exists():
                text_dirs.append(temp_text)
        self._repair_output_names_from_text_cache(output_dir, text_dirs, expected_names)

        # Re-scan after repair
        normalized_outputs = []
        expected_names = set()
        for idx, chapter in enumerate(chapters, start=1):
            chapter_num = self._chapter_number(chapter, idx)
            expected = self._expected_output_path(chapter, chapter_num, output_dir)
            expected_names.add(expected.name)
            if expected.exists():
                normalized_outputs.append(expected)

        # Remove stale MP3s whose names don't match any expected filename
        self._remove_stale_numbered_files(output_dir, "*.mp3", expected_names)
        if temp_dir:
            self._remove_stale_numbered_files(temp_dir, "*.mp3", expected_names)

        # Clean stale cache text files
        self._cleanup_stale_cache_text(chapters, config)

        return normalized_outputs

    def _repair_output_names_from_text_cache(
        self,
        output_dir: Path,
        text_dirs: List[Path],
        expected_names: set[str],
    ) -> None:
        if not output_dir.exists() or not text_dirs:
            return

        def _text_label_entries() -> List[tuple[str, str]]:
            entries: List[tuple[str, str]] = []
            seen: Set[str] = set()
            for text_dir in text_dirs:
                if not text_dir.exists():
                    continue
                for pre_tts in sorted(text_dir.glob("*-pre-tts.txt")):
                    stem = pre_tts.name[: -len("-pre-tts.txt")]
                    m = re.match(r"^(\d+(?:\.\d+)?)\s*-\s*(.+)$", stem)
                    if not m:
                        continue
                    label = (m.group(1) or "").strip()
                    title = (m.group(2) or "").strip()
                    if not label or not title:
                        continue
                    key = f"{label}::{title}".lower()
                    if key in seen:
                        continue
                    seen.add(key)
                    entries.append((label, title))
            return entries

        def _norm_title(value: str) -> str:
            text = self._normalize_title_match(value or "")
            text = re.sub(r"^\d+(?:[.,]\d+)?\s*-\s*", "", text).strip()
            return text

        labels = _text_label_entries()
        if not labels:
            return

        # Build candidate pool once
        candidates = [p for p in sorted(output_dir.glob("*.mp3")) if p.name not in expected_names]
        if not candidates:
            return

        used: Set[Path] = set()
        repaired = 0
        for label, title in labels:
            safe_name = self.file_manager.sanitize_filename(f"{label} - {title}")
            target = output_dir / f"{safe_name}.mp3"
            if target.exists():
                continue

            title_norm = _norm_title(title)
            best_path: Optional[Path] = None
            best_score = 0.0
            for candidate in candidates:
                if candidate in used or not candidate.exists():
                    continue
                cand_norm = _norm_title(candidate.stem)
                score = difflib.SequenceMatcher(None, title_norm, cand_norm).ratio()
                if score > best_score:
                    best_score = score
                    best_path = candidate

            # Conservative threshold to avoid bad renames
            if not best_path or best_score < 0.55:
                continue

            try:
                best_path.rename(target)
                used.add(best_path)
                repaired += 1
            except OSError:
                continue

        if repaired and self.verbose:
            print(f"🔧 Name repair from text cache: {repaired} file(s) renamed")

    def _remove_stale_numbered_files(
        self, directory: Path, glob_pattern: str, expected_names: set[str]
    ) -> None:
        """Remove numbered files whose name doesn't match any expected filename.

        Only removes a file if another file with the **same title** (after stripping
        the numeric prefix) exists in the expected set — i.e. it's a stale duplicate
        from a previous numbering scheme.
        """
        if not directory.exists():
            return

        # Build a mapping from normalized title -> expected filename
        expected_titles: dict[str, str] = {}
        for name in expected_names:
            m = self._NUMBERED_FILENAME_RE.match(Path(name).stem)
            if m:
                title_key = self._normalize_title_match(m.group(2))
                expected_titles[title_key] = name

        removed = 0
        for f in directory.glob(glob_pattern):
            if f.name in expected_names:
                continue
            m = self._NUMBERED_FILENAME_RE.match(f.stem)
            if not m:
                continue
            title_key = self._normalize_title_match(m.group(2))
            # Only remove if the same title exists under the expected naming
            if title_key in expected_titles:
                try:
                    f.unlink()
                    removed += 1
                    if self.verbose:
                        print(f"   🧹 Removed stale file: {f.name}")
                except OSError:
                    pass
        if removed and not self.verbose:
            print(f"  🧹 Removed {removed} stale file(s) from {directory.name}/")

    def _cleanup_stale_cache_text(self, chapters: List[Chapter], config: ConversionConfig) -> None:
        """Remove cache text files whose title duplicates an expected file but
        with a different numeric prefix (stale from a previous numbering scheme)."""
        cache_root = getattr(config, "cache_dir", None)
        if not cache_root:
            try:
                if self._current_book_path:
                    cache_root = self.cache_manager._get_cache_path(self._current_book_path)
            except Exception:
                return
        if not cache_root:
            return

        # Build expected text filenames
        expected_prefixes: set[str] = set()
        for idx, chapter in enumerate(chapters, start=1):
            chapter_label = self._chapter_index_label(chapter, idx)
            chapter_name = getattr(chapter, "name", None) or f"Chapter {chapter_label}"
            chapter_name_clean = self._remove_duplicate_chapter_prefix(chapter_label, chapter_name)
            safe_name = self.file_manager.sanitize_filename(chapter_name_clean)
            prefix = f"{chapter_label} - {safe_name}"
            expected_prefixes.add(prefix)

        # Build title index from expected prefixes
        expected_titles: set[str] = set()
        for prefix in expected_prefixes:
            m = self._NUMBERED_FILENAME_RE.match(prefix)
            if m:
                expected_titles.add(self._normalize_title_match(m.group(2)))

        # Check engine-specific text dirs under cache
        for engine_dir in Path(cache_root).iterdir():
            if not engine_dir.is_dir():
                continue
            text_dir = engine_dir / "text" if (engine_dir / "text").exists() else None
            if engine_dir.name == "text":
                text_dir = engine_dir
            if not text_dir or not text_dir.exists():
                continue
            removed = 0
            for txt_file in list(text_dir.glob("*.txt")):
                # Check if file matches expected prefix
                if any(txt_file.name.startswith(p) for p in expected_prefixes):
                    continue
                # Extract title from numbered file
                # Strip suffix like "-parsed.txt" or "-pre-tts.txt" first
                base = txt_file.name
                for suffix in ("-parsed.txt", "-pre-tts.txt"):
                    if base.endswith(suffix):
                        base = base[: -len(suffix)]
                        break
                m = self._NUMBERED_FILENAME_RE.match(base)
                if not m:
                    continue
                title_key = self._normalize_title_match(m.group(2))
                if title_key in expected_titles:
                    try:
                        txt_file.unlink()
                        removed += 1
                        if self.verbose:
                            print(f"   🧹 Removed stale cache text: {txt_file.name}")
                    except OSError:
                        pass
            if removed and not self.verbose:
                print(f"  🧹 Removed {removed} stale cache text file(s)")
