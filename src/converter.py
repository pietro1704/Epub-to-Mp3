# -*- coding: utf-8 -*-
"""Audio conversion pipeline wired to the TTS engines."""

from __future__ import annotations

import asyncio
import contextlib
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, List, Optional

from .ebook_reader import EbookReader, Chapter
from .config import ConversionConfig
from .tts.factory import TTSFactory
from .utils import AudioProcessor, FileManager, TextValidator
from .progress import ProgressTracker


@dataclass
class ConversionResult:
    """Result of audio conversion"""
    success: bool
    total_chapters: int
    converted_chapters: int
    output_files: List[Path]
    errors: List[str]


class AudioConverter:
    """Coordinate ebook parsing, TTS synthesis and post-processing."""

    def __init__(self) -> None:
        self.tts_factory = TTSFactory()
        self.audio_processor = AudioProcessor()
        self.file_manager = FileManager()
        self.progress = ProgressTracker()

    async def convert(self, reader: EbookReader, config: ConversionConfig) -> ConversionResult:
        """Convert all chapters in ``reader`` according to ``config``."""

        output_dir = self._setup_output_directory(config)
        chapters = list(reader.get_chapter_structure() or [])
        total_chapters = len(chapters)

        print(
            f"\n🚀 Iniciando conversão: {reader.title} "
            f"({total_chapters} capítulo{'s' if total_chapters != 1 else ''})"
        )
        print(f"💾 Saída: {output_dir}")

        self.progress.start(total_chapters, description="Convertendo capítulos")

        if total_chapters == 0:
            self.progress.finish()
            empty_result = ConversionResult(True, 0, 0, [], [])
            self._report_results(empty_result)
            return empty_result

        tts_engine = self.tts_factory.create_engine(config)
        voice_label = getattr(tts_engine, "voice", None) or config.voice or "(padrão)"
        print(f"🎙️ Engine: {config.engine} | Voz: {voice_label}")

        result = await self._convert_chapters(chapters, tts_engine, output_dir, config)
        self.progress.finish()
        self._report_results(result)
        return result

    def _setup_output_directory(self, config: ConversionConfig) -> Path:
        base_dir = Path(config.output_dir)
        if config.book_title:
            base_dir = base_dir / self.file_manager.sanitize_filename(config.book_title)
        return self.file_manager.ensure_directory(base_dir)

    async def _convert_chapters(
        self,
        chapters: Iterable[Chapter],
        tts_engine,
        output_dir: Path,
        config: ConversionConfig,
    ) -> ConversionResult:
        chapters_list = list(chapters)
        if not chapters_list:
            return ConversionResult(True, 0, 0, [], [])

        semaphore = asyncio.Semaphore(max(1, config.parallel or 1))
        tasks = [
            self._convert_single_chapter(
                semaphore,
                chapter,
                tts_engine,
                output_dir,
                index,
                config,
                self.progress,
            )
            for index, chapter in enumerate(chapters_list, start=1)
        ]

        results = await asyncio.gather(*tasks, return_exceptions=True)

        converted_files: List[Path] = []
        errors: List[str] = []
        for chapter, outcome in zip(chapters_list, results):
            if isinstance(outcome, Exception):
                errors.append(f"{chapter.name}: {outcome}")
            elif outcome is None:
                errors.append(f"{chapter.name}: conversion failed")
            else:
                converted_files.append(Path(outcome))

        success = not errors
        return ConversionResult(
            success=success,
            total_chapters=len(chapters_list),
            converted_chapters=len(converted_files),
            output_files=converted_files,
            errors=errors,
        )

    async def _convert_single_chapter(
        self,
        semaphore: asyncio.Semaphore,
        chapter: Chapter,
        tts_engine,
        output_dir: Path,
        index: int,
        config: ConversionConfig,
        progress: ProgressTracker,
    ) -> Optional[Path]:
        output_path = self.file_manager.get_output_path(chapter.name or f"Chapter {index}", output_dir, index)

        if output_path.exists() and not config.force_reprocess:
            progress.start_chapter(chapter.name or f"Chapter {index}", index)
            status = "✅ já existia"
            if getattr(config, "listen", False):
                progress.tick("🔊 reproduzindo")
                played = await self.audio_processor.play_audio(output_path)
                status = "✅ concluído" if played else "⚠️ reprodução indisponível"
            progress.complete_chapter(status)
            return output_path

        progress.start_chapter(chapter.name or f"Chapter {index}", index)
        status_holder = {"text": "⏳ preparando capítulo"}
        heartbeat_stop = asyncio.Event()

        async def heartbeat():
            try:
                while not heartbeat_stop.is_set():
                    progress.tick(status_holder["text"])
                    await asyncio.sleep(1)
            except asyncio.CancelledError:
                pass

        heartbeat_task = asyncio.create_task(heartbeat())

        try:
            async with semaphore:
                if not TextValidator.is_valid_text(chapter.text or " "):
                    status_holder["text"] = "⚠️ texto insuficiente"
                    return None

                chunks = ChapterProcessor.chunk_text(chapter.text or "")
                status_holder["text"] = "⏳ sintetizando"
                temp_wav = await tts_engine.synthesize_async(
                    "\n".join(chunks), output_path.with_suffix(".wav")
                )

                if not temp_wav:
                    status_holder["text"] = "⚠️ síntese falhou"
                    return None

                status_holder["text"] = "⏳ convertendo para MP3"
                converted = await self.audio_processor.convert_to_mp3(
                    temp_wav, output_path, bitrate=config.bitrate
                )
                if converted is None:
                    status_holder["text"] = "⚠️ MP3 falhou"
                    return None

                try:
                    if temp_wav.exists():
                        temp_wav.unlink()
                except OSError:
                    pass

                status_holder["text"] = "✅ concluído"
                if getattr(config, "listen", False):
                    status_holder["text"] = "🔊 reproduzindo"
                    played = await self.audio_processor.play_audio(converted)
                    status_holder["text"] = "✅ concluído" if played else "⚠️ reprodução indisponível"
                return converted
        except Exception as exc:
            if not status_holder["text"].startswith("❌"):
                status_holder["text"] = "❌ erro interno"
            raise RuntimeError("chapter conversion failed") from exc
        finally:
            heartbeat_stop.set()
            heartbeat_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await heartbeat_task
            progress.complete_chapter(status_holder["text"])

    def _report_results(self, result: ConversionResult) -> None:
        print("\n📊 Conversion Results:")
        print(f"  ✅ Converted: {result.converted_chapters}/{result.total_chapters}")
        print(f"  📁 Files: {len(result.output_files)}")
        if result.errors:
            print(f"  ❌ Errors: {len(result.errors)}")
            for error in result.errors[:3]:
                print(f"    • {error}")


class ChapterProcessor:
    """Handles chapter-specific processing following SRP"""
    
    @staticmethod
    def chunk_text(text: str, max_size: int = 5000) -> List[str]:
        """Split text into manageable chunks for TTS engines."""
        if text is None:
            return [""]
        if len(text) <= max_size:
            return [text]

        import re

        sentence_splitter = re.compile(r"(?<=[.!?])\s+")
        sentences = sentence_splitter.split(text)
        chunks: List[str] = []
        current: List[str] = []
        current_len = 0

        for sentence in sentences:
            cleaned = sentence.strip()
            if not cleaned:
                continue
            if current_len + len(cleaned) + 1 > max_size and current:
                chunks.append(" ".join(current).strip())
                current = [cleaned]
                current_len = len(cleaned)
            else:
                current.append(cleaned)
                current_len += len(cleaned) + 1

        if current:
            chunks.append(" ".join(current).strip())

        return chunks or [text[:max_size]]
