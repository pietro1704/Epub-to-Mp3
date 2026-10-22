# -*- coding: utf-8 -*-
"""Chapter selection, workload analysis and output paths."""

from __future__ import annotations

from pathlib import Path
from typing import Dict, List, Optional, Set

from .config import ConversionConfig
from .ebook_reader import Chapter


class ConverterChapterSelection:
    """Chapter selection, workload analysis and output paths."""

    def _reset_parallel_state(self, recommended_parallel: int) -> None:
        """Initialise the dynamic parallelism state."""
        from . import converter as _runtime
        target = max(1, int(recommended_parallel or 1))
        self._parallel_state = {
            "ceiling": target,
            "current": target,
            "best_throughput": 0.0,
            "last_throughput": None,
            "degrade_runs": 0,
        }
        with _runtime.contextlib.suppress(Exception):
            # Warm up psutil cpu_percent to avoid 0.0 on first reading
            _runtime.psutil.cpu_percent(interval=None)

    def _estimate_chapter_chars(self, chapter: Chapter) -> int:
        """Estimate the number of characters for a chapter."""
        try:
            text = self._speech_text(chapter)
        except Exception:
            text = getattr(chapter, "text", "") or ""
        return len(text or "")

    def _analyze_chapter_stats(self, chapters: List[Chapter]) -> Dict[str, float]:
        """Return summary statistics used to pick the fastest engine for the book."""
        from . import converter as _runtime
        stats: Dict[str, float] = {
            "count": len(chapters),
            "max_chars": 0,
            "avg_chars": 0,
            "long_ratio": 0.0,
            "total_chars": 0,
            "prefer_offline_engine": False,
        }
        if not chapters:
            return stats

        lengths: List[int] = [max(0, self._estimate_chapter_chars(chapter)) for chapter in chapters]
        total = sum(lengths)
        stats["total_chars"] = total
        stats["max_chars"] = max(lengths) if lengths else 0
        stats["avg_chars"] = total / len(lengths)
        long_threshold = _runtime.EDGE_OFFLINE_LONG_CHARS
        long_count = sum(1 for value in lengths if value >= long_threshold)
        stats["long_ratio"] = long_count / len(lengths)

        # Detect outlier chapters: chapters that are >5× the median size.
        # These are typically footnote-container files that embed the entire book text.
        sorted_lengths = sorted(lengths)
        median_chars = sorted_lengths[len(sorted_lengths) // 2] if sorted_lengths else 0
        outlier_threshold = max(median_chars * 5, 50_000)
        outlier_indices = [i for i, v in enumerate(lengths) if v > outlier_threshold and v > 50_000]
        stats["median_chars"] = float(median_chars)
        stats["outlier_indices"] = outlier_indices  # type: ignore[assignment]
        if outlier_indices:
            outlier_max = max(lengths[i] for i in outlier_indices)
            stats["outlier_max_chars"] = float(outlier_max)
            # Warn the user so they know they can skip this chapter.
            for idx in outlier_indices:
                ch = chapters[idx]
                ch_chars = lengths[idx]
                ratio = ch_chars // max(median_chars, 1)
                (ch_chars // 1000) * 1000  # round down to nearest 1K
                print(
                    f'\n⚠️  Oversized chapter: "{getattr(ch, "name", "?")[:70]}"'
                    f" ({ch_chars:,} chars = {ratio}× median)"
                    f" — conversion will take longer for this chapter"
                )

        prefer_offline = False
        reasons: List[str] = []
        if stats["max_chars"] >= _runtime.EDGE_OFFLINE_LONG_CHARS:
            prefer_offline = True
            reasons.append(f"chapter with ~{stats['max_chars']:,} chars")
        if stats["long_ratio"] >= _runtime.EDGE_OFFLINE_LONG_RATIO:
            prefer_offline = True
            reasons.append(f"{int(stats['long_ratio'] * 100)}% of chapters are too long")
        if stats["total_chars"] >= _runtime.EDGE_OFFLINE_TOTAL_CHARS:
            prefer_offline = True
            reasons.append(f"{stats['total_chars']:,} total chars")
        stats["prefer_offline_engine"] = prefer_offline
        if prefer_offline and reasons:
            stats["offline_reason"] = "; ".join(reasons)
            stats["prefer_piper_engine"] = True
        return stats

    def _apply_chapter_engine_preferences(
        self, config: ConversionConfig, stats: Dict[str, float]
    ) -> None:
        """Report chapter stats without forcing pre-emptive engine switches."""
        if not stats or not stats.get("prefer_offline_engine"):
            return
        reason = stats.get("offline_reason")
        if reason:
            print(f"🎯 Long chapters detected ({reason}) — keeping Edge as first attempt.")

    def _parse_chapter_whitelist(self, config: Optional[ConversionConfig]) -> List[str]:
        if not config or not getattr(config, "extra", None):
            return []
        raw = config.extra.get("chapter_whitelist") or config.extra.get("chapters_only")
        if not raw:
            return []
        if isinstance(raw, (list, tuple, set)):
            items = [str(item).strip() for item in raw]
        else:
            items = [part.strip() for part in str(raw).split(",")]
        return [item for item in items if item]

    @staticmethod
    def _chapter_selector_aliases(value: object) -> Set[str]:
        """Build equivalent selector forms (e.g. 5, 5.0, 005) for resilient matching."""
        from . import converter as _runtime
        text = str(value).strip() if value is not None else ""
        if not text:
            return set()

        aliases: Set[str] = {text}
        numeric_text = text.replace(",", ".")

        try:
            num = float(numeric_text)
            if num.is_integer():
                base = str(int(num))
                aliases.add(base)
                aliases.add(f"{base}.0")
            else:
                aliases.add(str(num))
        except Exception:
            pass

        if _runtime.re.fullmatch(r"\d+", text):
            base = str(int(text))
            aliases.add(base)
            aliases.add(f"{base}.0")

        return {item for item in aliases if item}

    @staticmethod
    def _effective_primary_language(
        config: Optional[ConversionConfig], default: str = "pt-BR"
    ) -> str:
        if config:
            raw_primary = str(getattr(config, "primary_language", "") or "").strip()
            if raw_primary and raw_primary.lower() not in {"auto", "unknown"}:
                return raw_primary
            languages = list(getattr(config, "languages", []) or [])
            for lang in languages:
                candidate = str(lang or "").strip()
                if candidate and candidate.lower() not in {"auto", "unknown"}:
                    return candidate
        return default

    @staticmethod
    def _normalize_title_for_match(raw: str) -> str:
        from . import converter as _runtime
        text = str(raw or "")
        text = text.replace("–", "-").replace("—", "-")
        text = _runtime.unicodedata.normalize("NFD", text)
        text = "".join(ch for ch in text if _runtime.unicodedata.category(ch) != "Mn")
        text = _runtime.re.sub(r"\s+", " ", text.lower())
        return text.strip()

    def _find_quick_synth_text_file(
        self,
        *,
        chapter_num: str,
        text_dirs: List[Path],
        issue_heading: Optional[str] = None,
    ) -> tuple[Optional[Path], bool, Dict[Path, List[Path]]]:
        from . import converter as _runtime
        chapter_aliases = self._chapter_selector_aliases(chapter_num)
        chapter_aliases.add(str(chapter_num).strip())

        def _matches_chapter_alias(path_obj: Path) -> bool:
            name = path_obj.name
            for alias in chapter_aliases:
                alias = str(alias).strip()
                if not alias:
                    continue
                if f" - {alias} -" in name:
                    return True
                if name.startswith(f"{alias} -") or name.startswith(f"{alias}."):
                    return True
            return False

        available_pre_tts: Dict[Path, List[Path]] = {}
        available_parsed: Dict[Path, List[Path]] = {}
        for text_dir in text_dirs:
            pre_tts_files = sorted(text_dir.glob("*-pre-tts.txt"))
            parsed_files = sorted(text_dir.glob("*-parsed.txt"))
            available_pre_tts[text_dir] = pre_tts_files
            available_parsed[text_dir] = parsed_files
            target = next((f for f in pre_tts_files if _matches_chapter_alias(f)), None)
            if target:
                return target, False, available_pre_tts
            target = next((f for f in parsed_files if _matches_chapter_alias(f)), None)
            if target:
                return target, True, available_pre_tts

        # Fallback: fuzzy match by chapter heading when legacy cache uses sequential prefixes.
        wanted_title = self._normalize_title_for_match(issue_heading or "")
        if wanted_title:
            scored: List[tuple[float, Path, bool]] = []
            for text_dir, files in available_pre_tts.items():
                for candidate in files:
                    stem = candidate.stem.replace("-pre-tts", "")
                    stem_norm = self._normalize_title_for_match(_runtime.re.sub(r"^\s*\d+\s*-\s*", "", stem))
                    ratio = _runtime.difflib.SequenceMatcher(None, wanted_title, stem_norm).ratio()
                    scored.append((ratio, candidate, False))
                for candidate in available_parsed.get(text_dir, []):
                    stem = candidate.stem.replace("-parsed", "")
                    stem_norm = self._normalize_title_for_match(_runtime.re.sub(r"^\s*\d+\s*-\s*", "", stem))
                    ratio = _runtime.difflib.SequenceMatcher(None, wanted_title, stem_norm).ratio()
                    scored.append((ratio, candidate, True))
            if scored:
                best_ratio, best_path, using_parsed = max(scored, key=lambda row: row[0])
                if best_ratio >= 0.45:
                    return best_path, using_parsed, available_pre_tts

        return None, False, available_pre_tts

    def _apply_chapter_whitelist(
        self, chapters: List[Chapter], whitelist: List[str]
    ) -> List[Chapter]:
        if not whitelist:
            return chapters
        allowed = {str(item).strip() for item in whitelist if str(item).strip()}
        if not allowed:
            return chapters

        filtered: List[Chapter] = []
        for idx, chapter in enumerate(chapters, start=1):
            label = self._chapter_index_label(chapter, idx)
            numeric = str(self._chapter_number(chapter, idx))
            sequential = str(idx)
            if label in allowed or numeric in allowed or sequential in allowed:
                filtered.append(chapter)

        if self.verbose:
            print(f"🎯 Chapter whitelist active: {len(filtered)}/{len(chapters)} selected")
        return filtered

    def _filter_chapters_auto(
        self, chapters: List[Chapter], output_dir: Path, config: ConversionConfig
    ) -> List[Chapter]:
        """
        Skip obvious credits/ads or very short chapters when there is no cached audio.
        Never removes chapters that already have a cached MP3.
        """
        from . import converter as _runtime
        patterns = [
            "créditos",
            "agradecimentos",
            "folha de rosto",
            "sumário",
            "indice",
            "capas",
        ]
        min_chars = int(_runtime.os.getenv("AUTO_SKIP_MIN_CHARS", "400").strip() or "400")
        # Default disabled to not skip chapters in test/default conversion scenarios
        skip_enabled = _runtime.os.getenv("AUTO_SKIP_EXTRA", "false").lower() not in {"false", "0", "no"}

        if not skip_enabled:
            return chapters

        filtered: List[Chapter] = []
        skipped = []
        for idx, chapter in enumerate(chapters, start=1):
            chapter_num = self._chapter_number(chapter, idx)
            name = (getattr(chapter, "name", None) or f"Chapter {chapter_num}").lower()
            chars = self._estimate_chapter_chars(chapter)
            mp3_temp = self._expected_output_path(chapter, chapter_num, output_dir)
            mp3_final = self._setup_output_directory(config) / mp3_temp.name
            has_audio = mp3_temp.exists() or mp3_final.exists()

            if has_audio:
                filtered.append(chapter)
                continue

            is_pattern = any(pat in name for pat in patterns)
            too_short = chars < min_chars
            if is_pattern or too_short:
                skipped.append((chapter_num, chapter.name, chars))
                continue

            filtered.append(chapter)

        if skipped:
            print(
                f"⏭️ Auto-skip: {len(skipped)} credits/short chapter(s) without cached audio; "
                f"use AUTO_SKIP_EXTRA=false to disable"
            )
            if self.verbose:
                for idx, name, chars in skipped:
                    print(f"   - {idx}: {name} ({chars} chars)")

        return filtered

    @staticmethod
    def _audio_files_exist(directory: Optional[Path]) -> bool:
        """Return whether a directory contains a non-empty cached MP3."""
        if not directory or not directory.exists():
            return False
        try:
            return any(
                path.is_file() and path.stat().st_size > 0 for path in directory.rglob("*.mp3")
            )
        except OSError:
            return False

    def _should_run_initial_validation(
        self, output_dir: Optional[Path], config: ConversionConfig
    ) -> bool:
        """Only run the expensive initial validator for genuinely new runs."""
        from . import converter as _runtime
        if getattr(config, "clear_cache", False):
            return False
        if self._audio_files_exist(output_dir):
            return False
        cache_dir = getattr(config, "cache_dir", None)
        if self._current_book_path:
            try:
                cache_dir = self.cache_manager._get_cache_path(self._current_book_path)
            except Exception:
                pass
        elif cache_dir and _runtime.Path(cache_dir) == _runtime.Path(_runtime.resolve_cache_root()):
            # The global cache root is not evidence for this book without a
            # resolved source path; avoid scanning unrelated audiobooks.
            cache_dir = None
        return not self._audio_files_exist(_runtime.Path(cache_dir) if cache_dir else None)

    @staticmethod
    def _duplicate_cleanup_enabled(config: ConversionConfig) -> bool:
        """Read the destructive duplicate cleanup opt-in."""
        if bool(getattr(config, "cleanup_duplicate_files", False)):
            return True
        extra = getattr(config, "extra", {}) or {}
        return str(extra.get("cleanup_duplicate_files", "")).strip().lower() in {
            "1",
            "true",
            "yes",
            "on",
        }

    def _setup_output_directory(self, config: ConversionConfig) -> Path:
        from . import converter as _runtime
        base_dir = _runtime.Path(config.output_dir)
        name = config.book_title or "default"
        safe_name = self.file_manager.sanitize_filename(name)
        return self.file_manager.ensure_directory(base_dir / safe_name)

    def _setup_temp_directory(self, config: ConversionConfig) -> Path:
        """Setup temporary directory for conversion files"""
        from . import converter as _runtime
        custom_cache = getattr(config, "cache_dir", None)

        if custom_cache:
            base_cache = _runtime.Path(custom_cache)
        else:
            try:
                base_cache = _runtime.resolve_cache_root()
                if config.book_title:
                    safe_title = self.file_manager.sanitize_filename(config.book_title)
                    base_cache = base_cache / safe_title
                else:
                    base_cache = base_cache / "conversion"
            except (RuntimeError, OSError) as e:
                # Fallback to system temp directory
                import tempfile

                print(f"⚠️ Cache unavailable: {e}")
                print("💡 Using system temporary directory")
                base_cache = _runtime.Path(tempfile.mkdtemp(prefix="epub_to_mp3_"))

        temp_dir = self.file_manager.ensure_directory(base_cache)
        config.cache_dir = temp_dir
        return temp_dir

    def _build_engine_signature(self, config: ConversionConfig) -> str:
        engine = getattr(config, "engine", None) or "unknown"
        return self.file_manager.sanitize_filename(engine.lower(), max_length=96).replace(" ", "_")
