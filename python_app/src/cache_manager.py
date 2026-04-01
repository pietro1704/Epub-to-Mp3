# -*- coding: utf-8 -*-
"""
Cache manager for processed ebooks
"""

import hashlib
import json
import shutil
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional

from .paths import CACHE_DIR


@dataclass
class ConversionCheckpoint:
    """Checkpoint state of a conversion"""

    book_path: str
    book_title: str
    output_dir: str
    temp_dir: str
    total_chapters: int
    completed_chapters: List[int]
    current_chapter: Optional[int]
    conversion_config: Dict[str, Any]
    started_at: str
    last_updated: str


class CacheManager:
    """Smart cache manager for ebooks"""

    # Directories that should not be deleted by a global cleanup (models, telemetry, etc.)
    _PROTECTED_DIRS = {
        "telemetry",
        "coqui_models",
        "piper_models",
        "models",
        "hf_models",
        "huggingface",
        "hf_cache",
        "transformers",
    }

    def __init__(self, cache_dir: Optional[Path] = None):
        # In-memory cache for the current session (avoids redundant disk reads)
        self._memory_cache: Dict[str, Dict[str, Any]] = {}
        try:
            # Always uses CACHE_DIR from project root, unless explicitly provided
            self.cache_dir = Path(cache_dir) if cache_dir else CACHE_DIR
            self.cache_dir.mkdir(parents=True, exist_ok=True)
        except (PermissionError, OSError) as e:
            print(f"⚠️ Cache disabled: no write permission ({e})")
            print(f"💡 Tip: check the directory permissions for {CACHE_DIR}")
            # Fallback to None - cache operations will be no-ops
            self.cache_dir = None

    def _get_ebook_hash(self, ebook_path: Path) -> str:
        """Generate unique hash for the ebook"""
        # Uses file stat + name to generate unique hash
        stat = ebook_path.stat()
        hash_input = f"{ebook_path.name}_{stat.st_size}_{stat.st_mtime}"
        return hashlib.md5(hash_input.encode()).hexdigest()[:12]

    def _get_cache_path(self, ebook_path: Path, *, override_name: Optional[str] = None) -> Path:
        """Return cache path using only the book filename

        IMPORTANT: Always uses the filename as base, NOT the book title,
        to avoid creating duplicate folders when title != filename
        """
        if self.cache_dir is None:
            # Fallback to temporary directory
            import tempfile

            return Path(tempfile.gettempdir()) / "epub_to_mp3_fallback"
        # **FIXED**: Always use ebook_path.stem, ignore override_name
        # to avoid creating multiple folders for the same book
        source_name = ebook_path.stem
        safe_name = self._sanitize_filename(source_name)
        if not safe_name:
            safe_name = "book"
        return self.cache_dir / safe_name

    def get_cached_chapters(
        self, ebook_path: Path, *, bypass: bool = False
    ) -> Optional[Dict[str, Any]]:
        """Return cached chapters if they exist.

        Args:
            ebook_path: Path to the ebook file.
            bypass: When True, skip all cache reads and return None immediately.
                    Used by --clear-cache to avoid consuming stale cache even if
                    deletion of the cache directory failed or is incomplete.
        """
        if bypass:
            return None
        if self.cache_dir is None:
            return None

        key = str(ebook_path.resolve())
        if key in self._memory_cache:
            return self._memory_cache[key]

        cache_path = self._get_cache_path(ebook_path)
        metadata_file = cache_path / "metadata.json"

        if not metadata_file.exists():
            return None

        try:
            with open(metadata_file, "r", encoding="utf-8") as f:
                metadata = json.load(f)

            # Validate if cache is still valid
            if self._is_cache_valid(metadata, ebook_path):
                self._memory_cache[key] = metadata
                return metadata
            else:
                # Remove invalid cache
                self._cleanup_cache(cache_path)
                return None

        except Exception:
            return None

    def save_chapters_to_cache(self, ebook_path: Path, chapters_data: Dict[str, Any]) -> bool:
        """Save processed chapters to cache"""
        if self.cache_dir is None:
            # Cache disabled - silent operation
            return False

        try:
            ebook_path = Path(ebook_path)
        except TypeError:
            print("⚠️  Invalid ebook path for cache.")
            return False

        if not isinstance(chapters_data, dict):
            print("⚠️  Unexpected chapter data when saving cache.")
            return False

        chapters = chapters_data.get("chapters")
        if chapters is None:
            # No chapters to save is an acceptable condition
            chapters = []
        elif not isinstance(chapters, list):
            print("⚠️  Unexpected format for chapters in cache.")
            return False

        try:
            # **FIXED**: Do not use override_name to avoid duplicate folders
            cache_path = self._get_cache_path(ebook_path)
            cache_path.mkdir(parents=True, exist_ok=True)

            # Create txt subdirectory for chapters, overwriting previous content
            txt_dir = cache_path / "txt"
            if txt_dir.exists():
                shutil.rmtree(txt_dir)
            txt_dir.mkdir(parents=True, exist_ok=True)

            # Save individual chapters as TXT
            for index, chapter in enumerate(chapters, 1):
                if not isinstance(chapter, dict):
                    print("⚠️  Unexpected chapter in cache, skipping invalid entry.")
                    continue

                chapter_title = chapter.get("title", "Chapter")
                chapter_text = chapter.get("text", "") or ""

                chapter_file = (
                    txt_dir / f"{index:03d} - {self._sanitize_filename(str(chapter_title))}.txt"
                )
                with open(chapter_file, "w", encoding="utf-8") as handle:
                    handle.write(chapter_text)

            # **FIX**: Save metadata.json so that get_cached_chapters works
            stat = ebook_path.stat()
            metadata = {
                "title": chapters_data.get("title", "Unknown"),
                "author": chapters_data.get("author", "Unknown"),
                "chapters": chapters_data.get("chapters", []),
                "chapters_count": len(chapters),
                "cached_at": datetime.now().isoformat(),
                "size": stat.st_size,
                "mtime": stat.st_mtime,
            }

            metadata_file = cache_path / "metadata.json"
            with open(metadata_file, "w", encoding="utf-8") as f:
                json.dump(metadata, f, ensure_ascii=False, indent=2)

            self._memory_cache[str(ebook_path.resolve())] = metadata
            return True

        except Exception as exc:
            print(f"⚠️  Error saving cache: {exc}")
            return False

    def _is_cache_valid(self, metadata: Dict[str, Any], ebook_path: Path) -> bool:
        """Validate if the cache is still valid"""
        try:
            stat = ebook_path.stat()
            return metadata.get("size") == stat.st_size and metadata.get("mtime") == stat.st_mtime
        except FileNotFoundError:
            return False

    def _cleanup_cache(self, cache_path: Path):
        """Remove invalid cache"""
        if cache_path.exists() and cache_path.is_dir():
            shutil.rmtree(cache_path, ignore_errors=True)

    def clear_cache(
        self, ebook_path: Optional[Path] = None, *, title: Optional[str] = None
    ) -> bool:
        """Clear the cache for a specific ebook or, globally, only the books.

        Note: model/telemetry directories are preserved to avoid
        repeated and expensive downloads.
        """
        if self.cache_dir is None:
            return False

        removed_any = False

        if ebook_path:
            ebook_path = Path(ebook_path)
            # **FIXED**: Use only the path based on the filename
            # to avoid searching in multiple folders
            candidates = set()
            candidates.add(self._get_cache_path(ebook_path))
            if title:
                safe_title = self._sanitize_filename(str(title))
                if safe_title:
                    candidates.add(self.cache_dir / safe_title)

            for candidate in candidates:
                if candidate.exists() and candidate.is_dir():
                    self._cleanup_cache(candidate)
                    removed_any = True

            checkpoint_path = self._get_checkpoint_path(ebook_path)
            if checkpoint_path.exists():
                checkpoint_path.unlink()
                removed_any = True

            self._memory_cache.pop(str(ebook_path.resolve()), None)
            return removed_any

        self._memory_cache.clear()
        for item in self.cache_dir.iterdir():
            if item.name in self._PROTECTED_DIRS:
                continue
            if item.is_dir():
                self._cleanup_cache(item)
                removed_any = True
            elif item.suffix.lower() == ".json" or item.name.startswith("checkpoint"):
                item.unlink()
                removed_any = True

        return removed_any

    def get_cache_info(self) -> Dict[str, Any]:
        """Return information about the cache"""
        if self.cache_dir is None:
            return {"total_cached_books": 0, "cache_size_mb": 0}

        try:
            if not self.cache_dir.exists():
                return {"total_cached_books": 0, "cache_size_mb": 0}

            cached_books = []
            total_size = 0

            for cache_folder in self.cache_dir.iterdir():
                if cache_folder.is_dir():
                    metadata_file = cache_folder / "metadata.json"
                    if metadata_file.exists():
                        try:
                            with open(metadata_file, "r", encoding="utf-8") as f:
                                metadata = json.load(f)

                            folder_size = sum(
                                f.stat().st_size for f in cache_folder.rglob("*") if f.is_file()
                            )
                            total_size += folder_size

                            cached_books.append(
                                {
                                    "title": metadata.get("title", "Unknown"),
                                    "cached_at": metadata.get("cached_at", ""),
                                    "chapters_count": metadata.get("chapters_count", 0),
                                    "size_mb": folder_size / 1024 / 1024,
                                }
                            )

                        except Exception:
                            continue

            return {
                "total_cached_books": len(cached_books),
                "cache_size_mb": total_size / 1024 / 1024,
                "cached_books": cached_books,
            }

        except Exception:
            return {"total_cached_books": 0, "cache_size_mb": 0}

    def _get_checkpoint_path(self, book_path: Path) -> Path:
        """Generate checkpoint path for the book"""
        if self.cache_dir is None:
            # Fallback to temporary directory
            import tempfile

            temp_cache = Path(tempfile.gettempdir()) / "epub_to_mp3_fallback"
            book_hash = hashlib.md5(str(book_path.absolute()).encode()).hexdigest()[:12]
            safe_name = self._sanitize_filename(book_path.stem)
            return temp_cache / f"{safe_name}_{book_hash}.json"

        book_hash = hashlib.md5(str(book_path.absolute()).encode()).hexdigest()[:12]
        safe_name = self._sanitize_filename(book_path.stem)
        return self.cache_dir / f"{safe_name}_{book_hash}.json"

    def save_checkpoint(
        self,
        book_path: Path,
        book_title: str,
        output_dir: Path,
        temp_dir: Path,
        total_chapters: int,
        completed_chapters: List[int],
        current_chapter: Optional[int],
        conversion_config: Dict[str, Any],
    ) -> bool:
        """Save conversion checkpoint"""
        try:
            checkpoint = ConversionCheckpoint(
                book_path=str(book_path.absolute()),
                book_title=book_title,
                output_dir=str(output_dir),
                temp_dir=str(temp_dir),
                total_chapters=total_chapters,
                completed_chapters=completed_chapters.copy(),
                current_chapter=current_chapter,
                conversion_config=conversion_config,
                started_at=getattr(self, "_conversion_start_time", datetime.now().isoformat()),
                last_updated=datetime.now().isoformat(),
            )

            checkpoint_path = self._get_checkpoint_path(book_path)
            with open(checkpoint_path, "w", encoding="utf-8") as f:
                json.dump(checkpoint.__dict__, f, ensure_ascii=False, indent=2)

            return True

        except Exception as e:
            print(f"⚠️ Error saving checkpoint: {e}")
            return False

    def load_checkpoint(self, book_path: Path) -> Optional[ConversionCheckpoint]:
        """Load conversion checkpoint"""
        try:
            checkpoint_path = self._get_checkpoint_path(book_path)
            if not checkpoint_path.exists():
                return None

            with open(checkpoint_path, "r", encoding="utf-8") as f:
                data = json.load(f)

            return ConversionCheckpoint(**data)

        except Exception as e:
            print(f"⚠️ Error loading checkpoint: {e}")
            return None

    def clear_checkpoint(self, book_path: Path) -> bool:
        """Remove conversion checkpoint."""
        try:
            checkpoint_path = self._get_checkpoint_path(book_path)
            if checkpoint_path.exists():
                checkpoint_path.unlink()
                return True
            return False

        except Exception as e:
            print(f"⚠️ Error removing checkpoint: {e}")
            return False

    def has_checkpoint(self, book_path: Path) -> bool:
        """Check whether a checkpoint exists for the book."""
        checkpoint_path = self._get_checkpoint_path(book_path)
        return checkpoint_path.exists()

    def validate_checkpoint(
        self,
        checkpoint: ConversionCheckpoint,
        current_temp_dir: Path,
        current_config: Dict[str, Any],
    ) -> bool:
        """Validate that checkpoint is compatible with the current conversion."""
        try:
            temp_dir = Path(checkpoint.temp_dir)
            if not temp_dir.exists():
                print(f"⚠️ Temp directory not found: {temp_dir}")
                return False

            for chapter_idx in checkpoint.completed_chapters:
                expected_files = list(temp_dir.glob(f"{chapter_idx:03d} - *.mp3"))
                if not expected_files:
                    expected_files = list(temp_dir.glob(f"{chapter_idx:03d}_*.mp3"))
                if not expected_files:
                    print(f"⚠️ Chapter file {chapter_idx} not found")
                    return False

            if checkpoint.conversion_config.get("engine") != current_config.get("engine"):
                print("⚠️ Different TTS engine — checkpoint incompatible")
                return False

            return True

        except Exception as e:
            print(f"⚠️ Error validating checkpoint: {e}")
            return False

    def get_resume_info(self, checkpoint: ConversionCheckpoint) -> Dict[str, Any]:
        """Return information needed to resume conversion."""
        completed_count = len(checkpoint.completed_chapters)
        remaining_count = checkpoint.total_chapters - completed_count

        elapsed_time = "unknown"
        try:
            started = datetime.fromisoformat(checkpoint.started_at)
            last_updated = datetime.fromisoformat(checkpoint.last_updated)
            elapsed = last_updated - started
            elapsed_time = str(elapsed).split(".")[0]
        except Exception:
            pass

        return {
            "completed_chapters": completed_count,
            "remaining_chapters": remaining_count,
            "progress_percentage": (completed_count / checkpoint.total_chapters) * 100,
            "elapsed_time": elapsed_time,
            "last_updated": checkpoint.last_updated,
            "temp_dir": checkpoint.temp_dir,
        }

    def mark_conversion_start(self):
        """Mark the start of conversion for timing control."""
        self._conversion_start_time = datetime.now().isoformat()

    def list_checkpoints(self) -> List[Dict[str, Any]]:
        """List all available checkpoints."""
        if self.cache_dir is None:
            return []

        checkpoints = []

        for checkpoint_file in self.cache_dir.glob("*.json"):
            try:
                with open(checkpoint_file, "r", encoding="utf-8") as f:
                    data = json.load(f)

                checkpoint = ConversionCheckpoint(**data)
                info = self.get_resume_info(checkpoint)

                checkpoints.append(
                    {
                        "book_title": checkpoint.book_title,
                        "book_path": checkpoint.book_path,
                        "progress": f"{info['completed_chapters']}/{checkpoint.total_chapters}",
                        "percentage": f"{info['progress_percentage']:.1f}%",
                        "last_updated": checkpoint.last_updated,
                        "elapsed_time": info["elapsed_time"],
                    }
                )

            except Exception:
                continue

        return checkpoints

    def get_validation_log_path(self, ebook_path: Path, chapter_number: int) -> Path:
        """
        Return the validation log path for a chapter.

        Args:
            ebook_path: Path to the ebook file
            chapter_number: Chapter number

        Returns:
            Path to the validation log file
        """
        cache_path = self._get_cache_path(ebook_path)
        logs_dir = cache_path / "validation_logs"
        logs_dir.mkdir(parents=True, exist_ok=True)
        return logs_dir / f"chapter_{chapter_number:03d}_validation.json"

    def get_cached_audio_path(
        self, ebook_path: Path, chapter_number: int, chapter_title: str
    ) -> Path:
        """
        Return the cached audio path for a chapter.

        Args:
            ebook_path: Path to the ebook file
            chapter_number: Chapter number
            chapter_title: Chapter title

        Returns:
            Path to the audio file (may not exist yet)
        """
        cache_path = self._get_cache_path(ebook_path)
        audio_dir = cache_path / "audio"
        sanitized_title = self._sanitize_filename(chapter_title)
        return audio_dir / f"{chapter_number:03d} - {sanitized_title}.mp3"

    def _sanitize_filename(self, filename: str) -> str:
        """Sanitize a filename."""
        import re

        safe = re.sub(r'[<>:"/\\|?*]', "", filename)
        safe = re.sub(r"\s+", "_", safe)
        safe = safe.strip("_")
        if not safe:
            return "book"
        return safe[:120]
