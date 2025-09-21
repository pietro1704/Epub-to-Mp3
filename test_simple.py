#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Test script for simple converter with footnote and italic text analysis
"""

import asyncio
from pathlib import Path
from src.config import AppConfig, ConversionConfig
from src.ebook_reader import EbookReader
from src.converter_simple import SimpleAudioConverter


async def test_jardim_chapters():
    """Test first chapters of O Jardim das Aflições for footnotes and italic text"""

    book_path = Path("O Jardim das Aflições.epub")
    if not book_path.exists():
        print("❌ Arquivo não encontrado: O Jardim das Aflições.epub")
        return

    print("📖 Testando: O Jardim das Aflições")
    print("=" * 50)

    # Setup configuration
    app_config = AppConfig()
    config = app_config.create_conversion_config(
        engine='edge',
        input_file=book_path,
        voice='pt-BR-FranciscaNeural',
        verbose=True,
        output_dir='.cache'
    )

    # Read book
    reader = EbookReader(book_path)

    chapters = list(reader.get_chapter_structure() or [])
    print(f"📚 Total de capítulos: {len(chapters)}")

    # Analyze first 3 chapters for footnotes and formatting
    for idx, chapter in enumerate(chapters[:3]):
        chapter_num = idx + 1
        print(f"\n📄 CAPÍTULO {chapter_num}: {chapter.name}")
        print("-" * 40)

        text = chapter.text[:2000]  # First 2000 chars

        # Check for footnotes
        footnote_patterns = [
            "[", "]", "¹", "²", "³", "⁴", "⁵",
            "(nota:", "(ver:", "(cf.", "(v."
        ]

        footnotes_found = []
        for pattern in footnote_patterns:
            if pattern in text:
                footnotes_found.append(pattern)

        if footnotes_found:
            print(f"📝 Notas de rodapé encontradas: {footnotes_found}")
        else:
            print("📝 Sem notas de rodapé aparentes")

        # Check for italic/emphasis text
        italic_patterns = ["<em>", "</em>", "<i>", "</i>", "_", "*"]
        italics_found = []

        for pattern in italic_patterns:
            if pattern in text:
                italics_found.append(pattern)

        if italics_found:
            print(f"🔤 Formatação de ênfase encontrada: {italics_found}")
        else:
            print("🔤 Sem formatação de ênfase aparente")

        # Show text sample
        print(f"\n📄 Amostra do texto:")
        print(text[:500] + "..." if len(text) > 500 else text)

        # Test conversion of this chapter only
        print(f"\n🎵 Testando conversão do capítulo {chapter_num}...")

        converter = SimpleAudioConverter()

        # Create single chapter mock
        class MockReader:
            def __init__(self, chapters):
                self._chapters = chapters
                self.file_path = str(book_path)

            def get_chapter_structure(self):
                return self._chapters

        single_chapter_reader = MockReader([chapter])

        result = await converter.convert(config, single_chapter_reader)

        if result.success:
            print(f"✅ Capítulo {chapter_num} convertido com sucesso")
            if result.output_paths:
                output_path = result.output_paths[0]
                print(f"📁 Arquivo: {output_path}")
                if output_path.exists():
                    size_mb = output_path.stat().st_size / (1024 * 1024)
                    print(f"📊 Tamanho: {size_mb:.2f} MB")
        else:
            print(f"❌ Falha na conversão do capítulo {chapter_num}")
            if result.error_message:
                print(f"⚠️ Erro: {result.error_message}")

        print("\n" + "=" * 50)


if __name__ == "__main__":
    asyncio.run(test_jardim_chapters())