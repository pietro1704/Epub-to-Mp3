#!/usr/bin/env python3
"""Quick test of new features: cover extraction and smart language detection."""

import sys
from pathlib import Path

# Add python_app to path
sys.path.insert(0, str(Path(__file__).parent / "python_app"))

from python_app.src.ebook_reader import EbookReader
from python_app.src.language.detector import LanguageDetector


def test_cover_extraction():
    """Test cover extraction from EPUB and PDF."""
    print("=" * 80)
    print("TEST 1: COVER EXTRACTION")
    print("=" * 80)

    # Test with EPUB
    epub_file = (
        "/Users/pietropugliesi/Downloads/Box Dom Quixote de la Mancha - Miguel de Cervantes.epub"
    )
    if Path(epub_file).exists():
        print(f"\n📚 Testando EPUB: {Path(epub_file).name}")
        reader = EbookReader(epub_file)
        cover = reader.extract_cover_image()
        if cover:
            print("✅ Cover extracted!")
            print(f"   - Type: {cover.media_type}")
            print(f"   - Extension: {cover.extension}")
            print(f"   - Size: {len(cover.data)} bytes")
        else:
            print("❌ No cover found")
    else:
        print(f"⚠️ EPUB file not found: {epub_file}")

    # Test with PDF
    pdf_file = "/Users/pietropugliesi/Downloads/OlavodeCarvalho-PlanetasnasCasas.pdf"
    if Path(pdf_file).exists():
        print(f"\n📄 Testando PDF: {Path(pdf_file).name}")
        reader = EbookReader(pdf_file)
        cover = reader.extract_cover_image()
        if cover:
            print("✅ Cover extracted!")
            print(f"   - Type: {cover.media_type}")
            print(f"   - Extension: {cover.extension}")
            print(f"   - Size: {len(cover.data)} bytes")
        else:
            print("❌ No cover found (normal for PDFs without images on the first page)")
    else:
        print(f"⚠️ PDF file not found: {pdf_file}")


def test_language_detection():
    """Test smart language detection with prioritization."""
    print("\n" + "=" * 80)
    print("TEST 2: SMART LANGUAGE DETECTION")
    print("=" * 80)

    detector = LanguageDetector()

    # Test 1: PT-BR vs Spanish (ambiguous sentence)
    print("\n📝 Test 1: PT-BR vs Spanish")
    print("-" * 80)

    text_pt_es = """
    Este é um livro sobre a história de Portugal. O país tem uma rica cultura.
    Buenas tardes, como vai você hoje? Esta frase pode ser confusa.
    A literatura portuguesa é muito interessante e diversificada.
    """

    print("Text:")
    print(text_pt_es.strip())
    print("\nWithout prioritization:")
    segments_no_priority = detector.detect_segments(text_pt_es, primary_language=None)
    for seg in segments_no_priority:
        print(f"  [{seg.language}] {seg.text[:80]}...")

    print("\nWith prioritization (primary_language='pt'):")
    segments_with_priority = detector.detect_segments(text_pt_es, primary_language="pt")
    for seg in segments_with_priority:
        print(f"  [{seg.language}] {seg.text[:80]}...")

    # Test 2: English vs German
    print("\n📝 Test 2: English vs German")
    print("-" * 80)

    text_en_de = """
    This is a book about the history of England. The country has a rich culture and heritage.
    Guten Tag, wie geht es Ihnen heute? This sentence might be confusing.
    The English literature is very interesting and diverse throughout history.
    """

    print("Text:")
    print(text_en_de.strip())
    print("\nWithout prioritization:")
    segments_no_priority = detector.detect_segments(text_en_de, primary_language=None)
    for seg in segments_no_priority:
        print(f"  [{seg.language}] {seg.text[:80]}...")

    print("\nWith prioritization (primary_language='en'):")
    segments_with_priority = detector.detect_segments(text_en_de, primary_language="en")
    for seg in segments_with_priority:
        print(f"  [{seg.language}] {seg.text[:80]}...")

    # Test 3: Genuinely ambiguous sentence
    print("\n📝 Test 3: Ambiguous sentence (pt-br vs Spanish)")
    print("-" * 80)

    ambiguous = "A cultura popular é muito interessante e diversificada em toda América"

    print(f"Text: '{ambiguous}'")

    # Detect multiple languages
    predictions = detector._detect_languages(ambiguous, top_n=3)
    print("\nDetector predictions:")
    for pred in predictions:
        print(f"  - {pred.code}: {pred.probability:.2%}")

    # With pt prioritization
    result_pt = detector._detect_language_with_timeout(
        ambiguous, primary_language="pt", ambiguity_threshold=0.15
    )
    print(f"\nWith primary_language='pt': {result_pt}")

    # With es prioritization
    result_es = detector._detect_language_with_timeout(
        ambiguous, primary_language="es", ambiguity_threshold=0.15
    )
    print(f"With primary_language='es': {result_es}")


if __name__ == "__main__":
    print("\n🧪 NEW FEATURES TEST\n")

    try:
        test_cover_extraction()
        test_language_detection()

        print("\n" + "=" * 80)
        print("✅ ALL TESTS COMPLETED!")
        print("=" * 80)

    except Exception as e:
        print(f"\n❌ ERRO: {e}")
        import traceback

        traceback.print_exc()
        sys.exit(1)
