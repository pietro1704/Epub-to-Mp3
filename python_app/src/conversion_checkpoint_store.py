"""Persist and validate resumable conversion checkpoints independently of text caching."""

import hashlib
import json
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional


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



class ConversionCheckpointStore:
    """Checkpoint operations bound to the host cache directory and filename policy."""

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
