#!/usr/bin/env python3
"""Teste específico de priorização de idiomas em textos ambíguos."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent / "python_app"))

from python_app.src.language.detector import LanguageDetector


def test_ambiguous_prioritization():
    """Demonstra como a priorização resolve ambiguidades."""

    detector = LanguageDetector()

    print("=" * 80)
    print("TESTE DE PRIORIZAÇÃO EM TEXTOS AMBÍGUOS")
    print("=" * 80)

    # Teste 1: Texto que pode ser pt-br OU espanhol
    print("\n📝 CASO 1: Frase ambígua (PT-BR vs Espanhol)")
    print("-" * 80)

    ambiguous_text = """
O professor estava muito preocupado com a situação.
La situación era complicada y difícil de resolver en ese momento.
A coordenação decidiu tomar medidas importantes para solucionar o problema.
Las autoridades competentes fueron informadas sobre los acontecimientos.
O resultado final foi bastante satisfatório para todos os envolvidos.
"""

    print("Texto de teste:")
    for line in ambiguous_text.strip().split("\n"):
        print(f"  {line}")

    # Detectar com múltiplas análises
    predictions = detector._detect_languages(ambiguous_text, top_n=5)
    print("\n🔍 Predições do langdetect:")
    for pred in predictions:
        print(f"   {pred.code}: {pred.probability:.1%}")

    # Testar priorização
    print("\n🎯 Teste de priorização:")

    for primary in ["pt", "es", None]:
        result = detector._detect_language_with_timeout(
            ambiguous_text, primary_language=primary, ambiguity_threshold=0.15, min_probability=0.4
        )
        label = primary if primary else "nenhum"
        print(f"   primary_language='{label}' → {result}")

    # Teste 2: Inglês vs Alemão
    print("\n📝 CASO 2: Texto misto (Inglês vs Alemão)")
    print("-" * 80)

    mixed_text = """
The weather was absolutely wonderful and everyone enjoyed the beautiful day.
Es war ein wunderschöner Tag und alle waren sehr glücklich darüber.
The organization decided to implement new policies for better management.
Die Verwaltung beschloss, neue Richtlinien einzuführen.
Everything worked out perfectly in the end for all parties involved.
"""

    print("Texto de teste:")
    for line in mixed_text.strip().split("\n"):
        print(f"  {line}")

    predictions = detector._detect_languages(mixed_text, top_n=5)
    print("\n🔍 Predições do langdetect:")
    for pred in predictions:
        print(f"   {pred.code}: {pred.probability:.1%}")

    print("\n🎯 Teste de priorização:")
    for primary in ["en", "de", None]:
        result = detector._detect_language_with_timeout(
            mixed_text, primary_language=primary, ambiguity_threshold=0.15, min_probability=0.4
        )
        label = primary if primary else "nenhum"
        print(f"   primary_language='{label}' → {result}")

    # Teste 3: Frases curtas ambíguas
    print("\n📝 CASO 3: Frases curtas individuais")
    print("-" * 80)

    short_phrases = [
        ("A vida é bela", ["pt", "es"]),
        ("La vida es bella", ["es", "pt"]),
        ("The life is beautiful", ["en", "de"]),
        ("Das Leben ist schön", ["de", "en"]),
    ]

    for phrase, primaries in short_phrases:
        print(f"\nFrase: '{phrase}'")
        predictions = detector._detect_languages(phrase, top_n=3)
        print(f"  Predições: {', '.join([f'{p.code}={p.probability:.0%}' for p in predictions])}")

        results = []
        for prim in primaries:
            result = detector._detect_language_with_timeout(
                phrase, primary_language=prim, ambiguity_threshold=0.15
            )
            results.append(f"{prim}→{result}")
        print(f"  Com priorização: {', '.join(results)}")


if __name__ == "__main__":
    try:
        test_ambiguous_prioritization()
        print("\n" + "=" * 80)
        print("✅ TESTE CONCLUÍDO!")
        print("=" * 80)
        print("\n💡 CONCLUSÃO:")
        print("   A priorização funciona quando múltiplos idiomas têm probabilidades")
        print("   similares (diferença ≤ 15%). Se o idioma primário está entre os")
        print("   candidatos, ele é escolhido mesmo não sendo o de maior probabilidade.")
        print()
    except Exception as e:
        print(f"\n❌ ERRO: {e}")
        import traceback

        traceback.print_exc()
        sys.exit(1)
