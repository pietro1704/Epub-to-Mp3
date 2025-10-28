# -*- coding: utf-8 -*-
"""
Simplified converter without checkpoint system - just checks if MP3 exists
"""

import asyncio
from pathlib import Path
from typing import Optional, List, Union, Any, Dict
from dataclasses import dataclass

from .config import ConversionConfig
from .ebook_reader import EbookReader
from .tts.factory import TTSFactory
from .utils import AudioProcessor, FileManager, TextValidator, resolve_cache_root
from .progress import ProgressTracker
from .i18n import Localization, get_localization


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

    async def convert(self, config: ConversionConfig, reader: EbookReader) -> ConversionResult:
        """Convert ebook to audiobook with simple MP3 cache check"""
        self.verbose = getattr(config, 'verbose', False)

        if self.verbose:
            print("🔍 [VERBOSE] SimpleAudioConverter.convert() iniciado")

        output_dir = self._setup_output_directory(config)
        chapters = list(reader.get_chapter_structure(preserve_all=config.preserve_all_chapters) or [])
        total_chapters = len(chapters)

        if self.verbose:
            print(f"🔍 [VERBOSE] Total de capítulos: {total_chapters}")
            print(f"🔍 [VERBOSE] Diretório de saída: {output_dir}")

        try:
            # Setup TTS engine
            engine = self.tts_factory.create_engine(config)

            # Track conversion progress
            self.progress.start(total_chapters)

            output_paths = []
            completed_count = 0

            for idx, chapter in enumerate(chapters):
                chapter_num = idx + 1

                # Generate expected MP3 filename
                safe_title = self.file_manager.sanitize_filename(chapter.name)
                output_filename = f"{chapter_num:03d} - {safe_title}.mp3"
                output_path = output_dir / output_filename

                # Simple cache check: skip if MP3 already exists
                if output_path.exists() and not getattr(config, 'force_reprocess', False):
                    if self.verbose:
                        print(f"✅ Capítulo {chapter_num} já existe: {output_path}")
                    self.progress.tick("✅ Já existe (cache)")
                    self.progress.complete_chapter("✅ Cache")
                    output_paths.append(output_path)
                    completed_count += 1
                    continue

                # Convert chapter
                self.progress.tick(f"🔄 Convertendo capítulo {chapter_num}")

                try:
                    # Synthesize chapter text to MP3
                    await engine.synthesize_async(chapter.text, output_path)

                    # Validate generated audio
                    if self.audio_processor.validate_audio_file(output_path):
                        output_paths.append(output_path)
                        completed_count += 1
                        self.progress.complete_chapter("✅ Completo")

                        if self.verbose:
                            print(f"✅ Capítulo {chapter_num} convertido: {output_path}")
                    else:
                        self.progress.complete_chapter("❌ Falha na validação")
                        if self.verbose:
                            print(f"❌ Falha na validação do capítulo {chapter_num}")

                except Exception as e:
                    self.progress.complete_chapter(f"❌ Erro: {str(e)[:30]}")
                    if self.verbose:
                        print(f"❌ Erro no capítulo {chapter_num}: {e}")
                    continue

            # Calculate total duration (simplified)
            total_duration = 0.0
            for path in output_paths:
                if path.exists():
                    try:
                        # Simple duration estimation based on file size
                        size_mb = path.stat().st_size / (1024 * 1024)
                        total_duration += size_mb * 60  # Rough estimate: 1MB ≈ 1 minute
                    except:
                        pass

            success = completed_count > 0

            return ConversionResult(
                success=success,
                output_paths=output_paths,
                total_chapters=total_chapters,
                completed_chapters=completed_count,
                total_duration=total_duration
            )

        except Exception as e:
            return ConversionResult(
                success=False,
                output_paths=[],
                total_chapters=total_chapters,
                completed_chapters=0,
                error_message=str(e)
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
