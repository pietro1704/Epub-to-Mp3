#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Test specific chapter (37) with footnotes and pronunciation enhancements
"""

import asyncio
import re
from pathlib import Path
from src.config import AppConfig, ConversionConfig
from src.ebook_reader import EbookReader
from src.converter_simple import SimpleAudioConverter


class PronunciationEnhancer:
    """Enhance text pronunciation for different formatting"""

    @staticmethod
    def enhance_text(text: str) -> str:
        """Add pronunciation cues for formatting"""
        enhanced = text

        # Add pause before and after parenthetical notes
        enhanced = re.sub(r'\(([^)]+)\)', r' <break time="200ms"/> \1 <break time="200ms"/> ', enhanced)

        # Add emphasis for italic-like formatting (common patterns)
        italic_patterns = [
            (r'_([^_]+)_', r'<emphasis level="moderate">\1</emphasis>'),
            (r'\*([^*]+)\*', r'<emphasis level="moderate">\1</emphasis>'),
            (r'<em>([^<]+)</em>', r'<emphasis level="moderate">\1</emphasis>'),
            (r'<i>([^<]+)</i>', r'<emphasis level="moderate">\1</emphasis>'),
        ]

        for pattern, replacement in italic_patterns:
            enhanced = re.sub(pattern, replacement, enhanced)

        # Improve pronunciation of citations and references
        enhanced = re.sub(r'cf\.', 'confira', enhanced)
        enhanced = re.sub(r'ver\s+', 'veja ', enhanced)
        enhanced = re.sub(r'op\.\s*cit\.', 'obra citada', enhanced)
        enhanced = re.sub(r'et\s+al\.', 'e outros', enhanced)

        # Add pauses around numbered references
        enhanced = re.sub(r'(\d+)', r'<break time="100ms"/>\1<break time="100ms"/>', enhanced)

        return enhanced


async def test_chapter_with_formatting():
    """Test chapter 37 with pronunciation enhancements"""

    book_path = Path("O Jardim das Aflições.epub")
    if not book_path.exists():
        print("❌ Arquivo não encontrado: O Jardim das Aflições.epub")
        return

    print("📖 Testando: Capítulo 37 com melhorias de pronúncia")
    print("=" * 60)

    # Setup configuration with multilingual voice
    app_config = AppConfig()
    config = app_config.create_conversion_config(
        engine='edge',
        input_file=book_path,
        verbose=True,
        output_dir='.cache'
    )

    # Read book
    reader = EbookReader(book_path)
    chapters = list(reader.get_chapter_structure() or [])

    # Get chapter 37 (index 36)
    target_chapter = chapters[36]  # Chapter 37
    print(f"🎯 Capítulo selecionado: {target_chapter.name}")

    # Analyze original text
    original_text = target_chapter.text
    print(f"📊 Texto original: {len(original_text)} chars")

    # Show sample of original text
    sample = original_text[:1000]
    print(f"\n📄 Amostra original:")
    print(sample)

    # Enhanced text with pronunciation cues
    enhancer = PronunciationEnhancer()
    enhanced_text = enhancer.enhance_text(original_text)

    print(f"\n📊 Texto melhorado: {len(enhanced_text)} chars")

    # Show sample of enhanced text
    enhanced_sample = enhanced_text[:1000]
    print(f"\n📄 Amostra melhorada:")
    print(enhanced_sample)

    # Show differences
    print(f"\n🔍 Diferenças encontradas:")
    if '<emphasis' in enhanced_text:
        print("✅ Ênfase adicionada para texto em itálico")
    if '<break' in enhanced_text:
        print("✅ Pausas adicionadas para notas de rodapé")
    if 'confira' in enhanced_text.lower():
        print("✅ Abreviações expandidas (cf. → confira)")

    # Create test versions
    test_configs = [
        {"name": "Original", "text": original_text, "suffix": "_original"},
        {"name": "Melhorado", "text": enhanced_text, "suffix": "_enhanced"}
    ]

    converter = SimpleAudioConverter()

    for test_config in test_configs:
        print(f"\n🎵 Testando versão: {test_config['name']}")
        print("-" * 40)

        # Create modified chapter
        modified_chapter = type('Chapter', (), {
            'name': f"{target_chapter.name}{test_config['suffix']}",
            'text': test_config['text'][:2000]  # First 2000 chars for testing
        })()

        # Mock reader
        class MockReader:
            def __init__(self, chapters):
                self._chapters = chapters
                self.file_path = str(book_path)

            def get_chapter_structure(self):
                return self._chapters

        mock_reader = MockReader([modified_chapter])

        try:
            result = await converter.convert(config, mock_reader)

            if result.success and result.output_paths:
                output_path = result.output_paths[0]
                print(f"✅ Convertido: {output_path}")
                if output_path.exists():
                    size_mb = output_path.stat().st_size / (1024 * 1024)
                    print(f"📊 Tamanho: {size_mb:.2f} MB")
            else:
                print(f"❌ Falha na conversão")
                if result.error_message:
                    print(f"⚠️ Erro: {result.error_message}")

        except Exception as e:
            print(f"❌ Erro: {e}")

    print(f"\n📁 Arquivos gerados em: .cache/")
    print("🎧 Compare os arquivos *_original.mp3 e *_enhanced.mp3 para ouvir as diferenças")


if __name__ == "__main__":
    asyncio.run(test_chapter_with_formatting())