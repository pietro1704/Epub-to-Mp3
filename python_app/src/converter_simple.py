# -*- coding: utf-8 -*-
"""
Simplified converter without checkpoint system - just checks if MP3 exists
"""

from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional

from .config import ConversionConfig
from .ebook_reader import Chapter, EbookReader
from .i18n import Localization, get_localization
from .progress import ProgressTracker
from .tts.factory import TTSFactory
from .utils import AudioProcessor, FileManager, resolve_cache_root


@dataclass
class ConversionResult:
    """Result of audio conversion"""

    success: bool
    output_paths: List[Path]
    total_chapters: int
    completed_chapters: int
    total_duration: float = 0.0
    error_message: Optional[str] = None


class SimpleAudioConverter:
    """Simple audio converter with MP3-based caching"""

    def __init__(self, localization: Optional[Localization] = None):
        self.tts_factory = TTSFactory()
        self.audio_processor = AudioProcessor()
        self.file_manager = FileManager()
        self.progress = ProgressTracker()
        self.loc = localization or get_localization()
        self.verbose = False

    @staticmethod
    def _chapter_number(chapter: Chapter, fallback: int) -> int:
        raw = getattr(chapter, "index", None)
        if raw is None:
            return fallback
        try:
            if isinstance(raw, str):
                text = raw.strip()
                if not text:
                    return fallback
                if text.replace(".", "", 1).isdigit():
                    raw = float(text) if "." in text else int(text)
                else:
                    return fallback
            value = int(raw)
        except Exception:
            try:
                value = int(float(raw))  # type: ignore[arg-type]
            except Exception:
                return fallback
        return value if value > 0 else fallback

    async def convert(self, config: ConversionConfig, reader: EbookReader) -> ConversionResult:
        """Convert ebook to audiobook with simple MP3 cache check"""
        self.verbose = getattr(config, "verbose", False)

        if self.verbose:
            print("🔍 [VERBOSE] SimpleAudioConverter.convert() iniciado")

        output_dir = self._setup_output_directory(config)
        chapters = list(
            reader.get_chapter_structure(preserve_all=config.preserve_all_chapters) or []
        )
        total_chapters = len(chapters)

        if self.verbose:
            print(f"🔍 [VERBOSE] Total chapters: {total_chapters}")
            print(f"🔍 [VERBOSE] Output directory: {output_dir}")

        try:
            # Setup TTS engine
            engine = self.tts_factory.create_engine(config)

            # Track conversion progress
            self.progress.start(total_chapters)

            output_paths = []
            completed_count = 0

            for idx, chapter in enumerate(chapters, start=1):
                chapter_num = self._chapter_number(chapter, idx)

                # Generate expected MP3 filename
                output_filename = self.file_manager.build_output_filename(
                    chapter.name or f"Chapter {chapter_num}", chapter_num
                )
                output_path = output_dir / output_filename

                # Simple cache check: skip if MP3 already exists
                if output_path.exists() and not getattr(config, "force_reprocess", False):
                    if self.verbose:
                        print(f"✅ Chapter {chapter_num} already exists: {output_path}")
                    self.progress.tick("✅ Already exists (cache)")
                    self.progress.complete_chapter("✅ Cache")
                    output_paths.append(output_path)
                    completed_count += 1
                    continue

                # Convert chapter
                self.progress.tick(f"🔄 Converting chapter {chapter_num}")

                try:
                    # Synthesize chapter text to MP3
                    await engine.synthesize_async(chapter.text, output_path)

                    # Validate generated audio
                    if self.audio_processor.validate_audio_file(output_path):
                        output_paths.append(output_path)
                        completed_count += 1
                        self.progress.complete_chapter("✅ Completo")

                        if self.verbose:
                            print(f"✅ Chapter {chapter_num} converted: {output_path}")
                    else:
                        self.progress.complete_chapter("❌ Validation failed")
                        if self.verbose:
                            print(f"❌ Validation failed for chapter {chapter_num}")

                except Exception as e:
                    self.progress.complete_chapter(f"❌ Error: {str(e)[:30]}")
                    if self.verbose:
                        print(f"❌ Error in chapter {chapter_num}: {e}")
                    continue

            # Calculate total duration (simplified)
            total_duration = 0.0
            for path in output_paths:
                if path.exists():
                    try:
                        # Simple duration estimation based on file size
                        size_mb = path.stat().st_size / (1024 * 1024)
                        total_duration += size_mb * 60  # Rough estimate: 1MB ≈ 1 minute
                    except OSError:
                        pass

            success = completed_count > 0

            return ConversionResult(
                success=success,
                output_paths=output_paths,
                total_chapters=total_chapters,
                completed_chapters=completed_count,
                total_duration=total_duration,
            )

        except Exception as e:
            return ConversionResult(
                success=False,
                output_paths=[],
                total_chapters=total_chapters,
                completed_chapters=0,
                error_message=str(e),
            )
        finally:
            pass  # Progress tracker cleanup not needed

    def _setup_output_directory(self, config: ConversionConfig) -> Path:
        """Setup output directory for MP3 files"""
        base_dir = Path(config.output_dir) if config.output_dir else resolve_cache_root()
        if config.book_title:
            base_dir = base_dir / self.file_manager.sanitize_filename(config.book_title)
        engine_suffix = self.file_manager.build_engine_voice_suffix(
            engine=getattr(config, "engine", None),
            voice=getattr(config, "voice", None),
            model_path=getattr(config, "model_path", None),
        )
        base_dir = base_dir / engine_suffix
        return self.file_manager.ensure_directory(base_dir)


__all__ = ["SimpleAudioConverter", "ConversionResult"]
