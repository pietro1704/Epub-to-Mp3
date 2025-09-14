#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Simplified EBook to Audiobook Converter - SOLID principles applied
Reduced from 564 to ~100 lines while maintaining all functionality
"""

import argparse
import asyncio
import sys
from pathlib import Path
from typing import Optional

# Local imports  
from src.ebook_reader import EbookReader
from src.converter import AudioConverter
from src.ui.menu import MenuInterface
from src.config import AppConfig


class ConverterApplication:
    """Main application class following SRP"""
    
    def __init__(self):
        self.config = AppConfig()
        self.menu = MenuInterface()
        self.converter = AudioConverter()
    
    def run(self, args: argparse.Namespace) -> int:
        """Main application entry point"""
        try:
            # Validate input
            if not Path(args.input_file).exists():
                print(f"❌ File not found: {args.input_file}")
                return 1
            
            # Load ebook
            reader = EbookReader(args.input_file)
            
            # Show structure only
            if args.show_structure:
                self._show_structure(reader)
                return 0
            
            # Configure conversion
            config = self._get_conversion_config(args, reader)
            if not config:
                return 1
                
            # Convert
            return asyncio.run(self.converter.convert(reader, config))
            
        except Exception as e:
            print(f"❌ Error: {e}")
            return 1
    
    def _show_structure(self, reader: EbookReader):
        """Display book structure"""
        print(f"📚 {reader.title}")
        print(f"👤 {reader.author}")
        print(f"📄 {len(reader.get_chapters())} chapters")
        
        for chapter in reader.get_chapters():
            print(f"  {chapter.index:>4}. {chapter.name} ({len(chapter.text)} chars)")
    
    def _get_conversion_config(self, args: argparse.Namespace, reader: EbookReader):
        """Get conversion configuration"""
        if args.engine:
            # Command line configuration
            return self._create_config_from_args(args, reader)
        else:
            # Interactive menu
            return self.menu.get_conversion_config(reader)
    
    def _create_config_from_args(self, args: argparse.Namespace, reader: EbookReader):
        """Create config from command line arguments"""
        return self.config.create_conversion_config(
            engine=args.engine,
            voice=args.voice,
            model=args.model,
            output_dir=args.output_dir or "output",
            book_title=reader.title,
            max_parallel=args.max_parallel
        )


def create_argument_parser() -> argparse.ArgumentParser:
    """Create command line argument parser"""
    parser = argparse.ArgumentParser(description="EBook to Audiobook Converter")
    
    parser.add_argument("input_file", help="Input EPUB or PDF file")
    parser.add_argument("--engine", choices=["edge", "coqui", "piper"], 
                       help="TTS engine to use")
    parser.add_argument("--voice", help="Voice to use (engine-specific)")
    parser.add_argument("--model", help="Model path (for Piper/Coqui)")
    parser.add_argument("--output-dir", help="Output directory")
    parser.add_argument("--show-structure", action="store_true",
                       help="Show book structure and exit")
    parser.add_argument("--max-parallel", type=int, default=3,
                       help="Maximum parallel conversions (default: 3)")
    
    return parser


def main() -> int:
    """Application entry point"""
    parser = create_argument_parser()
    args = parser.parse_args()
    
    app = ConverterApplication()
    return app.run(args)


if __name__ == "__main__":
    sys.exit(main())