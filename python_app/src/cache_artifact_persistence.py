"""Filesystem layout, model buckets and persistence of reusable conversion artifacts."""

from __future__ import annotations

import contextlib
import json
import shutil
from pathlib import Path
from typing import List, Optional

from ._cache_helpers import compute_cache_model_bucket
from .config import ConversionConfig
from .ebook_reader import Chapter
from .utils import FileManager


class CacheArtifactPersistence:
    """Own cache artifact I/O while the host supplies chapter identity and text hashes."""

    def _load_cache_index(self, cache_dir: Optional[Path]) -> dict:
        if not cache_dir:
            return {}
        try:
            index_path = Path(cache_dir) / "cache_index.json"
            if index_path.exists():
                return json.loads(index_path.read_text(encoding="utf-8"))
        except Exception:
            return {}
        return {}

    def _save_cache_index(self, cache_dir: Optional[Path], index: dict) -> None:
        if not cache_dir:
            return
        try:
            index_path = Path(cache_dir) / "cache_index.json"
            index_path.parent.mkdir(parents=True, exist_ok=True)
            index_path.write_text(json.dumps(index, indent=2, ensure_ascii=False), encoding="utf-8")
        except Exception:
            pass

    def _find_pre_tts_path(
        self,
        cache_dir: Optional[Path],
        output_dir: Optional[Path],
        index: int,
        chapter_name: Optional[str],
        index_label: Optional[str] = None,
    ) -> Optional[Path]:
        """Locate the pre-tts text for hashing, checking both temp and cache layouts."""
        safe_name = FileManager.sanitize_filename(chapter_name or f"Chapter {index}")
        label = index_label or str(index)
        candidates: List[Path] = []
        if output_dir:
            text_dir = Path(output_dir) / "text"
            candidates.append(text_dir / f"{label} - {safe_name}-pre-tts.txt")
            candidates.append(text_dir / f"{index} - {safe_name}-pre-tts.txt")
        if cache_dir:
            candidates.append(Path(cache_dir) / "text" / f"{index:03d} - {safe_name}.txt")
            safe_cache = safe_name.replace(" ", "_")
            candidates.append(Path(cache_dir) / "text" / f"{index:03d}_{safe_cache}.txt")
        for cand in candidates:
            if cand.exists():
                return cand
        return None

    def _find_cached_audio_path(
        self, cache_dir: Optional[Path], config: ConversionConfig, chapter_name: str, index: int
    ) -> Optional[Path]:
        """Locate an existing cached MP3 inside the cache/audio buckets."""
        if not cache_dir:
            return None
        try:
            cache_dir = Path(cache_dir)
            model_bucket = self._cache_model_bucket(config)
            target_dir = cache_dir / "audio"
            if model_bucket:
                target_dir /= model_bucket
            safe_name = FileManager.sanitize_filename(chapter_name or f"Chapter {index}")
            legacy_name = safe_name.replace(" ", "_")
            candidates = [
                target_dir / f"{index:03d} - {safe_name}.mp3",
                target_dir / f"{index:03d}_{legacy_name}.mp3",
            ]
            for candidate in candidates:
                if candidate.exists() and candidate.stat().st_size > 1000:
                    return candidate
        except Exception:
            return None
        return None

    def _segment_plan_path(self, cache_dir: Optional[Path], index: int) -> Optional[Path]:
        if not cache_dir:
            return None
        try:
            return Path(cache_dir) / "plan" / f"{index:03d}.json"
        except Exception:
            return None

    def _save_segment_plan(
        self, cache_dir: Optional[Path], index: int, segments: List[str], config: ConversionConfig
    ) -> None:
        plan_path = self._segment_plan_path(cache_dir, index)
        if not plan_path:
            return
        try:
            plan_path.parent.mkdir(parents=True, exist_ok=True)
            plan = {
                "segments": segments,
                "chunk_chars": getattr(config, "edge_chunk_chars", None),
                "max_segment_seconds": getattr(config, "edge_max_segment_seconds", None),
            }
            plan_path.write_text(json.dumps(plan, ensure_ascii=False), encoding="utf-8")
        except Exception:
            pass

    def _load_segment_plan(
        self,
        cache_dir: Optional[Path],
        index: int,
        *,
        chunk_chars: Optional[int] = None,
    ) -> Optional[List[str]]:
        plan_path = self._segment_plan_path(cache_dir, index)
        if not plan_path or not plan_path.exists():
            return None
        try:
            data = json.loads(plan_path.read_text(encoding="utf-8"))
            segments = data.get("segments")
            plan_chunk = data.get("chunk_chars")
            if chunk_chars and plan_chunk and int(plan_chunk) != int(chunk_chars):
                return None
            if isinstance(segments, list) and segments:
                return [str(s) for s in segments]
        except Exception:
            return None
        return None

    def _cleanup_temp_audio(self, temp_dir: Path) -> None:
        temp_dir = Path(temp_dir)
        if not temp_dir.exists():
            return

        patterns = ("*.mp3", "*.wav", "*.ogg")
        for pattern in patterns:
            for candidate in temp_dir.glob(pattern):
                try:
                    candidate.unlink()
                except FileNotFoundError:
                    continue
                except OSError:
                    if self.verbose:
                        print(f"⚠️ Could not remove temporary file: {candidate}")

        audio_cache = temp_dir / "audio"
        if audio_cache.exists():
            try:
                shutil.rmtree(audio_cache, ignore_errors=True)
            except OSError:
                if self.verbose:
                    print(f"⚠️ Could not clean audio cache: {audio_cache}")

    def _cache_audio(
        self,
        cache_dir: Optional[Path],
        audio_path: Path,
        chapter: Chapter,
        index: int,
        config: ConversionConfig,
        *,
        text_root: Optional[Path] = None,
    ) -> None:
        if not cache_dir:
            return
        try:
            cache_dir = Path(cache_dir)
            model_bucket = self._cache_model_bucket(config)
            target_dir = cache_dir / "audio"
            if model_bucket:
                target_dir /= model_bucket
            target_dir.mkdir(parents=True, exist_ok=True)
            chapter_name = getattr(chapter, "name", None) or f"Chapter {index}"
            safe_name = FileManager.sanitize_filename(chapter_name)
            target_path = target_dir / f"{index:03d} - {safe_name}.mp3"
            if not target_path.exists() or target_path.stat().st_mtime < audio_path.stat().st_mtime:
                shutil.copy2(audio_path, target_path)

            # Update cache index with hash/size if we have pre-tts text
            cache_index = self._load_cache_index(cache_dir)
            index_label = self._chapter_index_label(chapter, index)
            pre_tts_path = self._find_pre_tts_path(
                cache_dir,
                text_root or audio_path.parent,
                index,
                chapter_name,
                index_label=index_label,
            )
            pre_tts_hash = None
            if pre_tts_path and pre_tts_path.exists():
                with contextlib.suppress(Exception):
                    pre_tts_hash = self._hash_text(pre_tts_path.read_text(encoding="utf-8"))
            entry = cache_index.get(index_label) or cache_index.get(str(index)) or {}
            entry.update(
                {
                    "path": str(target_path),
                    "size": target_path.stat().st_size if target_path.exists() else 0,
                    "pre_tts_hash": pre_tts_hash,
                }
            )
            cache_index[index_label] = entry
            self._save_cache_index(cache_dir, cache_index)
        except OSError:
            pass

    @staticmethod
    def _cache_model_bucket(config: ConversionConfig) -> Optional[str]:
        return compute_cache_model_bucket(config)

    @staticmethod
    def _cache_text(
        cache_dir: Optional[Path],
        chapter: Chapter,
        index: int,
        text: str,
    ) -> None:
        if not cache_dir or not text:
            return
        try:
            cache_dir = Path(cache_dir)
            target_dir = cache_dir / "text"
            target_dir.mkdir(parents=True, exist_ok=True)
            chapter_name = getattr(chapter, "name", None) or f"Chapter {index}"
            safe_name = FileManager.sanitize_filename(chapter_name)
            base_name = f"{index:03d} - {safe_name}"
            target_path = target_dir / f"{base_name}.txt"
            pre_tts_path = target_dir / f"{base_name}-pre-tts.txt"
            parsed_path = target_dir / f"{base_name}-parsed.txt"
            parsed_text = getattr(chapter, "text", None) or ""
            target_path.write_text(text, encoding="utf-8")
            pre_tts_path.write_text(text, encoding="utf-8")
            parsed_path.write_text(parsed_text, encoding="utf-8")
        except OSError:
            pass
