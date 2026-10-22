"""Persist resumable failed-chapter identities and partial chunk inventory."""

from __future__ import annotations

import contextlib
import json
import time
from pathlib import Path
from typing import Any, Dict, Iterable, Optional


class FailureCheckpointStore:
    @staticmethod
    def _failure_checkpoint_path(output_dir: Optional[Path]) -> Optional[Path]:
        if not output_dir:
            return None
        try:
            base = Path(output_dir)
            base.mkdir(parents=True, exist_ok=True)
            return base / "_failure_checkpoint.json"
        except Exception:
            return None

    def _load_failure_checkpoint(self, output_dir: Optional[Path]) -> Dict[str, Any]:
        path = self._failure_checkpoint_path(output_dir)
        if path is None or not path.exists():
            return {}
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
            return payload if isinstance(payload, dict) else {}
        except Exception:
            return {}

    def _save_failure_checkpoint(
        self,
        output_dir: Optional[Path],
        *,
        failed_chapters: Iterable[str],
        edge_blocked_chapters: Optional[Iterable[str]] = None,
    ) -> None:
        path = self._failure_checkpoint_path(output_dir)
        if path is None:
            return
        try:
            failed = sorted({str(item).strip() for item in failed_chapters if str(item).strip()})
            blocked = sorted(
                {str(item).strip() for item in (edge_blocked_chapters or []) if str(item).strip()}
            )
            resume_chunks: Dict[str, Dict[str, int]] = {}
            chunks_root = path.parent / "chunks"
            if chunks_root.exists():
                for chapter_dir in chunks_root.glob("chapter_*"):
                    if not chapter_dir.is_dir():
                        continue
                    chunk_files = list(chapter_dir.glob("chunk_*.mp3"))
                    manifest_entries = 0
                    manifest_path = chapter_dir / "manifest.json"
                    if manifest_path.exists():
                        with contextlib.suppress(Exception):
                            manifest_data = json.loads(manifest_path.read_text(encoding="utf-8"))
                            if isinstance(manifest_data, list):
                                manifest_entries = len(manifest_data)
                    resume_chunks[chapter_dir.name] = {
                        "chunk_files": len(chunk_files),
                        "manifest_entries": manifest_entries,
                    }
            payload = {
                "updated_at": time.time(),
                "failed_chapters": failed,
                "edge_blocked_chapters": blocked,
                "resume_chunks": resume_chunks,
            }
            path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        except Exception:
            if self.verbose:
                print("⚠️ Failed to save failure checkpoint")

    def _clear_failure_checkpoint(self, output_dir: Optional[Path]) -> None:
        path = self._failure_checkpoint_path(output_dir)
        if path is None:
            return
        with contextlib.suppress(OSError):
            path.unlink(missing_ok=True)
