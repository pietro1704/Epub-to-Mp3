#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Find chapter 8.2 with footnotes and italic text
"""

from pathlib import Path
from src.ebook_reader import EbookReader


def find_chapter_8_2():
    """Find chapter 8.2 or similar with footnotes and formatting"""

    book_path = Path("O Jardim das Aflições.epub")
    if not book_path.exists():
        print("❌ Arquivo não encontrado: O Jardim das Aflições.epub")
        return

    print("🔍 Procurando capítulo 8.2 com notas de rodapé e texto em itálico...")
    print("=" * 60)

    # Read book
    reader = EbookReader(book_path)
    chapters = list(reader.get_chapter_structure() or [])

    print(f"📚 Total de capítulos: {len(chapters)}")

    # Look for chapters with "8" in title or similar patterns
    target_patterns = ["8.2", "8 ", "VIII", "Capítulo 8", "Cap. 8"]
    footnote_patterns = ["[", "]", "¹", "²", "³", "⁴", "⁵", "(", ")", "nota", "cf.", "ver"]
    italic_patterns = ["<em>", "</em>", "<i>", "</i>", "_", "*", "itálico", "ênfase"]

    candidates = []

    for idx, chapter in enumerate(chapters):
        chapter_num = idx + 1
        chapter_title = chapter.name.lower()
        text = chapter.text

        # Check if chapter matches target patterns
        is_target = any(pattern.lower() in chapter_title for pattern in target_patterns)

        # Count footnote indicators
        footnote_count = sum(text.count(pattern) for pattern in footnote_patterns)

        # Count italic indicators
        italic_count = sum(text.count(pattern) for pattern in italic_patterns)

        # Score chapter based on footnotes, italics, and if it's target
        score = footnote_count + italic_count * 2
        if is_target:
            score += 50

        if score > 5:  # Minimum threshold
            candidates.append({
                'idx': idx,
                'num': chapter_num,
                'title': chapter.name,
                'footnotes': footnote_count,
                'italics': italic_count,
                'score': score,
                'text_preview': text[:500]
            })

    # Sort by score
    candidates.sort(key=lambda x: x['score'], reverse=True)

    print(f"\n🎯 Encontrados {len(candidates)} capítulos candidatos:")
    print("-" * 60)

    for i, candidate in enumerate(candidates[:5]):  # Top 5
        print(f"\n{i+1}. CAPÍTULO {candidate['num']}: {candidate['title']}")
        print(f"   📊 Score: {candidate['score']} (notas: {candidate['footnotes']}, itálico: {candidate['italics']})")
        print(f"   📄 Preview: {candidate['text_preview'][:200]}...")

        # Show specific patterns found
        text = candidate['text_preview']
        found_footnotes = [p for p in footnote_patterns if p in text]
        found_italics = [p for p in italic_patterns if p in text]

        if found_footnotes:
            print(f"   📝 Notas encontradas: {found_footnotes}")
        if found_italics:
            print(f"   🔤 Formatação encontrada: {found_italics}")

    # Return best candidate
    if candidates:
        best = candidates[0]
        print(f"\n✅ Melhor candidato: Capítulo {best['num']} - {best['title']}")
        return best['idx']
    else:
        print("\n❌ Nenhum capítulo adequado encontrado")
        return None


if __name__ == "__main__":
    find_chapter_8_2()