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

    FORMAT_MARKER_RE = re.compile(r"\[\[fmt:[^\]]+\]\]|\[\[/fmt\]\]", re.IGNORECASE)
    def process_markup_tags(self, text: str) -> str:
        """Process markup tags from LanguageMarkup into formatting markers"""
        if not text:
            return text

        # Convert emphasis tags to formatting markers
        text = re.sub(r'\[\[emphasis:mild\]\](.*?)\[\[/emphasis\]\]', r'[[fmt:italic]]\1[[/fmt]]', text)
        text = re.sub(r'\[\[emphasis:strong\]\](.*?)\[\[/emphasis\]\]', r'[[fmt:bold]]\1[[/fmt]]', text)

        # Convert pause tags to SSML pauses (keep as-is for now)
        text = re.sub(r'\[\[pause:short\]\]', '<break time="300ms"/>', text)
        text = re.sub(r'\[\[pause:medium\]\]', '<break time="600ms"/>', text)
        text = re.sub(r'\[\[pause:long\]\]', '<break time="1s"/>', text)

        # Convert tone tags to prosody
        text = re.sub(r'\[\[tone:lower\]\](.*?)\[\[/tone\]\]', r'[[fmt:lower]]\1[[/fmt]]', text)

        return text

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

    INLINE_RENDERERS = {
        'italic': lambda value: f"_{value}_",
        'bold': lambda value: f"**{value}**",
        'emphasis': lambda value: f"_{value}_",
        'code': lambda value: f"`{value}`",
        'quote': lambda value: f'“{value}”',
        'small': lambda value: value,
        'lower': lambda value: value,
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

        # First process markup tags from LanguageMarkup
        text = self.process_markup_tags(html_text)

        # **NOVO**: Extrair atributos lang e converter para [[lang:xx]]
        text = self._extract_language_attributes(text)

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

        # **NOVO**: Adicionar marcadores para aspas inline e travessão de diálogo
        text = self._add_inline_emphasis_markers(text)

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
                # Itálico: tom mais alto, mais lento e volume reduzido para destacar
                ssml_parts.append(
                    f'<voice name="{voice}">'
                    f'<prosody rate="-20%" pitch="+15%" volume="-5%">{text}</prosody>'
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
            elif segment.formatting == 'lower':
                # Tom mais baixo (para parênteses)
                ssml_parts.append(
                    f'<voice name="{voice}">'
                    f'<prosody pitch="-15%" volume="-5%">{text}</prosody>'
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
                # Diálogo ou trecho enfatizado (travessão, exclamações etc.)
                parts.append(f"diálogo com ênfase: {text}")
            elif segment.formatting == 'code':
                parts.append(f"trecho de código: {text}")
            elif segment.formatting == 'quote':
                parts.append(f"entre aspas: {text}")
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

    def apply_inline_formatting(self, text: str) -> str:
        """Substitui marcadores internos por tokens de ênfase inline."""
        if not text:
            return ""

        marker_pattern = re.compile(r"\[\[fmt:(\w+)\]\](.*?)\[\[/fmt\]\]", re.DOTALL)

        def replace(match: re.Match) -> str:
            fmt_type = match.group(1)
            content = match.group(2)
            renderer = self.INLINE_RENDERERS.get(fmt_type)
            if renderer:
                rendered = renderer(content)
                return rendered
            return content

        formatted = marker_pattern.sub(replace, text)
        return formatted

    @classmethod
    def remove_formatting_markers(cls, text: str) -> str:
        """
        Remove marcadores [[fmt:...]] preservando o conteúdo interno.

        Mantém espaços e quebras de linha originais.
        """
        if not text:
            return ""

        return cls.FORMAT_MARKER_RE.sub("", text)

    @staticmethod
    def strip_inline_markdown(text: str) -> str:
        if not text:
            return ""

        # Remove marcadores [[fmt:...]]
        cleaned = TextFormattingProcessor.remove_formatting_markers(text)

        # Remove Markdown com padrões mais robustos
        # Permitir espaços dentro dos marcadores e múltiplas linhas
        cleaned = re.sub(r'\*\*\s*(.+?)\s*\*\*', r'\1', cleaned, flags=re.DOTALL)  # **texto**
        cleaned = re.sub(r'__\s*(.+?)\s*__', r'\1', cleaned, flags=re.DOTALL)      # __texto__
        cleaned = re.sub(r'_\s*([^_]+?)\s*_', r'\1', cleaned)                       # _texto_
        cleaned = re.sub(r'`([^`]+?)`', r'\1', cleaned)                              # `código`

        # Limpar asteriscos e underscores soltos que sobraram
        cleaned = re.sub(r'\*+', '', cleaned)  # Remove ** soltos
        cleaned = re.sub(r'_+', '', cleaned)   # Remove __ soltos

        # Normalizar espaços múltiplos
        cleaned = re.sub(r'[ \t]{2,}', ' ', cleaned)
        cleaned = re.sub(r'\n{3,}', '\n\n', cleaned)

        return cleaned.strip()

    @classmethod
    def clean_tts_text(cls, text: str) -> str:
        """
        Remove marcadores internos e markdown, preservando pistas de idioma.
        """
        if not text:
            return ""

        return cls.strip_inline_markdown(text)

    def to_audible_text(
        self,
        text: str,
        formatting_segments: Optional[List[FormattingSegment]] = None,
    ) -> str:
        """
        Converte o texto em uma versão pronta para o TTS, com pistas audíveis.
        """
        if not text and not formatting_segments:
            return ""

        segments = formatting_segments or self.parse_formatted_text(text)

        if not segments:
            return self.clean_tts_text(text)

        audible = self.to_plain_text_with_cues(segments)
        return self.clean_tts_text(audible)

    def _add_inline_emphasis_markers(self, text: str) -> str:
        """
        Adiciona marcadores de ênfase para padrões comuns em audiolivros:
        - "Texto entre aspas duplas" → [[fmt:quote]]..[[/fmt]]
        - —Diálogo com travessão → [[fmt:emphasis]]..[[/fmt]]

        IMPORTANTE: Não adicionar marcadores para markdown já processado (_italic_, **bold**)
        """
        if not text:
            return text

        # Detectar texto entre aspas duplas (curvas ou retas)
        # Ignora se já há marcador [[fmt:...]]
        quote_pattern = re.compile(r'(?<!\[\[fmt:)"([^"]{10,}?)"(?!\]\])', re.UNICODE)

        def add_quote_marker(match):
            content = match.group(1)
            # Não marcar se já tem marcador interno
            if '[[fmt:' in content:
                return match.group(0)
            return f'[[fmt:quote]]{content}[[/fmt]]'

        text = quote_pattern.sub(add_quote_marker, text)

        # Detectar travessão de diálogo (— ou --) no início de parágrafo/linha
        # Adiciona ênfase para diferenciar narração de diálogo
        dash_pattern = re.compile(r'^(—|--)\s*(.+?)$', re.MULTILINE)

        def add_dash_emphasis(match):
            dash = match.group(1)
            content = match.group(2)
            # Não marcar se já tem marcador
            if '[[fmt:' in content:
                return match.group(0)
            return f'{dash} [[fmt:emphasis]]{content}[[/fmt]]'

        text = dash_pattern.sub(add_dash_emphasis, text)

        return text

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

    def _extract_language_attributes(self, html_text: str) -> str:
        """
        Extrai atributos lang/xml:lang de tags HTML e converte para [[lang:xx]]
        Processa apenas tags de conteúdo (p, div, span), ignorando tags estruturais (html, body)

        Exemplo:
            <html lang="pt"><p lang="en">Hello</p></html>
            -> <html lang="pt">[[lang:en]]<p>Hello</p>[[/lang]]</html>
        """
        if not html_text:
            return html_text

        # Tags estruturais que devem ser ignoradas (não adicionar [[lang:]])
        structural_tags = {'html', 'body', 'head', 'article', 'section', 'header', 'footer', 'main', 'nav'}

        # Processar múltiplas vezes para capturar tags aninhadas
        # Começar das mais internas (menor distância entre abertura e fechamento)
        max_iterations = 10
        for _ in range(max_iterations):
            # Padrão para detectar tags com atributo lang
            # Captura: <tag lang="xx" ...> conteúdo </tag>
            lang_pattern = re.compile(
                r'<(\w+)\s+([^>]*?)(?:lang|xml:lang)=["\']([a-zA-Z\-]+)["\']([^>]*?)>(.*?)</\1>',
                re.IGNORECASE | re.DOTALL
            )

            match = lang_pattern.search(html_text)
            if not match:
                break  # Nenhuma tag lang encontrada

            tag_name = match.group(1).lower()
            attrs_before = match.group(2)
            lang_code = match.group(3)
            attrs_after = match.group(4)
            content = match.group(5)

            # **NOVO**: Ignorar tags estruturais para evitar quebrar capítulos
            if tag_name in structural_tags:
                # Remover apenas o atributo lang, mas não adicionar [[lang:]]
                attrs = (attrs_before + attrs_after).strip()
                if attrs:
                    new_tag = f'<{tag_name} {attrs}>'
                else:
                    new_tag = f'<{tag_name}>'

                replacement = f'{new_tag}{content}</{tag_name}>'
                html_text = html_text[:match.start()] + replacement + html_text[match.end():]
                continue

            # Remover atributo lang e reconstruir tag sem ele
            attrs = (attrs_before + attrs_after).strip()
            if attrs:
                new_tag = f'<{tag_name} {attrs}>'
            else:
                new_tag = f'<{tag_name}>'

            # Adicionar marcadores de idioma em torno do conteúdo
            replacement = f'{new_tag}[[lang:{lang_code}]]{content}[[/lang]]</{tag_name}>'

            # Substituir apenas a primeira ocorrência (mais interna)
            html_text = html_text[:match.start()] + replacement + html_text[match.end():]

        return html_text

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
