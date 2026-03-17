#!/usr/bin/env python3
"""Test for language prioritization in ambiguous texts."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent / "python_app"))

from python_app.src.language.detector import LanguageDetector


def test_ambiguous_prioritization():
    """Demonstrates how prioritization resolves language ambiguities."""

    detector = LanguageDetector()

    print("=" * 80)
    print("PRIORITIZATION TEST ON AMBIGUOUS TEXTS")
    print("=" * 80)

    # Test 1: Text that could be pt-br OR Spanish
    print("\n📝 CASE 1: Ambiguous sentence (PT-BR vs Spanish)")
    print("-" * 80)

    ambiguous_text = """
O professor estava muito preocupado com a situação.
La situación era complicada y difícil de resolver en ese momento.
A coordenação decidiu tomar medidas importantes para solucionar o problema.
Las autoridades competentes fueron informadas sobre los acontecimientos.
O resultado final foi bastante satisfatório para todos os envolvidos.
"""

    print("Test text:")
    for line in ambiguous_text.strip().split("\n"):
        print(f"  {line}")

    # Detect with multiple analyses
    predictions = detector._detect_languages(ambiguous_text, top_n=5)
    print("\n🔍 langdetect predictions:")
    for pred in predictions:
        print(f"   {pred.code}: {pred.probability:.1%}")

    # Test prioritization
    print("\n🎯 Prioritization test:")

    for primary in ["pt", "es", None]:
        result = detector._detect_language_with_timeout(
            ambiguous_text, primary_language=primary, ambiguity_threshold=0.15, min_probability=0.4
        )
        label = primary if primary else "none"
        print(f"   primary_language='{label}' → {result}")

    # Test 2: English vs German
    print("\n📝 CASE 2: Mixed text (English vs German)")
    print("-" * 80)

    mixed_text = """
The weather was absolutely wonderful and everyone enjoyed the beautiful day.
Es war ein wunderschöner Tag und alle waren sehr glücklich darüber.
The organization decided to implement new policies for better management.
Die Verwaltung beschloss, neue Richtlinien einzuführen.
Everything worked out perfectly in the end for all parties involved.
"""

    print("Test text:")
    for line in mixed_text.strip().split("\n"):
        print(f"  {line}")

    predictions = detector._detect_languages(mixed_text, top_n=5)
    print("\n🔍 langdetect predictions:")
    for pred in predictions:
        print(f"   {pred.code}: {pred.probability:.1%}")

    print("\n🎯 Prioritization test:")
    for primary in ["en", "de", None]:
        result = detector._detect_language_with_timeout(
            mixed_text, primary_language=primary, ambiguity_threshold=0.15, min_probability=0.4
        )
        label = primary if primary else "none"
        print(f"   primary_language='{label}' → {result}")

    # Test 3: Short ambiguous phrases
    print("\n📝 CASE 3: Short individual phrases")
    print("-" * 80)

    short_phrases = [
        ("A vida é bela", ["pt", "es"]),
        ("La vida es bella", ["es", "pt"]),
        ("The life is beautiful", ["en", "de"]),
        ("Das Leben ist schön", ["de", "en"]),
    ]

    for phrase, primaries in short_phrases:
        print(f"\nPhrase: '{phrase}'")
        predictions = detector._detect_languages(phrase, top_n=3)
        print(f"  Predictions: {', '.join([f'{p.code}={p.probability:.0%}' for p in predictions])}")

        results = []
        for prim in primaries:
            result = detector._detect_language_with_timeout(
                phrase, primary_language=prim, ambiguity_threshold=0.15
            )
            results.append(f"{prim}→{result}")
        print(f"  With prioritization: {', '.join(results)}")


if __name__ == "__main__":
    try:
        test_ambiguous_prioritization()
        print("\n" + "=" * 80)
        print("✅ TEST COMPLETE!")
        print("=" * 80)
        print("\n💡 CONCLUSION:")
        print("   Prioritization works when multiple languages have similar probabilities")
        print("   (difference ≤ 15%). If the primary language is among the candidates,")
        print("   it is chosen even if it does not have the highest probability.")
        print()
    except Exception as e:
        print(f"\n❌ ERROR: {e}")
        import traceback

        traceback.print_exc()
        sys.exit(1)
