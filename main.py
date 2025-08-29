#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
main_simple.py - Versão simplificada do conversor EPUB para áudio

Funcionalidades:
- Leitura simples de EPUB com hierarquia correta (1, 1.1, 1.2, etc.)
- Conversão para áudio usando Edge-TTS (mais confiável)
- Progress tracking básico
- Cache simples
"""

import argparse
import asyncio
import os
import sys
from pathlib import Path
from datetime import datetime

# Add src to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'src'))

from simple_epub_reader import read_epub_simple, SimpleChapter
import edge_tts
import subprocess

class SimpleConverter:
    def __init__(self, voice="pt-BR-AntonioNeural"):
        self.voice = voice
        
    async def convert_chapter(self, chapter: SimpleChapter, output_dir: Path):
        """Convert single chapter to MP3"""
        if not chapter.text.strip():
            print(f"⚠️  Skipping empty chapter: {chapter.index} - {chapter.title}")
            return
        
        # Clean filename
        safe_title = self._sanitize_filename(chapter.title)
        filename = f"{chapter.index.zfill(3)} - {safe_title}.mp3"
        output_path = output_dir / filename
        
        print(f"🎵 Converting: {chapter.index} - {chapter.title} ({chapter.char_count} chars)")
        
        try:
            # Generate speech with Edge-TTS
            communicate = edge_tts.Communicate(chapter.text, self.voice)
            await communicate.save(str(output_path))
            print(f"✅ Saved: {filename}")
            
        except Exception as e:
            print(f"❌ Error converting {chapter.index}: {e}")
    
    def _sanitize_filename(self, filename: str) -> str:
        """Clean filename for filesystem"""
        # Remove invalid characters
        safe = re.sub(r'[<>:"/\\|?*]', '', filename)
        # Replace multiple spaces with single space
        safe = re.sub(r'\s+', ' ', safe)
        # Trim and limit length
        safe = safe.strip()[:100]
        return safe

async def main():
    parser = argparse.ArgumentParser(description="Simple EPUB to Audio Converter")
    parser.add_argument("epub_file", help="Path to EPUB file")
    parser.add_argument("--voice", default="pt-BR-AntonioNeural", help="Edge-TTS voice")
    parser.add_argument("--output", "-o", help="Output directory (default: book title)")
    parser.add_argument("--show-structure", action="store_true", help="Only show chapter structure")
    parser.add_argument("--no-cache", action="store_true", help="Don't use cache, reprocess EPUB")
    
    args = parser.parse_args()
    
    # Check if EPUB file exists
    epub_path = Path(args.epub_file)
    if not epub_path.exists():
        print(f"❌ File not found: {epub_path}")
        return 1
    
    print(f"📖 Reading EPUB: {epub_path.name}")
    
    try:
        # Setup cache directory
        cache_dir = Path(f".cache/{epub_path.stem}")
        
        # Read chapters from EPUB (with HTML parsing for subchapters)
        print("📖 Parsing EPUB with HTML analysis...")
        chapters = read_epub_simple(str(epub_path), parse_html_subchapters=True)
        
        if not chapters:
            print("❌ No chapters found in EPUB")
            return 1
        
        # Always save TXT files (individual files) directly in cache dir
        cache_dir.mkdir(parents=True, exist_ok=True)
        
        for ch in chapters:
            if ch.text and ch.text.strip():
                safe_title = re.sub(r'[<>:"/\\|?*]', '', ch.title)[:80]  # Limit filename length
                txt_file = cache_dir / f"{ch.index.zfill(3)} - {safe_title}.txt"
                with open(txt_file, 'w', encoding='utf-8') as f:
                    f.write(f"# {ch.title}\n\n{ch.text}")
        
        print(f"📝 TXT files saved: {cache_dir}")
        
        # Show structure
        print(f"\n📚 BOOK STRUCTURE ({len(chapters)} chapters)")
        print("=" * 60)
        
        total_chars = 0
        for ch in chapters:
            indent = "  " * (ch.level - 1)
            print(f"{indent}{ch.index}. 📖 {ch.title}")
            print(f"{indent}     📊 {ch.char_count:,} chars | ~{ch.char_count/1000*0.6:.1f}min")
            total_chars += ch.char_count
        
        print("=" * 60)
        print(f"📊 TOTAL: {len(chapters)} chapters | {total_chars:,} chars | ~{total_chars/1000*0.6/60:.1f}h")
        print("=" * 60)
        
        if args.show_structure:
            return 0
        
        # Setup output directory
        if args.output:
            output_dir = Path(args.output)
        else:
            # Use book title from first chapter's source or file name
            book_name = epub_path.stem
            output_dir = Path(book_name)
        
        output_dir.mkdir(exist_ok=True)
        print(f"📁 Output directory: {output_dir}")
        
        # Convert chapters
        converter = SimpleConverter(args.voice)
        
        print(f"\n🎵 Starting conversion with voice: {args.voice}")
        start_time = datetime.now()
        
        for i, chapter in enumerate(chapters, 1):
            print(f"\n[{i}/{len(chapters)}] ", end="")
            await converter.convert_chapter(chapter, output_dir)
        
        duration = datetime.now() - start_time
        print(f"\n✅ Conversion completed in {duration}")
        print(f"📁 Files saved to: {output_dir.absolute()}")
        
        return 0
        
    except Exception as e:
        print(f"❌ Error: {e}")
        import traceback
        traceback.print_exc()
        return 1

if __name__ == "__main__":
    import re
    exit_code = asyncio.run(main())
    sys.exit(exit_code)