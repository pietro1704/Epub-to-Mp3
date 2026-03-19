#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
TDD Tests: Verificar que não há duplicação de conteúdo na conversão
Test-Driven Development - Estes testes definem o comportamento esperado
"""

import sys
from pathlib import Path
from typing import List, Set

# Add python_app to path
sys.path.insert(0, str(Path(__file__).parent.parent))

from src.ebook_reader import EbookReader


def test_no_duplicate_chapters_in_structure():
    """
    TDD RED: Teste que verifica se não há capítulos duplicados na estrutura

    Comportamento esperado:
    - Cada capítulo deve aparecer APENAS UMA VEZ
    - Nenhum texto deve estar duplicado entre capítulos
    """
    epub_path = Path(__file__).parent / "fixtures" / "epubs" / "test_multifeature.epub"
    assert epub_path.exists(), f"EPUB de teste não encontrado: {epub_path}"

    reader = EbookReader(str(epub_path))
    chapters = reader.get_chapter_structure()

    # Verificar que temos exatamente 2 capítulos
    assert len(chapters) == 2, f"Esperado 2 capítulos, obtido {len(chapters)}"

    # Verificar que os nomes são únicos
    chapter_names = [ch.name for ch in chapters]
    assert len(chapter_names) == len(
        set(chapter_names)
    ), f"Nomes de capítulos duplicados: {chapter_names}"

    # Verificar que os textos NÃO são idênticos
    chapter_texts = [ch.text for ch in chapters]
    for i, text1 in enumerate(chapter_texts):
        for j, text2 in enumerate(chapter_texts):
            if i != j:
                assert text1 != text2, f"Capítulos {i} e {j} têm texto idêntico (duplicação!)"


def test_no_duplicate_content_within_chapter():
    """
    TDD RED: Teste que verifica se não há frases repetidas dentro do mesmo capítulo

    Comportamento esperado:
    - Nenhuma frase com >20 caracteres deve aparecer 2x no mesmo capítulo
    - Exceção: notas de rodapé podem ter pequenas repetições de contexto
    """
    epub_path = Path(__file__).parent / "fixtures" / "epubs" / "test_multifeature.epub"
    reader = EbookReader(str(epub_path))
    chapters = reader.get_chapter_structure()

    for idx, chapter in enumerate(chapters):
        text = chapter.text

        # Dividir em sentenças (aproximação simples)
        sentences = [s.strip() for s in text.split(".") if len(s.strip()) > 20]

        # Verificar duplicatas
        seen: Set[str] = set()
        duplicates: List[str] = []

        for sentence in sentences:
            # Normalizar (remover espaços extras, lowcase)
            normalized = " ".join(sentence.lower().split())

            if normalized in seen:
                duplicates.append(sentence[:80])
            seen.add(normalized)

        # Permitir NO MÁXIMO 1 duplicata (contexto de nota de rodapé)
        assert len(duplicates) <= 1, (
            f"Capítulo {idx} ({chapter.name}) tem {len(duplicates)} sentenças duplicadas:\n"
            + "\n".join(f"  - {d}" for d in duplicates[:3])
        )


def test_chapter_text_length_reasonable():
    """
    TDD RED: Teste que verifica se os capítulos têm tamanho razoável

    Comportamento esperado:
    - Capítulo 1: ~600-700 caracteres (original tem 618)
    - Capítulo 2: ~400-500 caracteres (original tem 419)
    - Se tiver o DOBRO do tamanho, pode ser duplicação!
    """
    epub_path = Path(__file__).parent / "fixtures" / "epubs" / "test_multifeature.epub"
    reader = EbookReader(str(epub_path))
    chapters = reader.get_chapter_structure()

    # Limites esperados (com margem de 50%)
    expected_lengths = [
        (600, 900, "Capítulo 1"),  # min, max, nome
        (400, 600, "Capítulo 2"),
    ]

    for idx, (min_len, max_len, expected_name) in enumerate(expected_lengths):
        if idx >= len(chapters):
            break

        chapter = chapters[idx]
        actual_len = len(chapter.text)

        assert min_len <= actual_len <= max_len, (
            f"Capítulo {idx} ({chapter.name}) tem {actual_len} chars, "
            + f"esperado entre {min_len}-{max_len}. "
            + "Pode haver duplicação se muito maior, ou conteúdo faltando se muito menor!"
        )


def test_footnote_markers_not_duplicated():
    """
    TDD RED: Teste que verifica se marcadores de nota de rodapé não estão duplicados

    Comportamento esperado:
    - Marcadores como [1], [2], etc devem aparecer APENAS UMA VEZ
    - Cada nota deve ser processada apenas uma vez
    """
    epub_path = Path(__file__).parent / "fixtures" / "epubs" / "test_multifeature.epub"
    reader = EbookReader(str(epub_path))
    chapters = reader.get_chapter_structure()

    import re

    for idx, chapter in enumerate(chapters):
        text = chapter.text

        # Encontrar todos os marcadores de nota [N]
        markers = re.findall(r"\[(\d+)\]", text)

        if not markers:
            continue  # Capítulo sem notas

        # Verificar se há duplicatas
        marker_counts = {}
        for marker in markers:
            marker_counts[marker] = marker_counts.get(marker, 0) + 1

        duplicates = {m: count for m, count in marker_counts.items() if count > 1}

        assert not duplicates, (
            f"Capítulo {idx} ({chapter.name}) tem marcadores de nota duplicados: {duplicates}\n"
            + "Isso indica que as notas podem estar sendo processadas múltiplas vezes!"
        )


def test_no_double_chapter_titles():
    """
    TDD RED: Teste que verifica se títulos de capítulos não aparecem 2x no texto

    Comportamento esperado:
    - O título do capítulo deve aparecer APENAS UMA VEZ no início
    - Não deve ser repetido no meio ou fim do texto
    """
    epub_path = Path(__file__).parent / "fixtures" / "epubs" / "test_multifeature.epub"
    reader = EbookReader(str(epub_path))
    chapters = reader.get_chapter_structure()

    for idx, chapter in enumerate(chapters):
        title = chapter.name
        text = chapter.text

        # Contar quantas vezes o título aparece no texto
        title_count = text.count(title)

        # Título deve aparecer NO MÁXIMO 1 vez (no início)
        # Se aparecer 2x ou mais, há duplicação!
        assert title_count <= 1, (
            f"Capítulo {idx}: título '{title}' aparece {title_count} vezes no texto!\n"
            + "Isso indica duplicação de conteúdo.\n"
            + f"Texto: {text[:200]}..."
        )


if __name__ == "__main__":
    import pytest

    print("=" * 70)
    print("TESTES TDD: Verificação de Duplicação de Conteúdo")
    print("=" * 70)
    print("\nEstes testes definem o comportamento esperado (RED phase).")
    print("Se falharem, o código precisa ser corrigido (GREEN phase).\n")

    # Rodar testes
    exit_code = pytest.main([__file__, "-v", "--tb=short"])

    if exit_code == 0:
        print("\n" + "=" * 70)
        print("✅ ALL TESTS PASSED!")
        print("=" * 70)
    else:
        print("\n" + "=" * 70)
        print("❌ SOME TESTS FAILED - Code needs to be fixed")
        print("=" * 70)

    sys.exit(exit_code)
