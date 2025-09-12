# -*- coding: utf-8 -*-
"""
Simplified Audio Converter - SOLID principles applied
Reduced from 527 to ~150 lines by applying SRP and removing complexity
"""

import asyncio
import os
import sys
from pathlib import Path
from typing import List, Optional
from dataclasses import dataclass

from .ebook_reader import EbookReader, Chapter
from .config import ConversionConfig
from .tts.factory import TTSFactory
from .utils import AudioProcessor, FileManager
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
    """Main audio converter class following SRP"""
    
    def __init__(self):
        self.tts_factory = TTSFactory()
        self.audio_processor = AudioProcessor()
        self.file_manager = FileManager()
    
    async def convert(self, reader: EbookReader, config: ConversionConfig) -> int:
        """Convert ebook to audio"""
        try:
            # Setup
            output_dir = self._setup_output_directory(config)
            tts_engine = self.tts_factory.create_engine(config)
            chapters = reader.get_chapter_structure(preserve_all=config.preserve_all_chapters)
            
            # Convert chapters
            result = await self._convert_chapters(chapters, tts_engine, output_dir, config)
            
            # Report results
            self._report_results(result)
            return 0 if result.success else 1
            
        except Exception as e:
            print(f"❌ Conversion failed: {e}")
            return 1
    
    def _setup_output_directory(self, config: ConversionConfig) -> Path:
        """Setup output directory"""
        output_dir = Path(config.output_dir)
        if config.book_title:
            output_dir = output_dir / self.file_manager.sanitize_filename(config.book_title)
        
        output_dir.mkdir(parents=True, exist_ok=True)
        return output_dir
    
    async def _convert_chapters(self, chapters: List[Chapter], tts_engine, 
                              output_dir: Path, config: ConversionConfig) -> ConversionResult:
        """Convert chapters to audio with parallel processing"""
        progress = ProgressTracker(len(chapters))
        
        semaphore = asyncio.Semaphore(config.max_parallel)
        tasks = [
            self._convert_single_chapter(semaphore, chapter, tts_engine, output_dir, i, progress)
            for i, chapter in enumerate(chapters, 1)
        ]
        
        results = await asyncio.gather(*tasks, return_exceptions=True)
        
        # Process results
        output_files = []
        errors = []
        converted = 0
        
        for result in results:
            if isinstance(result, Exception):
                errors.append(str(result))
            elif result:
                output_files.append(result)
                converted += 1
        
        return ConversionResult(
            success=len(errors) == 0,
            total_chapters=len(chapters),
            converted_chapters=converted,
            output_files=output_files,
            errors=errors
        )
    
    async def _convert_single_chapter(self, semaphore: asyncio.Semaphore, 
                                    chapter: Chapter, tts_engine, 
                                    output_dir: Path, index: int, progress: ProgressTracker) -> Optional[Path]:
        """Convert single chapter to audio"""
        async with semaphore:
            try:
                # Generate output filename
                safe_title = self.file_manager.sanitize_filename(chapter.name)
                output_file = output_dir / f"{index:03d}_{safe_title}.mp3"
                
                # Skip if exists and not forcing reprocess
                if output_file.exists():
                    progress.start_chapter(f"Skipping {chapter.name} (exists)")
                    return output_file
                
                # Convert to audio
                progress.start_chapter(chapter.name)
                
                temp_file = await tts_engine.synthesize_async(chapter.text, output_file.with_suffix('.wav'))
                if temp_file and temp_file.exists():
                    # Convert to MP3
                    final_file = await self.audio_processor.convert_to_mp3(temp_file, output_file)
                    temp_file.unlink()  # Clean up temp file
                    return final_file
                
                return None
                
            except Exception as e:
                print(f"❌ Error in {chapter.name}: {e}")
                raise
            finally:
                progress.complete_chapter()
    
    def _report_results(self, result: ConversionResult):
        """Report conversion results"""
        print(f"\n📊 Conversion Results:")
        print(f"  ✅ Converted: {result.converted_chapters}/{result.total_chapters}")
        print(f"  📁 Files: {len(result.output_files)}")
        
        if result.errors:
            print(f"  ❌ Errors: {len(result.errors)}")
            for error in result.errors[:3]:  # Show first 3 errors
                print(f"    • {error}")


class ChapterProcessor:
    """Handles chapter-specific processing following SRP"""
    
    @staticmethod
    def chunk_text(text: str, max_size: int = 5000) -> List[str]:
        """Split text into chunks for TTS processing"""
        if len(text) <= max_size:
            return [text]
        
        # Split by sentences to avoid cutting words
        sentences = text.replace('.', '.\n').replace('!', '!\n').replace('?', '?\n').split('\n')
        
        chunks = []
        current_chunk = ""
        
        for sentence in sentences:
            if len(current_chunk) + len(sentence) <= max_size:
                current_chunk += sentence
            else:
                if current_chunk:
                    chunks.append(current_chunk.strip())
                current_chunk = sentence
        
        if current_chunk:
            chunks.append(current_chunk.strip())
        
        return chunks