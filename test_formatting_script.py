#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import sys
sys.path.insert(0, '/Users/pietropugliesi/Developer/testCOnvert/definitiv')

from src.text_formatting import TextFormattingProcessor

def test_formatting():
    with open('test_formatting.html', 'r', encoding='utf-8') as f:
        html_content = f.read()

    print("HTML original:")
    print(html_content)
    print("\n" + "="*80 + "\n")

    processor = TextFormattingProcessor()

    # Test extract_formatting
    print("1. Extraindo formatação...")
    marked_text = processor.extract_formatting(html_content)
    print("Texto com marcadores:")
    print(marked_text)
    print("\n" + "="*80 + "\n")

    # Test parsing
    print("2. Analisando segmentos...")
    segments = processor.parse_formatted_text(marked_text)
    print(f"Encontrados {len(segments)} segmentos:")
    for i, segment in enumerate(segments):
        print(f"  {i+1}. [{segment.formatting}] {segment.text[:50]}...")
    print("\n" + "="*80 + "\n")

    # Test SSML generation
    print("3. Gerando SSML...")
    ssml = processor.to_edge_ssml(segments)
    print("SSML gerado:")
    print(ssml)
    print("\n" + "="*80 + "\n")

    # Test plain text with cues
    print("4. Texto simples com indicações...")
    plain_with_cues = processor.to_plain_text_with_cues(segments)
    print(plain_with_cues)

if __name__ == "__main__":
    test_formatting()