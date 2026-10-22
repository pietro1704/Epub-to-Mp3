"""Cache policy for the retained legacy CLI."""

from . import cli_runtime_dependencies as _shared_cli_runtime_dependencies
from .cli_runtime_dependencies import ChapterStructureItem as ChapterStructureItem
from .cli_runtime_dependencies import ConversionConfig as ConversionConfig
from .cli_runtime_dependencies import EbookReader as EbookReader
from .cli_runtime_dependencies import List as List
from .cli_runtime_dependencies import Optional as Optional
from .cli_runtime_dependencies import Path as Path
from .cli_runtime_dependencies import Set as Set
from .cli_runtime_dependencies import Tuple as Tuple
from .cli_runtime_dependencies import argparse as argparse

FileManager = _shared_cli_runtime_dependencies.FileManager
shutil = _shared_cli_runtime_dependencies.shutil

class CLICachePolicy:
    def _resolve_book_output_dir(self, reader: EbookReader, config: ConversionConfig) -> Path:
        """The directory the converter writes MP3s into.

        Mirrors the path the converter assembles:
        ``<output_root>/<sanitised(book_title)>/``. Used for both
        existing-output detection (skip re-conversion when the book is
        already there) and the iPhone export step.
        """
        title = getattr(config, "book_title", "") or getattr(reader, "title", "") or "default"
        output_root = self._cli_runtime.Path(getattr(config, "output_dir", None) or self._cli_runtime.OUTPUT_DIR)
        return output_root / self._cli_runtime.FileManager.sanitize_filename(title)

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
            digest = self._cli_runtime.hashlib.blake2b("\n".join(entries).encode("utf-8"), digest_size=20).hexdigest()
            return count, digest

        cached_count: Optional[int] = None
        if cache_state_path.exists():
            try:
                state = self._cli_runtime.json.loads(cache_state_path.read_text(encoding="utf-8"))
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
                    self._cli_runtime.json.dumps(
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
            cache_dir = self.cache_root / self._cli_runtime.FileManager.sanitize_filename(
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
                    with self._cli_runtime.contextlib.suppress(OSError):
                        path.unlink()
                        removed += 1
            if removed:
                print(
                    f"🧹 Cache cleanup: removed {removed} stale MP3(s) that no "
                    "longer match the current chapter list"
                )
        except Exception:
            pass

    def _resolve_cache_dir(self, reader: EbookReader) -> Path:
        """Resolve shared cache directory path for this book."""
        base_name = getattr(reader, "title", None) or getattr(reader, "file_path", None) or "livro"
        sanitized = self._cli_runtime.FileManager.sanitize_filename(base_name) or "livro"
        return self._cli_runtime.resolve_cache_root() / sanitized

    @staticmethod
    def _clear_no_cache_target(cache_manager, input_path: Path, reader: EbookReader) -> bool:
        """Clear only the selected book's cache for ``--no-cache``.

        The cache root is shared by conversions, so removing it would destroy
        resumable state for unrelated books (especially in batch mode).
        ``CacheManager`` knows both the source-filename and metadata-title
        cache identities and removes the matching checkpoint as well.
        """
        cleared = cache_manager.clear_cache(
            input_path,
            title=getattr(reader, "title", None),
        )
        if cleared:
            print("🗑️ Cache cleared for the selected book due to --no-cache")
        return cleared

    def _handle_clear_cache(self, args: Optional[argparse.Namespace] = None) -> int:
        """Clear cache/output for a specific book, or globally with confirmation."""
        from src.cache_manager import CacheManager

        book_arg = getattr(args, "book", None) if args else None
        if book_arg:
            return self._handle_clear_cache_for_book(book_arg)

        cache_manager = CacheManager(cache_dir=self._cli_runtime.resolve_cache_root())
        cache_root = self._cli_runtime.resolve_cache_root()
        output_dir = self._cli_runtime.OUTPUT_DIR

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
                self._cli_runtime.shutil.rmtree(output_dir, ignore_errors=True)
                print(f"   ✅ Output directory removed: {output_dir}")
                removed_items += 1
            except Exception as e:
                print(f"   ⚠️ Error removing output: {e}")

        # Remove queues/persistent states
        residual_dirs = [
            self._cli_runtime.JOBS_DIR,
            self._cli_runtime.UPLOADS_DIR,
            self._cli_runtime.JOB_INPUTS_DIR,
            self._cli_runtime.Path.cwd() / ".jobs",
            self._cli_runtime.Path.cwd() / ".uploads",
            self._cli_runtime.Path.cwd() / ".job_inputs",
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
                    self._cli_runtime.shutil.rmtree(residual, ignore_errors=True)
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

        book_path = self._cli_runtime.Path(book_path_str)
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

        cache_manager = CacheManager(cache_dir=self._cli_runtime.resolve_cache_root())
        cache_manager.clear_cache(book_path, title=title)

        # Remove output directories that match the sanitized title (with or without engine suffix)
        output_base = self._cli_runtime.OUTPUT_DIR
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
