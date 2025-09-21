# -*- coding: utf-8 -*-
"""
Sistema de detecção e marcação de formatação de texto para diferenciação no áudio
"""

import re
from typing import List, Dict, Any, Optional
from dataclasses import dataclass


@dataclass
class FormattingSegment:
    """Segmento de texto com formatação específica"""
    text: str
    formatting: str  # 'normal', 'italic', 'bold', 'emphasis', 'strong', etc.
    language: Optional[str] = None


class TextFormattingProcessor:
    """Processador de formatação de texto para diferenciação no áudio"""

    # Padrões HTML/EPUB comuns para formatação
    FORMATTING_PATTERNS = {
        'italic': [
            r'<i\b[^>]*>(.*?)</i>',
            r'<em\b[^>]*>(.*?)</em>',
            r'<cite\b[^>]*>(.*?)</cite>',
        ],
        'bold': [
            r'<b\b[^>]*>(.*?)</b>',
            r'<strong\b[^>]*>(.*?)</strong>',
        ],
        'emphasis': [
            r'<emphasis\b[^>]*>(.*?)</emphasis>',
        ],
        'code': [
            r'<code\b[^>]*>(.*?)</code>',
            r'<tt\b[^>]*>(.*?)</tt>',
        ],
        'quote': [
            r'<blockquote\b[^>]*>(.*?)</blockquote>',
            r'<q\b[^>]*>(.*?)</q>',
        ],
        'small': [
            r'<small\b[^>]*>(.*?)</small>',
            r'<sub\b[^>]*>(.*?)</sub>',
            r'<sup\b[^>]*>(.*?)</sup>',
        ]
    }

    # Marcadores internos para preservar formatação
    INTERNAL_MARKERS = {
        'italic': '[[fmt:italic]]{}[[/fmt]]',
        'bold': '[[fmt:bold]]{}[[/fmt]]',
        'emphasis': '[[fmt:emphasis]]{}[[/fmt]]',
        'code': '[[fmt:code]]{}[[/fmt]]',
        'quote': '[[fmt:quote]]{}[[/fmt]]',
        'small': '[[fmt:small]]{}[[/fmt]]',
    }

    def __init__(self):
        self.compiled_patterns = {}
        for fmt_type, patterns in self.FORMATTING_PATTERNS.items():
            self.compiled_patterns[fmt_type] = [
                re.compile(pattern, re.IGNORECASE | re.DOTALL) for pattern in patterns
            ]

    def extract_formatting(self, html_text: str) -> str:
        """Extrai formatação do HTML e converte para marcadores internos"""
        if not html_text:
            return html_text

        text = html_text

        # Processar cada tipo de formatação
        for fmt_type, patterns in self.compiled_patterns.items():
            marker_template = self.INTERNAL_MARKERS[fmt_type]

            for pattern in patterns:
                def replace_with_marker(match):
                    content = match.group(1)
                    # Remover tags HTML internas mas preservar conteúdo
                    clean_content = re.sub(r'<[^>]+>', '', content)
                    return marker_template.format(clean_content)

                text = pattern.sub(replace_with_marker, text)

        return text

    def parse_formatted_text(self, text: str) -> List[FormattingSegment]:
        """Converte texto com marcadores internos em segmentos formatados"""
        if not text:
            return []

        segments = []

        # Padrão para encontrar marcadores internos
        marker_pattern = re.compile(r'\[\[fmt:(\w+)\]\](.*?)\[\[/fmt\]\]', re.DOTALL)

        last_end = 0

        for match in marker_pattern.finditer(text):
            start, end = match.span()

            # Adicionar texto normal antes do marcador
            if start > last_end:
                normal_text = text[last_end:start].strip()
                if normal_text:
                    segments.append(FormattingSegment(normal_text, 'normal'))

            # Adicionar texto formatado
            fmt_type = match.group(1)
            fmt_text = match.group(2).strip()
            if fmt_text:
                segments.append(FormattingSegment(fmt_text, fmt_type))

            last_end = end

        # Adicionar texto restante
        if last_end < len(text):
            remaining_text = text[last_end:].strip()
            if remaining_text:
                segments.append(FormattingSegment(remaining_text, 'normal'))

        # Se não há formatação, retornar texto completo como normal
        if not segments and text.strip():
            segments.append(FormattingSegment(text.strip(), 'normal'))

        return segments

    def to_edge_ssml(self, segments: List[FormattingSegment], voice: str = "pt-BR-ThalitaMultilingualNeural") -> str:
        """Converte segmentos formatados para SSML do Edge TTS"""
        if not segments:
            return ""

        ssml_parts = [
            '<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" '
            'xmlns:mstts="http://www.w3.org/2001/mstts">'
        ]

        for segment in segments:
            text = self._escape_ssml(segment.text)

            if segment.formatting == 'italic':
                # Itálico: tom ligeiramente mais alto e mais lento
                ssml_parts.append(
                    f'<voice name="{voice}">'
                    f'<prosody rate="-10%" pitch="+5%">{text}</prosody>'
                    f'</voice>'
                )
            elif segment.formatting == 'bold':
                # Negrito: mais forte e um pouco mais lento
                ssml_parts.append(
                    f'<voice name="{voice}">'
                    f'<prosody volume="+20%" rate="-5%">{text}</prosody>'
                    f'</voice>'
                )
            elif segment.formatting == 'emphasis':
                # Ênfase: pausa antes e depois, tom diferente
                ssml_parts.append(
                    f'<voice name="{voice}">'
                    f'<break time="200ms"/>'
                    f'<prosody rate="-15%" pitch="+10%">{text}</prosody>'
                    f'<break time="200ms"/>'
                    f'</voice>'
                )
            elif segment.formatting == 'code':
                # Código: mais monótono e pausado
                ssml_parts.append(
                    f'<voice name="{voice}">'
                    f'<break time="100ms"/>'
                    f'<prosody rate="-30%" pitch="-5%">{text}</prosody>'
                    f'<break time="100ms"/>'
                    f'</voice>'
                )
            elif segment.formatting == 'quote':
                # Citação: pausa e tom diferente
                ssml_parts.append(
                    f'<voice name="{voice}">'
                    f'<break time="300ms"/>'
                    f'<prosody rate="-10%" pitch="-10%">{text}</prosody>'
                    f'<break time="300ms"/>'
                    f'</voice>'
                )
            elif segment.formatting == 'small':
                # Texto pequeno: mais rápido e baixo
                ssml_parts.append(
                    f'<voice name="{voice}">'
                    f'<prosody rate="+10%" volume="-10%">{text}</prosody>'
                    f'</voice>'
                )
            else:  # normal
                ssml_parts.append(f'<voice name="{voice}">{text}</voice>')

        ssml_parts.append('</speak>')
        return ''.join(ssml_parts)

    def to_plain_text_with_cues(self, segments: List[FormattingSegment]) -> str:
        """Converte para texto simples com indicações verbais de formatação"""
        if not segments:
            return ""

        parts = []

        for segment in segments:
            text = segment.text

            if segment.formatting == 'italic':
                parts.append(f"em itálico: {text}")
            elif segment.formatting == 'bold':
                parts.append(f"em negrito: {text}")
            elif segment.formatting == 'emphasis':
                parts.append(f"com ênfase: {text}")
            elif segment.formatting == 'code':
                parts.append(f"código: {text}")
            elif segment.formatting == 'quote':
                parts.append(f"citação: {text}")
            elif segment.formatting == 'small':
                parts.append(f"texto pequeno: {text}")
            else:  # normal
                parts.append(text)

        return ' '.join(parts)

    def to_plain_text_with_pauses(self, segments: List[FormattingSegment]) -> str:
        """Converte para texto simples com pausas para indicar formatação"""
        if not segments:
            return ""

        parts = []

        for segment in segments:
            text = segment.text

            if segment.formatting in ['italic', 'emphasis']:
                parts.append(f"... {text} ...")
            elif segment.formatting == 'bold':
                parts.append(f"-- {text} --")
            elif segment.formatting == 'quote':
                parts.append(f'"" {text} ""')
            else:  # normal, code, small
                parts.append(text)

        return ' '.join(parts)

    def _escape_ssml(self, text: str) -> str:
        """Escapa caracteres especiais para SSML"""
        if not text:
            return ""

        # Escapar caracteres XML/SSML
        text = text.replace('&', '&amp;')
        text = text.replace('<', '&lt;')
        text = text.replace('>', '&gt;')
        text = text.replace('"', '&quot;')
        text = text.replace("'", '&apos;')

        return text

    def clean_html_tags(self, text: str) -> str:
        """Remove todas as tags HTML do texto"""
        if not text:
            return text

        # Primeiro extrair formatação
        text_with_markers = self.extract_formatting(text)

        # Remover tags HTML restantes
        clean_text = re.sub(r'<[^>]+>', '', text_with_markers)

        # Limpar espaços múltiplos
        clean_text = re.sub(r'\s+', ' ', clean_text)

        return clean_text.strip()


__all__ = ["TextFormattingProcessor", "FormattingSegment"]