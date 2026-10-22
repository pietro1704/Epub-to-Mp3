# -*- coding: utf-8 -*-
"""Validated pre-TTS text artifacts and full-book export."""

from __future__ import annotations

from pathlib import Path
from typing import List, Optional

from .config import ConversionConfig
from .ebook_reader import Chapter
from .text_integrity_validator import TextIntegrityValidator


class ConverterTextPreparation:
    """Validated pre-TTS text artifacts and full-book export."""

    def _validate_and_clean_cache(
        self, chapters: List[Chapter], output_dir: Path, config: ConversionConfig
    ) -> None:
        """Validate cache: if MP3 exists but pre-tts.txt doesn't, delete MP3.
        Also copy existing files from final output_dir back to temp for resume capability."""
        from . import converter as _runtime
        text_dir = _runtime.Path(output_dir) / "text"
        deleted_count = 0
        copied_count = 0
        regenerated_txt = 0

        # Prepare formatter once for regeneration
        try:
            from .text_formatting import TextFormattingProcessor

            TextFormattingProcessor()
        except ImportError:
            pass

        # Get final output directory to check for already converted chapters
        final_output_dir = self._setup_output_directory(config)

        for idx, chapter in enumerate(chapters, start=1):
            chapter_num = self._chapter_number(chapter, idx)
            chapter_label = self._chapter_index_label(chapter, idx)
            chapter_name = getattr(chapter, "name", None) or f"Chapter {chapter_label}"
            # Remove duplicate prefix to avoid "4.5 - 4.5 - Title"
            chapter_name_clean = self._remove_duplicate_chapter_prefix(chapter_label, chapter_name)
            safe_name = self.file_manager.sanitize_filename(chapter_name_clean)

            # Check for pre-tts.txt
            pre_tts_file = text_dir / f"{chapter_label} - {safe_name}-pre-tts.txt"

            # Check for MP3 in temp/cache dir
            mp3_path = self._expected_output_path(chapter, chapter_num, output_dir)

            # Check for MP3 in final output dir (for resume capability)
            final_mp3_path = final_output_dir / mp3_path.name

            # If MP3 exists in final output but not in temp, copy it for reuse
            if not mp3_path.exists() and final_mp3_path.exists():
                try:
                    final_size = final_mp3_path.stat().st_size
                    if final_size > 1000:  # Valid file (> 1KB)
                        import shutil

                        shutil.copy2(str(final_mp3_path), str(mp3_path))
                        copied_count += 1
                        if self.verbose:
                            print(f"   ♻️ Reusing chapter {chapter_num}: {mp3_path.name}")
                except OSError as e:
                    if self.verbose:
                        print(f"   ⚠️ Error copying chapter {chapter_num}: {e}")

            # If MP3 exists but pre-tts.txt doesn't → invalidate audio to force fresh synthesis
            if mp3_path.exists() and not pre_tts_file.exists():
                if self.verbose:
                    print(
                        f"   🗑️ Incomplete cache (missing pre-tts.txt) for chapter {chapter_num}: removing MP3"
                    )
                mp3_path.unlink(missing_ok=True)
                mp3_path.with_suffix(".wav").unlink(missing_ok=True)
                deleted_count += 1

        if copied_count > 0:
            print(f"♻️ {copied_count} chapter(s) reused from previous conversion")
        if regenerated_txt > 0:
            print(f"♻️ {regenerated_txt} pre-tts file(s) regenerated to reuse cache")
        if deleted_count > 0:
            print(f"🗑️ {deleted_count} MP3 file(s) removed (invalid cache)")

    def _generate_all_text_files(
        self,
        chapters: List[Chapter],
        output_dir: Path,
        config: ConversionConfig,
        *,
        text_validator: Optional["TextIntegrityValidator"] = None,
        cleanup_existing: bool = True,
    ) -> None:
        """Generate all text files BEFORE starting TTS conversion"""
        from . import converter as _runtime
        text_dir = _runtime.Path(output_dir) / "text"
        text_dir.mkdir(parents=True, exist_ok=True)

        # Clean up legacy duplicate files: old code wrote "N - X.Y.Z - name-parsed.txt"
        # variants alongside the canonical "X.Y.Z - name-parsed.txt" files.
        # Use regex to reliably detect the integer-prefix pattern regardless of
        # how many " - " separators the chapter name itself contains.
        _int_prefix_re = _runtime.re.compile(r"^\d+ - \d+(\.\d+)* - ")
        if text_dir.exists():
            duplicates_removed = 0
            for txt_file in sorted(text_dir.glob("*.txt")):
                if _int_prefix_re.match(txt_file.name):
                    txt_file.unlink(missing_ok=True)
                    duplicates_removed += 1
            if duplicates_removed > 0 and not self.verbose:
                print(f"  🧹 Removed {duplicates_removed} legacy duplicate file(s)")

        if cleanup_existing and any(text_dir.glob("*.txt")):
            for txt_file in text_dir.glob("*.txt"):
                txt_file.unlink(missing_ok=True)
            if self.verbose:
                print("  🧹 Cleaned up old text files")

        # Import TextFormattingProcessor to apply the same processing as TTS
        try:
            from .text_formatting import TextFormattingProcessor

            formatter = TextFormattingProcessor()
        except ImportError:
            formatter = None

        def _prepare_payload(chapter_index: str, chapter_obj: Chapter) -> tuple[str, str, str, str]:
            chapter_name_local = getattr(chapter_obj, "name", None) or f"Chapter {chapter_index}"
            parsed_text_local = chapter_obj.text or ""
            # When speech_text was set by _prepare_speech_text at parse time it already has:
            #   (a) [[fmt:]] markers converted to audible cues
            #   (b) apply_structural_speech_cues "..." pauses after headings
            # Re-calling to_audible_text with the original formatting_segments would
            # reconstruct text from the raw HTML-derived segments, discarding (b).
            # Fix: process only from speech_text itself, without passing segments.
            raw_speech = getattr(chapter_obj, "speech_text", None)
            if raw_speech is not None:
                if formatter and "[[fmt" in raw_speech:
                    # Rare: speech_text still has unresolved markers — convert without
                    # segments so we work from the text (which may already have cues).
                    pre_tts_text_local = formatter.to_audible_text(raw_speech, None)
                elif formatter:
                    pre_tts_text_local = formatter.strip_inline_markdown(raw_speech)
                else:
                    pre_tts_text_local = raw_speech
            else:
                # Fallback: no pre-processed speech_text — run the full formatting pipeline
                # using the original HTML-derived segments (no structural cues to preserve).
                speech_text_local = chapter_obj.text or ""
                if formatter:
                    formatting_segments_local = getattr(chapter_obj, "formatting_segments", None)
                    if formatting_segments_local or "[[fmt" in speech_text_local:
                        pre_tts_text_local = formatter.to_audible_text(
                            speech_text_local, formatting_segments_local
                        )
                    else:
                        pre_tts_text_local = speech_text_local
                else:
                    pre_tts_text_local = speech_text_local
            return (chapter_index, chapter_name_local, parsed_text_local, pre_tts_text_local or "")

        files_generated = 0
        futures = []
        chapter_entries: List[tuple[str, int, Chapter]] = []
        with _runtime.ThreadPoolExecutor(max_workers=min(8, (_runtime.os.cpu_count() or 1))) as executor:
            for idx, chapter in enumerate(chapters, start=1):
                chapter_label = self._chapter_index_label(chapter, idx)
                chapter_num = self._chapter_number(chapter, idx)
                chapter_entries.append((chapter_label, chapter_num, chapter))
                if formatter:
                    formatting_segments_local = getattr(chapter, "formatting_segments", None)
                    formatter.to_audible_text(self._speech_text(chapter), formatting_segments_local)
                futures.append(executor.submit(_prepare_payload, chapter_label, chapter))

            for idx, future in enumerate(futures, start=1):
                chapter_label, chapter_num, chapter = chapter_entries[idx - 1]
                max_retries = 3
                retry_count = 0
                result_data = None
                while retry_count < max_retries:
                    try:
                        result_data = future.result(timeout=120)
                        break
                    except TimeoutError:
                        retry_count += 1
                        if retry_count < max_retries:
                            print(
                                f"⚠️ Timeout ao processar chapter {chapter_label} - attempt {retry_count}/{max_retries}"
                            )
                            future = executor.submit(_prepare_payload, chapter_label, chapter)
                        else:
                            print(f"❌ Chapter {chapter_label} failed after {max_retries} attempts")
                            raise Exception(
                                f"Chapter {chapter_label} cannot be processed after {max_retries} attempts"
                            )

                if result_data is None:
                    raise Exception(f"Chapter {chapter_label} retornou dados nulos")

                chapter_label, chapter_name, parsed_text, pre_tts_text = result_data

                # **FIX**: Remove numeric prefix from chapter_name if it duplicates the label
                # to prevent filenames like "4.5 - 4.5 - Chapter Title"
                chapter_name_clean = self._remove_duplicate_chapter_prefix(
                    chapter_label, chapter_name
                )

                safe_name = self.file_manager.sanitize_filename(chapter_name_clean, max_length=96)

                # **FIX**: Use ONLY canonical chapter_label to prevent duplicates
                # Previously created multiple variants (label, sequential, numeric) which
                # caused duplicate files with same content but different names
                label_variants = [chapter_label]  # Only use canonical label

                paths_written = []
                for label in label_variants:
                    parsed_path = text_dir / f"{label} - {safe_name}-parsed.txt"
                    pre_tts_path = text_dir / f"{label} - {safe_name}-pre-tts.txt"
                    force = getattr(config, "force_reprocess", False) or getattr(
                        config, "clear_cache", False
                    )
                    if parsed_path.exists() and pre_tts_path.exists() and not force:
                        continue
                    parsed_path.write_text(parsed_text, encoding="utf-8")
                    pre_tts_path.write_text(pre_tts_text, encoding="utf-8")
                    paths_written.append((parsed_path, pre_tts_path))

                if not paths_written:
                    continue
                files_generated += 2

                if text_validator and getattr(config, "validate_text", True):
                    strict_validation = getattr(config, "strict_validate", False)
                    valid_text = self._validate_text_after_save(
                        chapter,
                        chapter_label,
                        parsed_text,
                        pre_tts_text,
                        validator=text_validator,
                        strict=False,
                    )
                    if not valid_text:
                        max_text_retries = 2
                        for retry_idx in range(max_text_retries):
                            if self.verbose:
                                print(
                                    f"🔄 Regerando text do chapter {chapter_label} "
                                    f"(attempt {retry_idx + 1}/{max_text_retries})"
                                )
                            _, _, parsed_text, pre_tts_text = _prepare_payload(
                                chapter_label, chapter
                            )
                            parsed_path.write_text(parsed_text, encoding="utf-8")
                            pre_tts_path.write_text(pre_tts_text, encoding="utf-8")
                            valid_text = self._validate_text_after_save(
                                chapter,
                                chapter_label,
                                parsed_text,
                                pre_tts_text,
                                validator=text_validator,
                                strict=False,
                            )
                            if valid_text:
                                break
                    if not valid_text and strict_validation:
                        raise RuntimeError(
                            f"Post-parsing validation failed after retry ({chapter_label})"
                        )

                # Save segment plan (text chunks) for future reuse
                try:
                    segments = []
                    chunk_limit = getattr(config, "edge_chunk_chars", 4000) or 4000
                    text_to_split = pre_tts_text or parsed_text or ""
                    for start in range(0, len(text_to_split), chunk_limit):
                        segments.append(text_to_split[start : start + chunk_limit])
                    self._save_segment_plan(config.cache_dir, chapter_num, segments, config)
                except Exception:
                    pass

                if self.verbose:
                    print(f"   📄 {chapter_num}. {chapter_name}")
                    print(f"      → {parsed_path.name}")
                    print(f"      → {pre_tts_path.name}")
                    if formatter and parsed_text != pre_tts_text:
                        chars_added = len(pre_tts_text) - len(parsed_text)
                        print(f"      ℹ️ Formatting added {chars_added} chars (audio cues)")

        if files_generated == 0 and self.verbose:
            print("   ♻️ All .txt files already exist (using cache)")

    def _sync_text_cache_to_output(self, temp_dir: Path, output_dir: Path) -> int:
        """Copy cached .txt artifacts into output/text for validation."""
        from . import converter as _runtime
        text_dir = _runtime.Path(temp_dir) / "text"
        if not text_dir.exists():
            return 0
        target_dir = _runtime.Path(output_dir) / "text"
        target_dir.mkdir(parents=True, exist_ok=True)
        copied = 0
        for txt_file in text_dir.glob("*.txt"):
            target_path = target_dir / txt_file.name
            try:
                _runtime.shutil.copy2(txt_file, target_path)
                copied += 1
            except OSError:
                continue
        if self.verbose and copied:
            print(f"[DEBUG] Synced {copied} text file(s) to output/text")
        return copied

    def _generate_full_book_text(self, output_dir: Path, chapters: List[Chapter]) -> Optional[Path]:
        """Generate a single TXT file with the complete book text."""
        try:
            if not chapters:
                return None

            text_dir = output_dir / "text"
            if not text_dir.exists():
                text_dir.mkdir(parents=True, exist_ok=True)

            # Use book title from config or first chapter
            book_title = "book_complete"
            if self._active_config:
                book_title = getattr(self._active_config, "book_title", None) or book_title

            safe_title = self.file_manager.sanitize_filename(book_title)
            full_book_file = output_dir / f"{safe_title}_complete.txt"

            # Collect all chapter texts in order
            full_text_parts = []
            for idx, chapter in enumerate(chapters, start=1):
                self._chapter_number(chapter, idx)
                chapter_label = self._chapter_index_label(chapter, idx)
                chapter_name = getattr(chapter, "name", None) or f"Chapter {chapter_label}"
                # Remove duplicate prefix
                chapter_name_clean = self._remove_duplicate_chapter_prefix(
                    chapter_label, chapter_name
                )

                # Add chapter header (use original name for display)
                full_text_parts.append(f"\n{'=' * 70}\n")
                full_text_parts.append(f"CHAPTER {chapter_label}: {chapter_name}\n")
                full_text_parts.append(f"{'=' * 70}\n\n")

                # Try to find pre-tts.txt first (final processed text)
                safe_name = self.file_manager.sanitize_filename(chapter_name_clean)
                pre_tts_file = text_dir / f"{chapter_label} - {safe_name}-pre-tts.txt"
                parsed_file = text_dir / f"{chapter_label} - {safe_name}-parsed.txt"

                text_content = None
                if pre_tts_file.exists():
                    text_content = pre_tts_file.read_text(encoding="utf-8")
                elif parsed_file.exists():
                    text_content = parsed_file.read_text(encoding="utf-8")
                else:
                    # Fallback to chapter text
                    text_content = self._speech_text(chapter)

                if text_content:
                    full_text_parts.append(text_content.strip())
                    full_text_parts.append("\n\n")

            # Write complete book text (remove legacy *_completo.txt if present)
            for legacy in output_dir.glob("*_completo.txt"):
                try:
                    legacy.unlink()
                except OSError:
                    pass
            full_book_file.write_text("".join(full_text_parts), encoding="utf-8")

            if self.verbose:
                print(f"\n📖 Complete book text generated: {full_book_file.name}")
                print(f"   Total: {len(''.join(full_text_parts)):,} chars")

            return full_book_file

        except Exception as exc:
            if self.verbose:
                print(f"⚠️ Failure generating complete book text: {exc}")
            return None
