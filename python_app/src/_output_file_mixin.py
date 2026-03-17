# -*- coding: utf-8 -*-
"""Output file, ID3 tagging, audio validation, and chapter naming helpers for AudioConverter."""

from __future__ import annotations

import difflib
import re
import subprocess
import unicodedata
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Set

from .config import ConversionConfig
from .ebook_reader import Chapter, EbookReader
from .text_integrity_validator import TextIntegrityValidator
from .utils import TextValidator


class _OutputFileMixin:
    @staticmethod
    def _speech_text(chapter: Chapter) -> str:
        text = getattr(chapter, "speech_text", None)
        if text is None:
            text = chapter.text or ""
        return text

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
        if raw is None:
            return fallback
        try:
            if isinstance(raw, str):
                text = raw.strip()
                if not text:
                    return fallback
                if text.replace(".", "", 1).isdigit():
                    raw = float(text) if "." in text else int(text)
                else:
                    return fallback
            value = int(raw)
        except Exception:
            try:
                value = int(float(raw))  # type: ignore[arg-type]
            except Exception:
                return fallback
        return value if value > 0 else fallback

    @staticmethod
    def _spot_check_text_against_epub(epub_text: str, payload: str) -> bool:
        """Lightweight spot-check: ensure key snippets from EPUB exist in the TTS payload."""
        if not epub_text or not payload:
            return False

        def normalize(val: str) -> str:
            val = re.sub(r"\s+", " ", val or "")
            return val.strip().lower()

        epub_norm = normalize(epub_text)
        payload_norm = normalize(payload)
        if not epub_norm or not payload_norm:
            return False

        # Take first snippet and a middle snippet to detect truncation/duplication.
        first_snippet = epub_norm[:200]
        mid_start = max(len(epub_norm) // 2 - 100, 0)
        mid_snippet = epub_norm[mid_start : mid_start + 200]

        first_ok = first_snippet in payload_norm
        mid_ok = mid_snippet in payload_norm
        return first_ok and mid_ok

    @staticmethod
    def _sample_edges(text: str, size: int = 180) -> tuple[str, str]:
        normalized = re.sub(r"\s+", " ", text or "").strip()
        if len(normalized) <= size * 2:
            return normalized, normalized
        return normalized[:size], normalized[-size:]

    @staticmethod
    def _strip_formatting_cues(text: str) -> str:
        """Remove audible formatting cue phrases from text."""
        if not text:
            return ""
        try:
            from .text_formatting import TextFormattingProcessor

            phrases: set[str] = set()
            for locale_map in TextFormattingProcessor.CUE_LABELS.values():
                for start, end in locale_map.values():
                    phrases.add(start)
                    phrases.add(end)
            phrases.update(TextFormattingProcessor.FOOTNOTE_END_PHRASES)
        except Exception:
            return text

        cleaned = text
        for phrase in sorted(phrases, key=len, reverse=True):
            cleaned = re.sub(re.escape(phrase), "", cleaned, flags=re.IGNORECASE)
        cleaned = re.sub(r"\s+", " ", cleaned).strip()
        return cleaned

    def _validate_text_after_save(
        self,
        chapter: Chapter,
        chapter_label: str,
        parsed_text: str,
        pre_tts_text: str,
        *,
        validator: "TextIntegrityValidator",
        strict: bool,
    ) -> bool:
        """Validate parsed/pre-tts text against EPUB content."""
        issues: List[str] = []
        epub_text = chapter.text or ""
        parsed_norm = validator.normalize_text(parsed_text)
        epub_norm = validator.normalize_text(epub_text)

        if not parsed_norm:
            issues.append("chapter text is empty or not extracted from EPUB")
        if epub_norm:
            diff = len(epub_norm) - len(parsed_norm)
            allowed_diff = max(50, int(len(epub_norm) * 0.05))
            if abs(diff) > allowed_diff:
                issues.append(f"text divergente do EPUB ({diff:+d} chars)")
            start, end = self._sample_edges(epub_norm)
            if start and start not in parsed_norm:
                issues.append("text parsed sem start do EPUB")
            if end and end not in parsed_norm:
                issues.append("text parsed sem final do EPUB")

        if parsed_norm:
            text_hash = validator.calculate_text_hash(parsed_norm)
            if text_hash in self._text_validation_hashes:
                other = self._text_validation_hashes[text_hash]
                # Only flag as duplicate if it's a different chapter
                # (validation may be called multiple times for same chapter during retries)
                if other != chapter_label:
                    issues.append(f"Duplicate content (same as chapter {other})")
            else:
                # Use full chapter label instead of just integer index to avoid false positives
                # for subchapters (4.1, 4.2, etc.) which all have the same integer part
                self._text_validation_hashes[text_hash] = chapter_label

            snippet = parsed_norm[:200]
            if snippet and parsed_norm.count(snippet) > 1:
                issues.append("Possible internal duplication (repeated snippet)")
            if len(parsed_norm) > 400 and parsed_norm[:200] == parsed_norm[-200:]:
                issues.append("Possible internal duplication (start = end)")

        if pre_tts_text and parsed_norm:
            pretts_norm = validator.normalize_text(self._strip_formatting_cues(pre_tts_text))
            # Pre-TTS text may have chapter announcements and formatting cues prepended/appended
            # So we check if substantial portions of the parsed text appear anywhere in pre-TTS
            # rather than checking exact beginning/end positions
            if len(parsed_norm) > 300:
                # Sample from middle sections to avoid chapter announcement additions
                mid_start = len(parsed_norm) // 4
                mid_sample_size = min(200, len(parsed_norm) // 2)
                mid_sample = parsed_norm[mid_start : mid_start + mid_sample_size]

                # Check if middle portion exists in pre-TTS (more reliable than start/end)
                if mid_sample and mid_sample not in pretts_norm:
                    # Length check: pre-TTS should be similar length to parsed (within 20%)
                    len_ratio = len(pretts_norm) / len(parsed_norm) if len(parsed_norm) > 0 else 0
                    if len_ratio < 0.8 or len_ratio > 1.5:
                        issues.append(
                            f"Pre-TTS tem tamanho muito diferente do parsed ({len_ratio:.1%})"
                        )

        if issues:
            message = f"Post-parsing validation failed ({chapter_label}): {', '.join(issues)}"
            self._text_validation_errors.append(message)
            if self.verbose:
                print(f"❌ {message}")
            if strict:
                raise RuntimeError(message)
            return False

        return True

    def _validate_audio_after_write(
        self,
        text_payload: str,
        output_path: Path,
        *,
        config: ConversionConfig,
    ) -> tuple[bool, Optional[str]]:
        """Validate MP3 integrity and duration after conversion."""
        try:
            from .audio_validator import AudioValidator

            validator = AudioValidator()
            file_is_valid = validator.validate_audio_file(output_path)
            if not file_is_valid:
                return False, "Invalid or corrupted audio"

            normalized_len = len(re.sub(r"\s+", " ", text_payload or "").strip())
            if normalized_len >= 5000:
                # Increased tolerance: Edge-TTS speed varies significantly based on content
                # Portuguese text + formatting cues make duration estimation less accurate
                tolerance = 0.50 if normalized_len < 10000 else 0.40
                duration_result = validator.validate_duration(
                    text_payload, output_path, tolerance=tolerance
                )
                if not duration_result.is_valid:
                    # Log warning but don't fail - file exists and is playable
                    if self.verbose:
                        print(f"⚠️ Duration check: {duration_result.message}")
                    # Don't fail conversion due to duration mismatch alone
                    # return False, duration_result.message or "Invalid duration"

            return True, None
        except Exception as exc:
            if self.verbose:
                print(f"⚠️ Audio validation failed with error: {exc}")
            return True, None

    def _edge_segment_integrity_ok(self, tts_engine: object) -> tuple[bool, Optional[str]]:
        """Ensure Edge produced all segments (100% completeness)."""
        report = getattr(tts_engine, "last_segment_report", None)
        expected = 0
        generated = 0
        failed = 0
        if isinstance(report, dict):
            try:
                expected = int(report.get("expected") or 0)
                generated = int(report.get("generated") or 0)
                failed = int(report.get("failed") or 0)
            except (TypeError, ValueError):
                expected = 0
                generated = 0
                failed = 0

        tracker_missing = 0
        if hasattr(tts_engine, "get_synthesis_tracker"):
            tracker = tts_engine.get_synthesis_tracker()
            if tracker:
                try:
                    tracker_missing = len(tracker.get_missing_segments() or [])
                except Exception:
                    tracker_missing = 0

        if getattr(tts_engine, "partial_failure_detected", False):
            return False, "Partial failure detected in Edge synthesis"

        if failed > 0 or tracker_missing > 0:
            total_failed = failed if failed > 0 else tracker_missing
            if expected and generated:
                return (
                    False,
                    f"Missing segments: {generated}/{expected} (failed {total_failed})",
                )
            return False, f"Missing segments: {total_failed}"

        if expected and generated and expected != generated:
            return False, f"Incomplete segments: {generated}/{expected}"

        return True, None

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

    def _extract_cover_art(self, reader: EbookReader) -> Optional[dict]:
        extractor = getattr(reader, "extract_cover_image", None)
        if callable(extractor):
            try:
                cover = extractor()
            except Exception:
                cover = None
            if cover and getattr(cover, "data", None):
                return {
                    "data": cover.data,
                    "mime": getattr(cover, "media_type", "image/jpeg") or "image/jpeg",
                }
        return None

    def _embed_id3_metadata(
        self,
        mp3_path: Path,
        *,
        title: str,
        album: Optional[str],
        artist: Optional[str],
        cover_art: Optional[dict],
    ) -> None:
        try:
            from mutagen.id3 import APIC, ID3, TALB, TIT2, TPE1
            from mutagen.mp3 import MP3

            audio = MP3(mp3_path, ID3=ID3)
            if audio.tags is None:
                audio.add_tags()
        except Exception:
            return

        try:
            audio.tags.delall("TIT2")
            audio.tags.delall("TALB")
            audio.tags.delall("TPE1")
            audio.tags.delall("APIC")
        except Exception:
            pass

        try:
            audio.tags["TIT2"] = TIT2(encoding=3, text=title or mp3_path.name)
            if album:
                audio.tags["TALB"] = TALB(encoding=3, text=album)
            if artist:
                audio.tags["TPE1"] = TPE1(encoding=3, text=artist)
            if cover_art and cover_art.get("data"):
                mime = cover_art.get("mime") or "image/jpeg"
                try:
                    audio.tags.add(
                        APIC(
                            encoding=3,
                            mime=mime,
                            type=3,
                            desc="Cover",
                            data=cover_art["data"],
                        )
                    )
                except Exception:
                    pass
            audio.save()
        except Exception:
            if self.verbose:
                print(f"   ⚠️ Failure embedding ID3 metadata in {mp3_path.name}")

    @staticmethod
    def _title_from_filename(mp3_path: Path) -> str:
        stem = mp3_path.stem
        candidate = stem
        if " - " in stem:
            parts = stem.split(" - ", 1)
            if len(parts) == 2 and parts[0].isdigit():
                candidate = parts[1]
        else:
            parts = stem.split("_", 1)
            if len(parts) == 2 and parts[0].isdigit():
                candidate = parts[1]
            candidate = candidate.replace("_", " ")
        candidate = candidate.strip()
        return candidate or mp3_path.name

    def _apply_final_id3_tags(
        self,
        files: Iterable[Path],
        *,
        default_album: Optional[str],
        artist: Optional[str],
        cover_art: Optional[dict],
    ) -> None:
        album_fallback = default_album or ""
        for mp3_path in files:
            try:
                path_obj = Path(mp3_path)
            except TypeError:
                continue
            if path_obj.suffix.lower() != ".mp3" or not path_obj.exists():
                continue
            title = self._title_from_filename(path_obj)
            album = album_fallback or path_obj.parent.name
            self._embed_id3_metadata(
                path_obj,
                title=title,
                album=album,
                artist=artist or None,
                cover_art=cover_art,
            )

    @staticmethod
    def _bitrate_to_bps(bitrate: Optional[str]) -> Optional[int]:
        if bitrate is None:
            return None
        text = str(bitrate).strip().lower()
        if not text:
            return None
        multiplier = 1_000 if text.endswith(("kbps", "k")) else 1
        if text.endswith("mbps") or text.endswith("m"):
            multiplier = 1_000_000
        suffixes = ("mbps", "kbps", "bps", "m", "k")
        for suffix in suffixes:
            if text.endswith(suffix):
                text = text[: -len(suffix)]
                break
        text = text.strip()
        if not text:
            return None
        try:
            value = float(text)
        except ValueError:
            return None
        bps = int(value * multiplier)
        return bps if bps > 0 else None

    @classmethod
    def _expected_audio_bytes(
        cls, estimated_seconds: float, bitrate: Optional[str]
    ) -> Optional[int]:
        if estimated_seconds <= 0:
            return None
        bps = cls._bitrate_to_bps(bitrate)
        if not bps:
            return None
        expected = estimated_seconds * (bps / 8.0)
        return int(expected)

    def _probe_audio_duration(self, audio_path: Path) -> Optional[float]:
        try:
            result = subprocess.run(
                [
                    "ffprobe",
                    "-v",
                    "error",
                    "-show_entries",
                    "format=duration",
                    "-of",
                    "default=noprint_wrappers=1:nokey=1",
                    str(audio_path),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            if result.returncode == 0:
                value = result.stdout.strip()
                if value:
                    duration = float(value)
                    if duration > 0:
                        return duration
        except FileNotFoundError:
            pass
        except Exception:
            pass
        return None

    def _detect_short_audio_output(
        self,
        audio_path: Path,
        payload_text: Optional[str],
        config: ConversionConfig,
        engine_label: Optional[str] = None,
    ) -> Optional[str]:
        audio_path = Path(audio_path)
        if not audio_path.exists() or not payload_text:
            return None

        (engine_label or getattr(config, "engine", "") or "").lower()

        try:
            file_size = audio_path.stat().st_size
        except OSError:
            file_size = 0

        stripped = payload_text.strip() if payload_text else ""
        if len(stripped) < 2000:
            return None

        estimated_seconds = TextValidator.estimate_duration(stripped)
        if estimated_seconds < 150:
            return None

        actual_seconds = self._probe_audio_duration(audio_path)
        if actual_seconds and actual_seconds >= estimated_seconds * 0.60:
            return None
        if actual_seconds and actual_seconds >= max(
            estimated_seconds - 90, estimated_seconds * 0.5
        ):
            return None

        expected_bytes = self._expected_audio_bytes(
            estimated_seconds, getattr(config, "bitrate", "8k")
        )
        ratio_warning = False
        approx_seconds = None
        if expected_bytes:
            minimum_expected = max(int(expected_bytes * 0.55), 180_000)
            if file_size < minimum_expected:
                ratio_warning = True
        if not ratio_warning and actual_seconds is None:
            bitrate_bps = self._bitrate_to_bps(getattr(config, "bitrate", "8k")) or 8_000
            approx_seconds_calc = (file_size * 8) / max(bitrate_bps, 1)
            approx_seconds = int(approx_seconds_calc)
            if approx_seconds < estimated_seconds * 0.55:
                ratio_warning = True

        if not ratio_warning and actual_seconds is None:
            return None

        short_seconds = approx_seconds if approx_seconds is not None else int(actual_seconds or 0)
        if actual_seconds is not None:
            short_seconds = int(actual_seconds)

        expected_display = int(estimated_seconds)
        if short_seconds <= 0:
            short_seconds = max(int((file_size or 1) / 1000), 1)

        return f"Audio possibly truncated ({file_size} bytes ≈ {short_seconds}s, expected ≈ {expected_display}s)"
