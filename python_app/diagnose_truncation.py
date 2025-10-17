#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
Script de diagnóstico para identificar onde o áudio está sendo cortado
"""

import asyncio
import sys
from pathlib import Path

# Add parent directory to path
sys.path.insert(0, str(Path(__file__).parent))

from src.ebook_reader import EbookReader
from src.config import ConversionConfig
from src.tts.edge_engine import EdgeTTSEngine


async def diagnose_chapter(epub_path: str, chapter_num: int = 1):
    """Diagnose a specific chapter to see where truncation occurs"""

    print(f"🔍 Diagnosticando: {epub_path}")
    print(f"📖 Capítulo: {chapter_num}")
    print("=" * 80)

    # Read EPUB
    reader = EbookReader(epub_path)
    chapters = list(reader.get_chapter_structure())

    if chapter_num > len(chapters):
        print(f"❌ Capítulo {chapter_num} não existe! Livro tem {len(chapters)} capítulos.")
        return

    chapter = chapters[chapter_num - 1]

    print(f"\n📚 Capítulo: {chapter.name}")
    print(f"📄 Texto original: {len(chapter.text or '')} caracteres")

    # Get speech_text (what converter uses)
    speech_text = getattr(chapter, 'speech_text', None) or chapter.text or ""
    print(f"🎤 Speech text: {len(speech_text)} caracteres")

    # Apply formatting (what TTS actually receives)
    try:
        from src.text_formatting import TextFormattingProcessor
        formatter = TextFormattingProcessor()
        formatting_segments = getattr(chapter, 'formatting_segments', None)
        actual_tts_text = formatter.to_audible_text(speech_text, formatting_segments)
        print(f"✨ Texto formatado (pós-processamento): {len(actual_tts_text)} caracteres")
    except ImportError:
        actual_tts_text = speech_text
        print(f"⚠️ TextFormattingProcessor não disponível")

    print(f"\n📊 RESUMO:")
    print(f"  • Original:  {len(chapter.text or '')} chars")
    print(f"  • Speech:    {len(speech_text)} chars")
    print(f"  • TTS Input: {len(actual_tts_text)} chars")

    # Show preview
    print(f"\n📝 PRÉVIA (primeiros 200 chars):")
    print(f"  {actual_tts_text[:200]}")

    print(f"\n📝 FINAL (últimos 200 chars):")
    print(f"  ...{actual_tts_text[-200:]}")

    # Check how Edge TTS will segment it
    print(f"\n🔪 SEGMENTAÇÃO DO EDGE TTS:")
    engine = EdgeTTSEngine("pt-BR-FranciscaNeural", verbose=False)
    segments = engine._prepare_segments(actual_tts_text)

    print(f"  • Total de segmentos: {len(segments)}")

    total_chars_in_segments = sum(len(seg_text) for _, seg_text in segments)
    print(f"  • Caracteres nos segmentos: {total_chars_in_segments}/{len(actual_tts_text)}")

    if total_chars_in_segments != len(actual_tts_text):
        lost = len(actual_tts_text) - total_chars_in_segments
        print(f"  ⚠️ PERDA DE CARACTERES: {lost} chars perdidos na segmentação!")
        print(f"  ⚠️ Isso significa que {lost} caracteres NÃO serão sintetizados!")
    else:
        print(f"  ✅ Nenhuma perda de caracteres na segmentação")

    # Show each segment
    print(f"\n📋 DETALHES DOS SEGMENTOS:")
    for idx, (voice, seg_text) in enumerate(segments[:5]):  # Show first 5
        estimated_duration = engine._estimate_duration(seg_text)
        print(f"  Segmento {idx+1}: {len(seg_text)} chars (~{estimated_duration:.1f}s)")
        print(f"    Início: {seg_text[:60]}...")
        print(f"    Fim:    ...{seg_text[-60:]}")

    if len(segments) > 5:
        print(f"  ... (+{len(segments) - 5} segmentos)")

    # Estimate total duration
    total_duration = sum(engine._estimate_duration(seg_text) for _, seg_text in segments)
    print(f"\n⏱️ DURAÇÃO ESTIMADA:")
    print(f"  • Duração total estimada: {total_duration:.1f} segundos ({total_duration/60:.1f} minutos)")
    print(f"  • Palavras: ~{len(actual_tts_text.split())} palavras")

    # Check for potential issues
    print(f"\n🔍 VERIFICAÇÕES:")

    if total_duration > 60:
        print(f"  ⚠️ Duração > 1 minuto ({total_duration/60:.1f} min)")
        print(f"     Se o áudio corta em ~1 minuto, o problema é no Microsoft Edge TTS")

    if len(segments) > 1:
        print(f"  ℹ️ Texto será dividido em {len(segments)} segmentos")
        print(f"     Cada segmento é processado sequencialmente")

    # Save to file for inspection
    output_file = Path(f"diagnostico_capitulo_{chapter_num}.txt")
    with output_file.open("w", encoding="utf-8") as f:
        f.write(f"DIAGNÓSTICO - Capítulo {chapter_num}\n")
        f.write("=" * 80 + "\n\n")
        f.write(f"Livro: {epub_path}\n")
        f.write(f"Capítulo: {chapter.name}\n")
        f.write(f"Caracteres: {len(actual_tts_text)}\n")
        f.write(f"Segmentos: {len(segments)}\n")
        f.write(f"Duração estimada: {total_duration:.1f}s\n\n")
        f.write("=" * 80 + "\n")
        f.write("TEXTO COMPLETO QUE SERÁ ENVIADO AO TTS:\n")
        f.write("=" * 80 + "\n\n")
        f.write(actual_tts_text)

    print(f"\n💾 Texto completo salvo em: {output_file}")
    print(f"   Use este arquivo para comparar com o áudio gerado")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Uso: python diagnose_truncation.py <arquivo.epub> [numero_capitulo]")
        print()
        print("Exemplo:")
        print("  python diagnose_truncation.py meu_livro.epub")
        print("  python diagnose_truncation.py meu_livro.epub 3")
        sys.exit(1)

    epub_path = sys.argv[1]
    chapter_num = int(sys.argv[2]) if len(sys.argv) > 2 else 1

    asyncio.run(diagnose_chapter(epub_path, chapter_num))
