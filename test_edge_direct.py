#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Teste direto do Edge TTS para identificar problema
"""

import asyncio
import time
from pathlib import Path
from src.tts.edge_engine import EdgeTTSEngine

async def test_edge_direct():
    print("🧪 Teste direto do Edge TTS")

    # Texto de teste (primeiro parágrafo do capítulo 3)
    text = """Apenas os jovens têm desses momentos. Não me refiro aos muito jovens. Não. Os muito jovens, a bem dizer, não têm momento algum. Só a tenra juventude desfruta o privilégio da experiência ainda não consumada. Eu tinha vinte e poucos anos quando aconteceu aquilo, e esse período de sua vida é exatamente quando você pode ter esses momentos. Essa primeira visão das coisas, quando todas as cores são vivas e as formas definidas, o sol brilha magnificamente e os ventos sopram com força — quando a vida e o mundo ainda afloram com a esperança de mistério e aventura."""

    # Configurar engine
    engine = EdgeTTSEngine(
        voice="pt-BR-FranciscaNeural",
        verbose=True
    )

    print(f"📝 Texto: {len(text)} caracteres")
    print(f"🎙️ Voz: pt-BR-FranciscaNeural")

    # Arquivo de saída
    output_path = Path("test_edge_output.mp3")
    if output_path.exists():
        output_path.unlink()

    # Teste com timeout manual
    print("⏱️ Iniciando síntese com timeout de 2 minutos...")
    start_time = time.time()

    try:
        result = await asyncio.wait_for(
            engine.synthesize_async(text, output_path),
            timeout=120.0  # 2 minutos
        )

        end_time = time.time()
        duration = end_time - start_time

        if result and output_path.exists():
            file_size = output_path.stat().st_size
            print(f"✅ Sucesso em {duration:.1f}s - Arquivo: {file_size} bytes")
            return True
        else:
            print(f"❌ Falha em {duration:.1f}s - Sem arquivo de saída")
            if engine.last_error:
                print(f"   Erro: {engine.last_error}")
            return False

    except asyncio.TimeoutError:
        end_time = time.time()
        duration = end_time - start_time
        print(f"⏰ Timeout após {duration:.1f}s")
        if engine.last_error:
            print(f"   Último erro: {engine.last_error}")
        return False
    except Exception as e:
        end_time = time.time()
        duration = end_time - start_time
        print(f"💥 Exceção após {duration:.1f}s: {e}")
        return False

async def main():
    print("🚀 Teste de diagnóstico do Edge TTS")

    # Teste múltiplas vezes para ver se é consistente
    for i in range(3):
        print(f"\n--- Teste {i+1}/3 ---")
        success = await test_edge_direct()
        if success:
            print("✅ Teste passou - Edge TTS funcionando")
            break
        else:
            print("❌ Teste falhou")
            if i < 2:
                print("🔄 Tentando novamente em 2s...")
                await asyncio.sleep(2)
    else:
        print("\n❌ Todos os testes falharam - problema no Edge TTS")

if __name__ == "__main__":
    asyncio.run(main())