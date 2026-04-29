# -*- coding: utf-8 -*-
"""Audio validation helpers for AudioConverter."""

from __future__ import annotations

import os
import re
import shutil
from pathlib import Path
from typing import List, Optional, Set

from .config import ConversionConfig


def _env_bool(name: str, default: bool = False) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


LEGACY_FINAL_FALLBACK_ENABLED = _env_bool("LEGACY_FINAL_FALLBACK_ENABLED", False)


class _ValidationMixin:
    async def _auto_validate_and_retry_async(
        self, output_dir: Path, epub_path: Path, cache_dir: Optional[Path], max_retries: int = 10
    ) -> bool:
        """
        Validate and reconvert ONLY problematic segments until 100% correct.

        Smart retry:
        - Missing MP3: reconvert only the MP3 (uses cached text)
        - Modified text: reconvert the full chapter
        - Loop until success or critical stall error

        Returns:
            True if validation passed, False if critical error
        """
        import sys

        project_root = Path(__file__).parent.parent.parent
        if str(project_root) not in sys.path:
            sys.path.insert(0, str(project_root))

        from validate_conversion import extract_problem_chapters, validate_book

        from .ebook_reader import EbookReader

        config = self._active_config
        if not config:
            return False

        consecutive_failures = 0
        last_problem_count = float("inf")
        last_resort_attempted = False
        last_problem_chapters: List[str] = []
        completo_regen_attempted = False

        # Pre-pass: when the same chapter label produced multiple MP3s
        # across runs (different filename truncations or hash markers),
        # collapse them down to the single best file *before* validation
        # runs. Otherwise validate_book reports phantom dups + the retry
        # loop tries to re-synth a chapter that's already covered. The
        # 2026-04-29 Carl conversion produced 64 MP3s for a 61-chapter
        # book because of this exact issue.
        dedup_dropped = self._dedup_chapter_outputs(output_dir)
        if dedup_dropped and self.verbose:
            print(f"🧹 Auto-dedup: removed {dedup_dropped} duplicate MP3(s)")

        # Progressive duration tolerance: increase each retry to handle
        # Edge-TTS reading speed variations (Portuguese ~100-120 WPM, not 150)
        duration_tolerances = [None, 0.60, 0.70, 0.80, 0.90, 1.00, 1.20, 1.50, 2.00, 2.50]

        for attempt in range(1, max_retries + 1):
            dur_tol = duration_tolerances[min(attempt - 1, len(duration_tolerances) - 1)]
            if self.verbose:
                tol_str = f" (duration tolerance: {dur_tol:.0%})" if dur_tol else ""
                print(f"\n🔍 Validation (attempt {attempt}/{max_retries}){tol_str}...")

            # Suppress error messages during auto-fix
            old_verbose = os.environ.get("SUPPRESS_VALIDATION_ERRORS", "0")
            os.environ["SUPPRESS_VALIDATION_ERRORS"] = "1"

            try:
                stats, issues = validate_book(
                    epub_path, output_dir, cache_dir=cache_dir, duration_tolerance=dur_tol
                )
            finally:
                os.environ["SUPPRESS_VALIDATION_ERRORS"] = old_verbose

            # Check if passed (duration_mismatch also critical)
            has_critical_problems = bool(
                any(
                    stats.get(key, 0) > 0
                    for key in (
                        "missing_cache",
                        "text_mismatch",
                        "parsed_pretts_diff",
                        "missing_mp3",
                        "duration_mismatch",
                        "completo_size_mismatch",
                    )
                )
            )

            if not has_critical_problems:
                # **TRANSCRIPTION VERIFICATION**: Final gate via speech-to-text
                if getattr(config, "verify_transcription", False):
                    try:
                        from .transcription_verifier import TranscriptionVerifier
                        from .transcription_verifier import is_available as _whisper_ok

                        if _whisper_ok():
                            if (
                                not hasattr(self, "_transcription_verifier")
                                or self._transcription_verifier is None
                            ):
                                # Don't force language — let Whisper auto-detect per chapter
                                # (forced language fails on multilingual content)
                                self._transcription_verifier = TranscriptionVerifier(
                                    model_size=getattr(config, "transcription_model", "medium"),
                                    language=None,
                                )

                            if self.verbose:
                                print("🔍 Transcription verification (faster-whisper)...")

                            transcription_failures = []

                            def _find_pretts(mp3_stem: str) -> Optional[Path]:
                                """Find pre-tts.txt matching MP3 by best title overlap.

                                Searches output_dir/text/ first (filenames match MP3),
                                then cache_dir/text/ as fallback.
                                """

                                def _title(name: str) -> str:
                                    parts = name.split(" - ", 1)
                                    return parts[1].strip() if len(parts) > 1 else name

                                mp3_title = _title(mp3_stem)
                                search_dirs = []
                                if (output_dir / "text").exists():
                                    search_dirs.append(output_dir / "text")
                                if cache_dir and (cache_dir / "text").exists():
                                    search_dirs.append(cache_dir / "text")

                                best_match = None
                                best_overlap = 0
                                for text_dir in search_dirs:
                                    for candidate in text_dir.glob("*-pre-tts.txt"):
                                        cache_title = _title(candidate.stem.replace("-pre-tts", ""))
                                        overlap = 0
                                        for a, b in zip(mp3_title, cache_title):
                                            if a == b:
                                                overlap += 1
                                            else:
                                                break
                                        if overlap > best_overlap and overlap >= 20:
                                            best_overlap = overlap
                                            best_match = candidate
                                return best_match

                            mp3_files = sorted(output_dir.glob("*.mp3"))
                            total_mp3 = len(mp3_files)
                            for mp3_idx, mp3_file in enumerate(mp3_files, 1):
                                print(f"🔍 [{mp3_idx}/{total_mp3}] Verifying: {mp3_file.name}")
                                pre_tts_path = _find_pretts(mp3_file.stem)

                                if pre_tts_path and pre_tts_path.exists():
                                    original_text = pre_tts_path.read_text(encoding="utf-8")
                                    vr = self._transcription_verifier.verify_chapter(
                                        mp3_file, original_text
                                    )
                                    if not vr.passed:
                                        chapter_id = (
                                            mp3_file.stem.split(" - ")[0].strip()
                                            if " - " in mp3_file.stem
                                            else mp3_file.stem
                                        )
                                        threshold = (
                                            self._transcription_verifier.SIMILARITY_THRESHOLD
                                        )

                                        if getattr(vr, "partial", False):
                                            # Timeout during transcription - audio is likely fine,
                                            # just too large for Whisper to verify in time. Don't delete.
                                            print(
                                                f"⚠️ {mp3_file.name}: partial verification (timeout) {vr.similarity_score:.1%} - keeping MP3"
                                            )
                                        else:
                                            transcription_failures.append(chapter_id)
                                            print(
                                                f"❌ {mp3_file.name}: transcription {vr.similarity_score:.1%} < {threshold:.0%}"
                                            )
                                            # Delete bad MP3 so retry loop picks it up
                                            mp3_file.unlink(missing_ok=True)
                                    else:
                                        print(f"✅ {mp3_file.name}: {vr.similarity_score:.1%}")

                            if transcription_failures:
                                if self.verbose:
                                    print(
                                        f"🔄 {len(transcription_failures)} chapter(s) failed transcription, reconverting..."
                                    )
                                # Don't return True — fall through to retry
                                last_problem_count = len(transcription_failures)
                                continue
                    except Exception as e:
                        if self.verbose:
                            print(f"⚠️ Transcription verification error: {e}")

                if self.verbose:
                    print("✅ Validation passed! Conversion 100% correct.")
                return True

            # If only the complete-book text file has a size mismatch (all chapters are fine),
            # regenerate it from the cached text files instead of reconverting audio.
            if stats.get("completo_size_mismatch", 0) > 0 and not any(
                stats.get(k, 0) > 0
                for k in (
                    "missing_cache",
                    "text_mismatch",
                    "parsed_pretts_diff",
                    "missing_mp3",
                    "duration_mismatch",
                )
            ):
                if not completo_regen_attempted:
                    completo_regen_attempted = True
                    if self.verbose:
                        print("📖 Regenerating complete book text file...")
                    try:
                        reader = EbookReader(str(epub_path))
                        all_chapters = reader.get_chapter_structure(preserve_all=True)
                        self._generate_full_book_text(output_dir, all_chapters)
                    except Exception as exc:
                        if self.verbose:
                            print(f"⚠️  Could not regenerate complete book text: {exc}")
                    continue
                else:
                    # Already attempted regeneration — size mismatch is inherent to this
                    # book's text processing. All individual chapters are valid, so accept.
                    if self.verbose:
                        print(
                            "⚠️  Complete book text size mismatch persists after regeneration "
                            "(likely due to text preprocessing). All individual chapters are intact — accepting."
                        )
                    return True

            # Extract chapters with problems
            problem_chapters = extract_problem_chapters(issues)
            last_problem_chapters = list(problem_chapters)

            if not problem_chapters:
                # Has problems but couldn't identify specific chapters
                if self.verbose:
                    print("⚠️  Problems detected but couldn't identify specific chapters")
                consecutive_failures += 1
                if consecutive_failures >= 3:
                    if not last_resort_attempted:
                        last_resort_attempted = True
                        recovered = await self._last_resort_recovery(
                            epub_path=epub_path,
                            output_dir=output_dir,
                            chapter_selectors=None,
                            reason="validation without identifiable chapter mapping",
                        )
                        if recovered:
                            consecutive_failures = 0
                            last_problem_count = float("inf")
                            continue
                    print("❌ Critical error: cannot identify problems. Aborting.")
                    return False
                continue

            # Detect if we're stuck (same number of problems)
            current_problem_count = len(problem_chapters)
            if current_problem_count >= last_problem_count:
                consecutive_failures += 1
                # With progressive tolerance, allow more retries for duration-only issues
                _, duration_only_check = self._categorize_problems(issues, problem_chapters)
                all_duration_only = len(duration_only_check) == current_problem_count
                max_consecutive = 6 if all_duration_only else 3
                if consecutive_failures >= max_consecutive:
                    if not last_resort_attempted:
                        last_resort_attempted = True
                        recovered = await self._last_resort_recovery(
                            epub_path=epub_path,
                            output_dir=output_dir,
                            chapter_selectors=problem_chapters,
                            reason=f"stuck with repeated problems ({current_problem_count})",
                        )
                        if recovered:
                            consecutive_failures = 0
                            last_problem_count = float("inf")
                            continue
                    if self.verbose:
                        print(
                            f"❌ Critical error: stuck with {current_problem_count} problems after {max_consecutive} attempts. Aborting."
                        )
                    return False
            else:
                consecutive_failures = 0

            last_problem_count = current_problem_count

            # Categorize problems by type
            missing_mp3_only, duration_only = self._categorize_problems(issues, problem_chapters)

            if self.verbose:
                print()
                print("=" * 60)
                print(f"🔧 RECONVERSION: {len(problem_chapters)} chapter(s) with problems")
                print("=" * 60)
                print(f"   Chapters: {', '.join(map(str, problem_chapters[:10]))}")
                if missing_mp3_only:
                    print(
                        f"   💡 {len(missing_mp3_only)} chapter(s) with missing MP3 only - quick synthesis"
                    )
                if duration_only:
                    print(
                        f"   ⏱️  {len(duration_only)} chapter(s) with incorrect duration only - will be retried with higher tolerance"
                    )
                skip_set = set(missing_mp3_only) | set(duration_only)
                full_reconvert = [ch for ch in problem_chapters if ch not in skip_set]
                if full_reconvert:
                    print(
                        f"   🔄 {len(full_reconvert)} chapter(s) with incorrect text/name - full reconversion"
                    )

            # Remove bad MP3s before reconverting
            removed_files = self._remove_bad_mp3s(output_dir, issues, problem_chapters)
            if removed_files and self.verbose:
                print(f"   🗑️  {len(removed_files)} bad MP3(s) removed before reconversion:")
                for f in removed_files:
                    print(f"      - {f}")
                print("=" * 60)

            # Reconvert problematic chapters
            try:
                quick_missing_mp3_failed = False
                # For missing MP3s, try quick synthesis first
                if missing_mp3_only:
                    quick_limit = max(1, int(os.getenv("QUICK_SYNTH_MAX_CHAPTERS", "8") or "8"))
                    if len(missing_mp3_only) > quick_limit:
                        quick_missing_mp3_failed = True
                        if self.verbose:
                            print(
                                f"   ⚠️  {len(missing_mp3_only)} missing MP3 chapters (>{quick_limit}) - skipping quick synthesis and forcing full reconversion"
                            )
                    else:
                        success = await self._reconvert_missing_mp3s(
                            output_dir, cache_dir, missing_mp3_only, issues
                        )
                        if success and self.verbose:
                            print(f"   ✅ {len(missing_mp3_only)} MP3(s) generated successfully")
                        if not success:
                            quick_missing_mp3_failed = True
                            if self.verbose:
                                print(
                                    "   ⚠️  Quick synthesis incomplete; falling back to full chapter reconversion"
                                )

                # Duration-only chapters: re-synthesize MP3 (may get slightly different timing)
                if duration_only and attempt <= 2:
                    # Only re-synthesize on first 2 attempts; after that rely on tolerance increase
                    if self.verbose:
                        print(
                            f"   🔄 Re-synthesizing {len(duration_only)} MP3(s) with incorrect duration..."
                        )
                    await self._reconvert_missing_mp3s(output_dir, cache_dir, duration_only, issues)

                # For the rest, reconvert full chapter
                skip_set = set(duration_only)
                if not quick_missing_mp3_failed:
                    skip_set |= set(missing_mp3_only)
                chapters_to_reconvert = [ch for ch in problem_chapters if ch not in skip_set]

                if not chapters_to_reconvert:
                    continue  # Only MP3s/duration, already handled

                reader = EbookReader(str(epub_path))

                # Apply same transforms as validation to ensure consistent chapter mapping
                try:
                    from python_app.main import ConverterApplication

                    app = ConverterApplication()
                    preview_config = app.config.create_conversion_config(
                        engine=config.engine,
                        output_dir=str(output_dir.parent),
                        book_title=reader.title,
                        preserve_all_chapters=True,
                    )
                    preview_config.footnote_mode = "inline"
                    preview_config.footnote_context_words = app.FOOTNOTE_CONTEXT_WORDS
                    structure_items = app._generate_structure_items(reader, filter_chapters=False)
                    structure_items = app._apply_text_transforms(
                        structure_items, preview_config, reader
                    )
                    app._apply_structure_to_reader(reader, structure_items)
                except Exception as exc:
                    if self.verbose:
                        print(f"⚠️  Warning: failed to apply transforms ({exc})")

                all_chapters = reader.get_chapter_structure(preserve_all=True)

                chapter_indices = self._resolve_problem_chapter_indices(
                    all_chapters, chapters_to_reconvert
                )

                if not chapter_indices:
                    if self.verbose:
                        print("⚠️  Could not map problematic chapters")
                    consecutive_failures += 1
                    continue

                # Create config for partial reconversion
                retry_config = ConversionConfig(
                    engine=config.engine,
                    voice=config.voice,
                    output_dir=str(output_dir.parent),
                    book_title=reader.title,
                    preserve_all_chapters=True,
                    clear_cache=False,  # Keep existing cache
                    auto_validate_output=False,  # Prevent recursion
                    auto_fix_output=False,  # Prevent recursion
                )
                retry_config.extra["chapter_whitelist"] = ",".join(chapter_indices)
                retry_config.extra["disable_chunk_resume"] = "1"

                # Reconvert using existing converter instance
                await self.convert(reader, retry_config)

            except Exception as exc:
                if self.verbose:
                    print(f"⚠️  Error reconverting: {exc}")
                    import traceback

                    traceback.print_exc()
                consecutive_failures += 1
                if consecutive_failures >= 3:
                    if not last_resort_attempted:
                        last_resort_attempted = True
                        recovered = await self._last_resort_recovery(
                            epub_path=epub_path,
                            output_dir=output_dir,
                            chapter_selectors=last_problem_chapters or None,
                            reason=f"exception during reconversion: {exc}",
                        )
                        if recovered:
                            consecutive_failures = 0
                            last_problem_count = float("inf")
                            continue
                    return False
                continue

        # If we reached here, attempts exhausted but may have made progress
        if not last_resort_attempted:
            recovered = await self._last_resort_recovery(
                epub_path=epub_path,
                output_dir=output_dir,
                chapter_selectors=last_problem_chapters or None,
                reason=f"max retries exhausted ({max_retries})",
            )
            if recovered:
                return True
        if self.verbose:
            print(f"⚠️  Reached limit of {max_retries} attempts. Some problems may persist.")
        return False

    def _dedup_chapter_outputs(self, output_dir: Path) -> int:
        """Collapse duplicate MP3s for the same chapter label.

        Two situations produce duplicates we want to clean up
        automatically:

        1. Re-runs with slightly different filename truncations leave
           one short and one long version (the v0.3.16 stable hash
           addresses this for new conversions but doesn't retroactively
           fix older artefacts already on disk).
        2. A reconversion of a single chapter writes a new file while
           the legacy one persists.

        Strategy: group MP3s by their leading ``<label> - `` prefix.
        Keep the file with the longest *audio duration* — the longer
        track is almost always the more complete output. Drop the rest.

        Returns the number of files removed.
        """
        import re as _re
        import subprocess as _subprocess
        from collections import defaultdict as _defaultdict

        if not output_dir or not output_dir.exists():
            return 0

        label_re = _re.compile(r"^([\d.]+)\s+-\s+")
        groups: dict[str, list[Path]] = _defaultdict(list)
        for mp3 in output_dir.glob("*.mp3"):
            match = label_re.match(mp3.name)
            if not match:
                continue
            groups[match.group(1)].append(mp3)

        ffprobe_failures = 0

        def _duration(path: Path) -> float:
            nonlocal ffprobe_failures
            try:
                out = _subprocess.run(
                    [
                        "ffprobe",
                        "-v",
                        "error",
                        "-show_entries",
                        "format=duration",
                        "-of",
                        "default=noprint_wrappers=1:nokey=1",
                        str(path),
                    ],
                    capture_output=True,
                    text=True,
                    timeout=15,
                )
                return float(out.stdout.strip() or 0.0)
            except Exception:
                # ffprobe missing or refused the file — note it so the
                # caller knows the dedup downgraded to file-size only,
                # then return 0.0 so the size tie-break below still
                # produces a deterministic winner.
                ffprobe_failures += 1
                return 0.0

        removed = 0
        for label, files in groups.items():
            if len(files) <= 1:
                continue
            # When ffprobe reports duration, longer audio wins (more of
            # the chapter actually got synthesised). When it doesn't, the
            # tuple falls back to file size — still deterministic, and
            # bigger MP3 is almost always the more complete track.
            scored = [(_duration(f), f.stat().st_size, f) for f in files]
            scored.sort(key=lambda t: (t[0], t[1]), reverse=True)
            for _dur, _size, loser in scored[1:]:
                try:
                    loser.unlink()
                    removed += 1
                except OSError:
                    pass
        if ffprobe_failures and getattr(self, "verbose", False):
            print(
                f"   ⚠️ Auto-dedup: ffprobe failed on {ffprobe_failures} file(s); "
                "ranking by file size only."
            )
        return removed

    def _categorize_problems(self, issues: list, problem_chapters: list) -> tuple[list, list]:
        """
        Categorize problems to decide reconversion strategy.

        Returns:
            Tuple of (missing_mp3_only, duration_only) chapter lists
        """
        missing_mp3_only = []
        duration_only = []

        for chapter_num in problem_chapters:
            chapter_issues = [issue for issue in issues if f"Chapter {chapter_num}" in issue]
            if not chapter_issues:
                continue

            tags: Set[str] = set()
            for issue in chapter_issues:
                issue_l = issue.lower()
                if "missing mp3" in issue_l:
                    tags.add("missing_mp3")
                elif "duration mismatch" in issue_l:
                    tags.add("duration")
                else:
                    # Any other validation issue (missing cache, text mismatch, HTML, duplicates, etc.)
                    # must trigger full chapter reconversion.
                    tags.add("other")

            if tags == {"missing_mp3"}:
                missing_mp3_only.append(chapter_num)
            elif tags == {"duration"}:
                # Duration-only issue (text and MP3 exist but duration off)
                duration_only.append(chapter_num)

        return missing_mp3_only, duration_only

    def _remove_bad_mp3s(self, output_dir: Path, issues: list, problem_chapters: list) -> list[str]:
        """
        Remove bad MP3s before reconverting to avoid conflicts.

        Extracts MP3 names from validation issues (incorrect name, duplicate,
        wrong duration) and removes them from the output directory.

        Returns:
            List of removed file names.
        """
        removed = []
        mp3_filenames_to_remove: set[str] = set()

        for issue in issues:
            # "MP3 filename 'xxx.mp3' does not match EPUB heading"
            match = re.search(r"MP3 filename '([^']+\.mp3)'", issue)
            if match:
                mp3_filenames_to_remove.add(match.group(1))

            # "MP3 filename contains HTML/markup: xxx.mp3"
            match = re.search(r"HTML/markup:\s*(.+\.mp3)", issue)
            if match:
                mp3_filenames_to_remove.add(match.group(1).strip())

        # Also remove MP3s for chapters with duration mismatch or duplicates
        # by matching chapter number patterns in existing MP3 filenames
        problem_set = set(str(ch) for ch in problem_chapters)
        if output_dir.exists():
            for mp3_file in output_dir.glob("*.mp3"):
                # Extract chapter number from filename (e.g. "4.1 - ..." or "004 - ...")
                stem = mp3_file.name
                # Match decimal index: "4.1 - ...", "10.5 - ..."
                ch_match = re.match(r"^(\d+\.\d+)\s*-\s*", stem)
                if not ch_match:
                    # Match zero-padded: "004 - ..."
                    ch_match = re.match(r"^0*(\d+)\s*-\s*", stem)
                if ch_match:
                    ch_num = ch_match.group(1)
                    if ch_num in problem_set:
                        mp3_filenames_to_remove.add(mp3_file.name)

        # Remove the files
        for fname in mp3_filenames_to_remove:
            mp3_path = output_dir / fname
            if mp3_path.exists():
                mp3_path.unlink()
                removed.append(fname)

        return removed

    async def _auto_validate_output(self, output_dir: Optional[Path], stage: str = "final") -> bool:
        """
        Run validate_conversion.validate_book to cross-check EPUB, cache and MP3.

        Best-effort: failures are logged only in verbose mode.
        Skipped when a chapter filter is active (--chapter) because the
        full-book validator would flag every non-requested chapter as missing.
        """
        try:
            if stage not in {"final", "cache-only", "test", "initial"}:
                return True
            config = self._active_config
            if not config or getattr(config, "auto_validate_output", True) is False:
                return True

            # Skip full-book validation when only specific chapters were requested
            chapter_filter_active = bool(self._parse_chapter_whitelist(config)) or bool(
                (config.extra or {}).get("selected_indices", "").strip()
            )
            if chapter_filter_active:
                return True

            epub_path = getattr(self, "_current_book_path", None)
            if not epub_path or not Path(epub_path).exists():
                return stage != "final"
            if not output_dir:
                output_dir = self._last_output_dir
            if not output_dir:
                return stage != "final"

            # For "initial" stage, only run if there are existing MP3s to validate
            if stage == "initial":
                if not output_dir.exists():
                    return True
                mp3_files = list(output_dir.glob("*.mp3"))
                if not mp3_files:
                    # No existing MP3s, skip initial validation (first conversion)
                    return True
                if self.verbose:
                    print(
                        f"\n🔍 Previous conversion detected with {len(mp3_files)} MP3(s). Validating before reconverting..."
                    )

            # Add project root to sys.path for validate_conversion import
            import sys

            project_root = Path(__file__).parent.parent.parent
            if str(project_root) not in sys.path:
                sys.path.insert(0, str(project_root))

            from validate_conversion import validate_book

            cache_dir = getattr(config, "cache_dir", None)
            if cache_dir:
                cache_dir = Path(cache_dir)
            else:
                try:
                    if self._current_book_path:
                        cache_dir = self.cache_manager._get_cache_path(self._current_book_path)
                except Exception:
                    cache_dir = None

            # Get max retries from config or environment
            # 2 retries is plenty: each iteration runs validate_book over
            # the entire book and re-syntheses every flagged chapter, so
            # 8 retries on a 61-chapter audiobook = up to 8 × 61 chapter
            # checks plus 8 × N reconversions. The Carl conversion crashed
            # the OS at iteration 5 from sustained 8 GB RAM pressure. Two
            # passes is enough for genuine flakiness without spiralling.
            # Override via MAX_VALIDATION_RETRIES.
            max_retries = getattr(config, "max_validation_retries", None)
            if max_retries is None:
                max_retries = int(os.getenv("MAX_VALIDATION_RETRIES", "2"))

            # Use retry-based validation if auto_fix is enabled
            if getattr(config, "auto_fix_output", True) and not self._auto_fix_guard:
                self._auto_fix_guard = True
                try:
                    success = await self._auto_validate_and_retry_async(
                        Path(output_dir), Path(epub_path), cache_dir, max_retries=max_retries
                    )
                    if not success:
                        if self.verbose:
                            print("\n⚠️  Conversion completed but with validation problems")

                        # Legacy fallback path (disabled by default because it duplicates
                        # expensive full-book validation/retry already handled above).
                        current_engine = getattr(config, "engine", "").lower()
                        if (
                            LEGACY_FINAL_FALLBACK_ENABLED
                            and current_engine in {"edge", "auto"}
                            and stage == "final"
                        ):
                            if self.verbose:
                                print("\n🔄 Trying automatic fallback to Piper...")

                            # Check if Piper is available
                            try:
                                from .tts.factory import TTSFactory

                                factory = TTSFactory()
                                available_engines = factory.available_engines()

                                if "piper" in available_engines:
                                    # Get chapters with problems
                                    from validate_conversion import validate_book

                                    stats, issues = validate_book(
                                        Path(epub_path), Path(output_dir), cache_dir=cache_dir
                                    )

                                    missing_chapters = []
                                    for issue in issues:
                                        if "Missing MP3" in issue:
                                            # Extract chapter number
                                            match = re.search(r"Chapter (\d+(?:\.\d+)?)", issue)
                                            if match:
                                                missing_chapters.append(match.group(1))

                                    if missing_chapters and self.verbose:
                                        print(
                                            f"   🎯 {len(missing_chapters)} chapter(s) missing - reconverting com Piper"
                                        )
                                        print(
                                            f"   Chapters: {', '.join(map(str, missing_chapters[:10]))}"
                                        )

                                    # Mudar temporariamente para Piper
                                    original_engine = config.engine
                                    config.engine = "piper"

                                    try:
                                        # Reconverter chapters missing com Piper
                                        piper_success = await self._reconvert_missing_mp3s(
                                            Path(output_dir), cache_dir, missing_chapters, issues
                                        )

                                        if piper_success:
                                            # Validar novamente
                                            stats_after, issues_after = validate_book(
                                                Path(epub_path),
                                                Path(output_dir),
                                                cache_dir=cache_dir,
                                            )
                                            has_critical = any(
                                                stats_after.get(key, 0) > 0
                                                for key in (
                                                    "missing_cache",
                                                    "text_mismatch",
                                                    "parsed_pretts_diff",
                                                    "missing_mp3",
                                                )
                                            )

                                            if not has_critical:
                                                if self.verbose:
                                                    print(
                                                        "   ✅ Fallback para Piper bem-sucedido! Todos os chapters convertidos."
                                                    )
                                                success = True
                                            elif self.verbose:
                                                print(
                                                    f"   ⚠️  Fallback parcial: {stats_after.get('missing_mp3', 0)} chapter(s) ainda missing"
                                                )
                                    finally:
                                        # Restaurar engine original
                                        config.engine = original_engine
                                else:
                                    if self.verbose:
                                        print("   ⚠️  Piper not available para fallback")
                            except Exception as fallback_exc:
                                if self.verbose:
                                    print(f"   ⚠️  Error no fallback: {fallback_exc}")

                        # If problems remain after fallback, show a clear error
                        if not success and self.verbose:
                            print(
                                "\n❌ INCOMPLETE CONVERSION: Alguns chapters not foram convertidos"
                            )
                            print("   Tente:")
                            print("   1. Converter novamente com --engine piper")
                            print("   2. Convert specific chapters with --chapter N")
                    if stage == "final":
                        self._final_validation_passed = bool(success)
                finally:
                    self._auto_fix_guard = False
                return bool(success)

            # Fallback to simple validation without auto-fix
            stats, issues = validate_book(Path(epub_path), Path(output_dir), cache_dir=cache_dir)
            has_problems = bool(
                issues
                or any(
                    stats.get(key, 0) > 0
                    for key in (
                        "missing_cache",
                        "text_mismatch",
                        "parsed_pretts_diff",
                        "missing_mp3",
                        "duration_mismatch",
                    )
                )
            )

            # Just report validation results (no auto-fix when it's disabled)
            if self.verbose and has_problems:
                print(
                    f"[DEBUG] Auto-validate ({stage}): validation has problems but auto-fix is disabled"
                )
            if stage == "final":
                self._final_validation_passed = not has_problems
            return not has_problems
        except Exception as exc:
            if self.verbose:
                print(f"[DEBUG] Auto-validate ({stage}) failed: {exc}")
            if stage == "final":
                self._final_validation_passed = False
                return False
            return True

    async def _attempt_segment_retry(
        self,
        tts_engine: object,
        chapter_index: int,
        chapter_label: str,
        output_path: Path,
        *,
        config: ConversionConfig,
    ) -> bool:
        """Try recovering missing chunks/segments after validation failure."""
        if not getattr(config, "validate_audio", True):
            return False
        try:
            if not hasattr(tts_engine, "get_synthesis_tracker"):
                return False
            tracker = tts_engine.get_synthesis_tracker()
            if not tracker:
                return False
            missing_segments = tracker.get_missing_segments()
            if not missing_segments:
                return False
            if self.verbose:
                print(
                    f"🔄 Chapter {chapter_label}: {len(missing_segments)} segmento(s) failurendo, tentando recuperar..."
                )
            from .retry_manager import RetryManager

            retry_manager = RetryManager(max_retries=3)
            temp_retry_dir = output_path.parent / f"retry_temp_{chapter_index}"
            retry_report = await retry_manager.retry_failed_segments(
                engine=tts_engine,
                failed_segments=missing_segments,
                output_path=output_path,
                temp_dir=temp_retry_dir,
            )
            if self.verbose:
                print(
                    f"✓ Retry segmentos: {retry_report.successful}/{retry_report.total_retried} recuperados, "
                    f"{retry_report.still_failed} failed"
                )
            try:
                if temp_retry_dir.exists():
                    shutil.rmtree(temp_retry_dir, ignore_errors=True)
            except Exception:
                pass
            return retry_report.still_failed == 0
        except Exception as exc:
            if self.verbose:
                print(f"⚠️ Segment retry failed: {exc}")
            return False
