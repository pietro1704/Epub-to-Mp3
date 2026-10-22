"""Book cache cleanup for the retained legacy CLI."""

class CLIBookCacheCleanup:
    def _clear_requested_book_outputs(self, args, reader, structure_items, selectors, cache_manager, input_path):
        if getattr(args, "clear_cache", False):
            input_path = (
                self._cli_runtime.Path(getattr(args, "input_file", ""))
                if getattr(args, "input_file", None)
                else None
            )
            if input_path:
                display_name = reader.title or input_path.stem
                output_base = self._cli_runtime.Path(getattr(args, "output_dir", None) or self._cli_runtime.OUTPUT_DIR)
                sanitized_title = self._cli_runtime.FileManager.sanitize_filename(display_name)

                if selectors:
                    # Chapter-specific: clear only selected chapters' cache and output
                    safe_book_title = self._cli_runtime.FileManager.sanitize_filename(
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
                            self._cli_runtime.shutil.rmtree(stream_dir, ignore_errors=True)
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
                                    with self._cli_runtime.contextlib.suppress(OSError):
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
                    # (ex: "Book_edge", "Book_piper")
                    removed_count = 0
                    if output_base.exists():
                        for output_dir in output_base.iterdir():
                            if output_dir.is_dir() and (
                                output_dir.name == sanitized_title
                                or output_dir.name.startswith(f"{sanitized_title}_")
                            ):
                                try:
                                    self._cli_runtime.shutil.rmtree(output_dir, ignore_errors=True)
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
                return input_path, self._handle_clear_cache()

        return input_path, None
