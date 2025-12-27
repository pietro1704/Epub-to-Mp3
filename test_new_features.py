#!/usr/bin/env python3
"""Teste rápido das novas features: extração de capa e detecção inteligente de idioma."""

import sys
from pathlib import Path

# Add python_app to path
sys.path.insert(0, str(Path(__file__).parent / "python_app"))

from python_app.src.ebook_reader import EbookReader
from python_app.src.language.detector import LanguageDetector


def test_cover_extraction():
    """Testa extração de capa de EPUB e PDF."""
    print("=" * 80)
    print("TESTE 1: EXTRAÇÃO DE CAPA")
    print("=" * 80)

    # Teste com EPUB
    epub_file = (
        "/Users/pietropugliesi/Downloads/Box Dom Quixote de la Mancha - Miguel de Cervantes.epub"
    )
    if Path(epub_file).exists():
        print(f"\n📚 Testando EPUB: {Path(epub_file).name}")
        reader = EbookReader(epub_file)
        cover = reader.extract_cover_image()
        if cover:
            print("✅ Capa extraída!")
            print(f"   - Tipo: {cover.media_type}")
            print(f"   - Extensão: {cover.extension}")
            print(f"   - Tamanho: {len(cover.data)} bytes")
        else:
            print("❌ Nenhuma capa encontrada")
    else:
        print(f"⚠️ Arquivo EPUB não encontrado: {epub_file}")

    # Teste com PDF
    pdf_file = "/Users/pietropugliesi/Downloads/OlavodeCarvalho-PlanetasnasCasas.pdf"
    if Path(pdf_file).exists():
        print(f"\n📄 Testando PDF: {Path(pdf_file).name}")
        reader = EbookReader(pdf_file)
        cover = reader.extract_cover_image()
        if cover:
            print("✅ Capa extraída!")
            print(f"   - Tipo: {cover.media_type}")
            print(f"   - Extensão: {cover.extension}")
            print(f"   - Tamanho: {len(cover.data)} bytes")
        else:
            print("❌ Nenhuma capa encontrada (normal para PDFs sem imagens na primeira página)")
    else:
        print(f"⚠️ Arquivo PDF não encontrado: {pdf_file}")


def test_language_detection():
    """Testa detecção inteligente de idioma com priorização."""
    print("\n" + "=" * 80)
    print("TESTE 2: DETECÇÃO INTELIGENTE DE IDIOMA")
    print("=" * 80)

    detector = LanguageDetector()

    # Teste 1: PT-BR vs Espanhol (frase ambígua)
    print("\n📝 Teste 1: PT-BR vs Espanhol")
    print("-" * 80)

    text_pt_es = """
    Este é um livro sobre a história de Portugal. O país tem uma rica cultura.
    Buenas tardes, como vai você hoje? Esta frase pode ser confusa.
    A literatura portuguesa é muito interessante e diversificada.
    """

    print("Texto:")
    print(text_pt_es.strip())
    print("\nSem priorização:")
    segments_no_priority = detector.detect_segments(text_pt_es, primary_language=None)
    for seg in segments_no_priority:
        print(f"  [{seg.language}] {seg.text[:80]}...")

    print("\nCom priorização (primary_language='pt'):")
    segments_with_priority = detector.detect_segments(text_pt_es, primary_language="pt")
    for seg in segments_with_priority:
        print(f"  [{seg.language}] {seg.text[:80]}...")

    # Teste 2: Inglês vs Alemão
    print("\n📝 Teste 2: Inglês vs Alemão")
    print("-" * 80)

    text_en_de = """
    This is a book about the history of England. The country has a rich culture and heritage.
    Guten Tag, wie geht es Ihnen heute? This sentence might be confusing.
    The English literature is very interesting and diverse throughout history.
    """

    print("Texto:")
    print(text_en_de.strip())
    print("\nSem priorização:")
    segments_no_priority = detector.detect_segments(text_en_de, primary_language=None)
    for seg in segments_no_priority:
        print(f"  [{seg.language}] {seg.text[:80]}...")

    print("\nCom priorização (primary_language='en'):")
    segments_with_priority = detector.detect_segments(text_en_de, primary_language="en")
    for seg in segments_with_priority:
        print(f"  [{seg.language}] {seg.text[:80]}...")

    # Teste 3: Frase realmente ambígua
    print("\n📝 Teste 3: Frase ambígua (pt-br vs espanhol)")
    print("-" * 80)

    ambiguous = "A cultura popular é muito interessante e diversificada em toda América"

    print(f"Texto: '{ambiguous}'")

    # Detectar múltiplas línguas
    predictions = detector._detect_languages(ambiguous, top_n=3)
    print("\nPredições do detector:")
    for pred in predictions:
        print(f"  - {pred.code}: {pred.probability:.2%}")

    # Com priorização pt
    result_pt = detector._detect_language_with_timeout(
        ambiguous, primary_language="pt", ambiguity_threshold=0.15
    )
    print(f"\nCom primary_language='pt': {result_pt}")

    # Com priorização es
    result_es = detector._detect_language_with_timeout(
        ambiguous, primary_language="es", ambiguity_threshold=0.15
    )
    print(f"Com primary_language='es': {result_es}")


if __name__ == "__main__":
    print("\n🧪 TESTE DAS NOVAS FEATURES\n")

    try:
        test_cover_extraction()
        test_language_detection()

        print("\n" + "=" * 80)
        print("✅ TODOS OS TESTES CONCLUÍDOS!")
        print("=" * 80)

    except Exception as e:
        print(f"\n❌ ERRO: {e}")
        import traceback

        traceback.print_exc()
        sys.exit(1)
