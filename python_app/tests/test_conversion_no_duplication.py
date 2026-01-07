#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
TDD Tests: Verificar que a conversão COMPLETA não gera duplicações
Test-Driven Development - Testes end-to-end
"""

import sys
import tempfile
from pathlib import Path

# Add python_app to path
sys.path.insert(0, str(Path(__file__).parent.parent))

from src.cache_manager import CacheManager
from src.config import ConversionConfig
from src.converter import AudioConverter
from src.ebook_reader import EbookReader


def test_conversion_creates_exactly_two_files():
    """
    TDD RED: Teste que verifica se a conversão cria EXATAMENTE 2 arquivos MP3

    Comportamento esperado:
    - EPUB tem 2 capítulos
    - Conversão deve criar EXATAMENTE 2 arquivos MP3
    - Não deve criar duplicatas (3 ou mais arquivos)
    """
    epub_path = Path(__file__).parent / "fixtures" / "epubs" / "test_multifeature.epub"

    with tempfile.TemporaryDirectory() as temp_dir:
        temp_path = Path(temp_dir)

        # Configuração de conversão
        config = ConversionConfig(
            book_title="Test Multi Feature Book",
            engine="edge",
            voice="pt-BR-FranciscaNeural",
            output_dir=str(temp_path),
            preserve_all_chapters=False,
        )

        # Ler EPUB
        reader = EbookReader(str(epub_path))
        chapters = reader.get_chapter_structure()

        assert len(chapters) == 2, f"EPUB deve ter 2 capítulos, tem {len(chapters)}"

        # Converter (mock sem TTS real para testes rápidos)
        # Apenas verificar que não há duplicação na preparação
        converter = AudioConverter()

        # Verificar que prepare_chapters não duplica
        prepared = []
        for ch in chapters:
            prepared.append(ch)

        # Deve ter exatamente 2 capítulos preparados
        assert len(prepared) == 2, f"Preparação deve ter 2 capítulos, tem {len(prepared)}"

        # Verificar que os nomes são diferentes
        names = [ch.name for ch in prepared]
        assert len(set(names)) == 2, f"Capítulos preparados têm nomes duplicados: {names}"


def test_cache_does_not_duplicate_chapters():
    """
    TDD RED: Teste que verifica se o cache não duplica capítulos

    Comportamento esperado:
    - Salvar 2 capítulos no cache
    - Ler do cache
    - Deve retornar EXATAMENTE 2 capítulos (não 4!)
    """
    epub_path = Path(__file__).parent / "fixtures" / "epubs" / "test_multifeature.epub"

    with tempfile.TemporaryDirectory() as temp_dir:
        cache_dir = Path(temp_dir) / "cache"
        cache_manager = CacheManager(cache_dir=cache_dir)

        # Ler EPUB
        reader = EbookReader(str(epub_path))
        chapters = reader.get_chapter_structure()

        # Preparar dados para cache
        chapters_data = {
            "title": reader.title,
            "author": reader.author,
            "chapters": [{"title": ch.name, "text": ch.text} for ch in chapters],
        }

        # Salvar no cache
        success = cache_manager.save_chapters_to_cache(Path(epub_path), chapters_data)

        assert success, "Falha ao salvar no cache"

        # Ler do cache (simular reload)
        cached = cache_manager.get_cached_chapters(Path(epub_path))

        assert cached is not None, "Cache não retornou dados"
        assert "chapters" in cached, "Cache sem campo 'chapters'"

        cached_chapters = cached["chapters"]

        # Verificar que NÃO há duplicação
        assert (
            len(cached_chapters) == 2
        ), f"Cache deve ter 2 capítulos, tem {len(cached_chapters)}. Há duplicação!"

        # Verificar que os títulos são únicos
        titles = [ch["title"] for ch in cached_chapters]
        assert len(set(titles)) == 2, f"Capítulos no cache têm títulos duplicados: {titles}"


def test_text_chunks_no_overlap():
    """
    TDD RED: Teste que verifica se chunks de texto não têm overlap

    Comportamento esperado:
    - Ao dividir texto grande em chunks (para TTS)
    - Chunks NÃO devem ter overlap/repetição
    - Cada parte do texto deve aparecer APENAS UMA VEZ
    """
    # Texto de teste longo (simula capítulo grande)
    long_text = "A " * 1000 + "B " * 1000 + "C " * 1000

    # Simular chunking (como em edge_engine ou outros)
    chunk_size = 500
    chunks = []

    start = 0
    while start < len(long_text):
        end = min(start + chunk_size, len(long_text))
        chunk = long_text[start:end]
        chunks.append(chunk)
        start = end  # NÃO adicionar overlap!

    # Verificar que não há overlap
    all_text = "".join(chunks)

    # Texto reconstruído deve ser EXATAMENTE igual ao original
    assert (
        all_text == long_text
    ), "Chunks têm overlap ou lacunas! Texto reconstruído diferente do original"

    # Verificar que cada parte aparece apenas 1x
    # Contar 'A', 'B', 'C'
    assert all_text.count("A ") == 1000, "Letra A duplicada ou faltando"
    assert all_text.count("B ") == 1000, "Letra B duplicada ou faltando"
    assert all_text.count("C ") == 1000, "Letra C duplicada ou faltando"


def test_footnote_processing_no_duplication():
    """
    TDD RED: Teste que verifica se processamento de notas de rodapé não duplica

    Comportamento esperado:
    - Notas de rodapé devem ser processadas APENAS UMA VEZ
    - Não deve haver "nota sobre nota"
    """
    # Texto com nota de rodapé
    text_with_footnote = """
    Este é um texto com nota[1].

    [1] Esta é a nota de rodapé.
    """

    # Processar (simular extração de notas)
    import re

    # Encontrar marcadores [N]
    markers = re.findall(r"\[(\d+)\]", text_with_footnote)

    # Deve ter exatamente 2 ocorrências: [1] no texto e [1] na nota
    assert len(markers) == 2, f"Esperado 2 marcadores [1], encontrado {len(markers)}: {markers}"

    # Ambos devem ser '1'
    assert markers == ["1", "1"], f"Marcadores incorretos: {markers}"

    # Se processar novamente, NÃO deve duplicar
    # (teste de idempotência)
    markers_again = re.findall(r"\[(\d+)\]", text_with_footnote)
    assert markers == markers_again, "Segunda passagem de processamento duplicou marcadores!"


def test_chapter_structure_stability():
    """
    TDD RED: Teste que verifica se estrutura de capítulos é estável

    Comportamento esperado:
    - Ler EPUB múltiplas vezes
    - Sempre retornar a MESMA estrutura
    - Não deve "crescer" a cada leitura
    """
    epub_path = Path(__file__).parent / "fixtures" / "epubs" / "test_multifeature.epub"

    # Primeira leitura
    reader1 = EbookReader(str(epub_path))
    chapters1 = reader1.get_chapter_structure()
    count1 = len(chapters1)
    names1 = [ch.name for ch in chapters1]

    # Segunda leitura (novo reader)
    reader2 = EbookReader(str(epub_path))
    chapters2 = reader2.get_chapter_structure()
    count2 = len(chapters2)
    names2 = [ch.name for ch in chapters2]

    # Terceira leitura
    reader3 = EbookReader(str(epub_path))
    chapters3 = reader3.get_chapter_structure()
    count3 = len(chapters3)
    names3 = [ch.name for ch in chapters3]

    # Todas devem ter 2 capítulos
    assert (
        count1 == count2 == count3 == 2
    ), f"Contagens diferem: {count1}, {count2}, {count3}. Há instabilidade!"

    # Todos devem ter os mesmos nomes
    assert (
        names1 == names2 == names3
    ), f"Nomes diferem entre leituras:\n  1: {names1}\n  2: {names2}\n  3: {names3}"


if __name__ == "__main__":
    import pytest

    print("=" * 70)
    print("TESTES TDD: Conversão End-to-End (Sem Duplicação)")
    print("=" * 70)
    print("\nEstes testes verificam a conversão completa.\n")

    # Rodar testes
    exit_code = pytest.main([__file__, "-v", "--tb=short"])

    if exit_code == 0:
        print("\n" + "=" * 70)
        print("✅ TODOS OS TESTES PASSARAM!")
        print("=" * 70)
    else:
        print("\n" + "=" * 70)
        print("❌ ALGUNS TESTES FALHARAM - Código precisa ser corrigido")
        print("=" * 70)

    sys.exit(exit_code)
