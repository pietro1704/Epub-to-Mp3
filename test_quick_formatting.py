#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import sys
import asyncio
sys.path.insert(0, '/Users/pietropugliesi/Developer/testCOnvert/definitiv')

from src.tts.edge_engine import EdgeTTSEngine
from src.text_formatting import TextFormattingProcessor, FormattingSegment
from pathlib import Path

async def test_quick_formatting():
    print("🧪 Teste rápido da formatação com EdgeTTS\n")

    # Criar alguns segmentos de teste com formatação
    segments = [
        FormattingSegment("Este é um texto normal.", "normal"),
        FormattingSegment("texto em itálico", "italic"),
        FormattingSegment(" e este é ", "normal"),
        FormattingSegment("texto em negrito", "bold"),
        FormattingSegment(".", "normal"),
        FormattingSegment("Aqui temos código:", "normal"),
        FormattingSegment("print('hello')", "code"),
        FormattingSegment("e uma citação:", "normal"),
        FormattingSegment("Esta é uma citação importante.", "quote"),
    ]

    # Inicializar EdgeTTS
    print("📋 Segmentos de teste:")
    for i, seg in enumerate(segments):
        print(f"  {i+1}. [{seg.formatting}] {seg.text}")

    print(f"\n🎙️ Inicializando EdgeTTS...")
    engine = EdgeTTSEngine("pt-BR-ThalitaMultilingualNeural", verbose=True)

    # Juntar o texto simples
    simple_text = "".join([seg.text for seg in segments])
    print(f"\n📝 Texto completo: {simple_text}")

    # Testar com formatação
    output_path = Path("test_formatting_output.mp3")
    print(f"\n🔄 Testando síntese com formatação...")

    result = await engine.synthesize_async(
        simple_text,
        output_path,
        formatting_segments=segments
    )

    if result and output_path.exists():
        size = output_path.stat().st_size
        print(f"✅ Sucesso! Arquivo gerado: {output_path.name} ({size} bytes)")
        print(f"🎵 Para ouvir: open {output_path}")
    else:
        print(f"❌ Falha na síntese")

if __name__ == "__main__":
    asyncio.run(test_quick_formatting())