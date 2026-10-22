"""Validation-stage orchestration and missing-segment repair for the converter host."""

from __future__ import annotations

import os
import re
import shutil
from pathlib import Path
from typing import Optional

from .config import ConversionConfig


class OutputValidationStage:
    """Own stage acceptance and segment retry while the host supplies conversion hooks."""

    async def _auto_validate_output(self, output_dir: Optional[Path], stage: str = "final", *, legacy_fallback_enabled: bool) -> bool:
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
                            legacy_fallback_enabled
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
