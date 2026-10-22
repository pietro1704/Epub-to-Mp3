"""Run the final serial conversion recovery and restore temporary environment state."""

from __future__ import annotations

import os
from pathlib import Path
from typing import List, Optional

from .config import ConversionConfig


class LastResortRecovery:
    async def _last_resort_recovery(
        self,
        *,
        epub_path: Path,
        output_dir: Path,
        chapter_selectors: Optional[List[str]],
        reason: str,
    ) -> bool:
        """Final anti-stall recovery path: stable engine, serial run, strict re-validation."""
        config = self._active_config
        if not config:
            return False

        if self.verbose:
            print("\n🛟 LAST-RESORT RECOVERY")
            print(f"   Reason: {reason}")

        from validate_conversion import validate_book

        from .ebook_reader import EbookReader

        engine_name = (getattr(config, "engine", "") or "edge").lower()
        try:
            from .tts.factory import TTSFactory

            available = set(TTSFactory().available_engines())
        except Exception:
            available = set()

        # Honour `--fallback-engine none`: if the operator forbade
        # falling back, the last-resort path must keep using the
        # requested engine instead of jumping to piper (the
        # Carl regression — Piper would emit 16 kHz English-tinged
        # audio for pt-BR text).
        cli_fallback = (getattr(self, "_cli_fallback_engine", None) or "").lower()
        if cli_fallback == "none":
            pass  # keep the originally requested engine
        elif "piper" in available:
            engine_name = "piper"
        elif "edge" in {"edge"}:
            engine_name = "edge"

        reader = EbookReader(str(epub_path))
        try:
            from python_app.main import ConverterApplication

            app = ConverterApplication()
            preview_config = app.config.create_conversion_config(
                engine=engine_name,
                output_dir=str(output_dir.parent),
                book_title=reader.title,
                preserve_all_chapters=True,
            )
            preview_config.footnote_mode = "inline"
            preview_config.footnote_context_words = app.FOOTNOTE_CONTEXT_WORDS
            structure_items = app._generate_structure_items(reader, filter_chapters=False)
            structure_items = app._apply_text_transforms(structure_items, preview_config, reader)
            app._apply_structure_to_reader(reader, structure_items)
        except Exception as exc:
            if self.verbose:
                print(f"⚠️  Last-resort: failed to apply transforms ({exc})")

        chapter_indices: List[str] = []
        if chapter_selectors:
            all_chapters = reader.get_chapter_structure(preserve_all=True)
            chapter_indices = self._resolve_problem_chapter_indices(all_chapters, chapter_selectors)

        retry_config = ConversionConfig(
            engine=engine_name,
            voice=config.voice,
            output_dir=str(output_dir.parent),
            book_title=reader.title,
            preserve_all_chapters=True,
            force_reprocess=True,
            clear_cache=False,
            auto_validate_output=False,
            auto_fix_output=False,
        )
        # Preserve language affinity in last-resort mode so offline engines
        # (especially Piper) don't fall back to an unrelated default model.
        retry_lang = (
            getattr(config, "primary_language", None)
            or getattr(reader, "language", None)
            or "pt-BR"
        )
        retry_config.primary_language = str(retry_lang)
        retry_config.languages = [str(retry_lang)]
        retry_config.extra["disable_chunk_resume"] = "1"
        if chapter_indices:
            retry_config.extra["chapter_whitelist"] = ",".join(chapter_indices)

        if self.verbose:
            target = f"{len(chapter_indices)} chapter(s)" if chapter_indices else "full book"
            print(f"   Engine: {engine_name} | Target: {target} | Parallel: serial safe mode")

        env_backup = {
            "CHAPTER_PARALLEL_COUNT": os.environ.get("CHAPTER_PARALLEL_COUNT"),
            "CHAPTER_PARALLEL_MAX": os.environ.get("CHAPTER_PARALLEL_MAX"),
            "EDGE_ENABLE_PARALLEL": os.environ.get("EDGE_ENABLE_PARALLEL"),
        }
        os.environ["CHAPTER_PARALLEL_COUNT"] = "1"
        os.environ["CHAPTER_PARALLEL_MAX"] = "1"
        os.environ["EDGE_ENABLE_PARALLEL"] = "false"
        try:
            await self.convert(reader, retry_config)
        except Exception as exc:
            if self.verbose:
                print(f"⚠️  Last-resort conversion failed: {exc}")
            return False
        finally:
            for key, old in env_backup.items():
                if old is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = old

        stats_after, _issues_after = validate_book(
            epub_path,
            output_dir,
            cache_dir=Path(getattr(config, "cache_dir", ""))
            if getattr(config, "cache_dir", None)
            else None,
            duration_tolerance=1.50,
        )
        critical = any(
            stats_after.get(key, 0) > 0
            for key in ("missing_cache", "text_mismatch", "parsed_pretts_diff", "missing_mp3")
        )
        if not critical:
            if self.verbose:
                print("   ✅ Last-resort recovery succeeded.")
            return True
        if self.verbose:
            print("   ❌ Last-resort recovery still has critical validation problems.")
        return False
