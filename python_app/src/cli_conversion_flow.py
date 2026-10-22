"""Conversion flow for the retained legacy CLI."""

from .cli_runtime_dependencies import List as List
from .cli_runtime_dependencies import argparse as argparse


class CLIConversionFlow:
    def _run_single_conversion(
        self,
        args: argparse.Namespace,
        *,
        hardware_profile=None,
    ) -> int:
        """Main application entry point"""
        conversion_start = self._cli_runtime.time.time()
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
            input_path = self._cli_runtime.Path(getattr(args, "input_file", "")).expanduser()
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
            reader = self._cli_runtime.EbookReader(str(input_path))

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

            # Combined .cache/ + output/ budget enforcement (LRU + TTL).
            # Runs once at CLI start so disk usage stays bounded even
            # during heavy development use.
            try:
                from src.storage_budget import evict_storage_budget

                evict_storage_budget(self.cache_root, self._cli_runtime.OUTPUT_DIR)
            except Exception:
                pass

            input_path, cleanup_exit = self._clear_requested_book_outputs(
                args, reader, structure_items, selectors, cache_manager, input_path
            )
            if cleanup_exit is not None:
                return cleanup_exit

            cache_dir = self._resolve_cache_dir(reader)
            cache_dir.mkdir(parents=True, exist_ok=True)
            setattr(args, "cache_dir", cache_dir)

            # Set temp directory to .cache/{book name}
            book_name = self._cli_runtime.Path(args.input_file).stem
            temp_dir = self.cache_root / book_name

            if getattr(args, "no_cache", False):
                self._clear_no_cache_target(cache_manager, input_path, reader)

            # Ensure the temp directory is inside .cache
            book_name = self._cli_runtime.Path(args.input_file).stem
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
                self.language_profile = self._cli_runtime.LanguageProfile(
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
                self._cli_runtime.os.environ["ENGINE_CHAIN_FALLBACK"] = "1"
                try:
                    import src.converter as _cv

                    _cv.ENGINE_CHAIN_FALLBACK = True
                except Exception:
                    pass

            fallback_pref = self._cli_runtime._resolve_cli_fallback_engine(
                getattr(args, "fallback_engine", "auto"),
                self._cli_runtime.os.getenv("FALLBACK_ENGINE_OVERRIDE"),
            )
            if fallback_pref:
                self.converter._cli_fallback_engine = fallback_pref

            if getattr(args, "prewarm_edge", False):
                self._cli_runtime._prewarm_edge_pipeline(getattr(config, "voice", None))
            if getattr(args, "prewarm_piper", False):
                self._cli_runtime._prewarm_piper_pipeline(getattr(config, "primary_language", None))

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
                result = self._cli_runtime.ConversionResult(
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
                result = self._cli_runtime.asyncio.run(self.converter.convert(reader, config))

            elapsed = self._cli_runtime.time.time() - conversion_start
            print(f"⏱️ Total conversion time: {self._format_hms(elapsed)}")
            self._finish_cli_conversion(
                args, reader, structure_items, config, result, elapsed, conversion_start, temp_dir
            )

            if isinstance(result, self._cli_runtime.ConversionResult):
                return 0 if result.success else 1
            if isinstance(result, int):
                return result
            if isinstance(result, bool):
                return 0 if result else 1
            return 0

        except Exception as e:
            self._cli_runtime.traceback.print_exc()
            print(self.localization.t("unexpected_error", error=e))
            return 1
