# -*- coding: utf-8 -*-
"""Lightweight EPUB/PDF reader used across the simplified test-suite."""

from __future__ import annotations

import re
import zipfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple
from urllib.parse import unquote
from xml.etree import ElementTree as ET

from .text_formatting import TextFormattingProcessor, FormattingSegment

try:  # pragma: no cover - exercised indirectly in tests
    import pypdf  # type: ignore
    PDF_AVAILABLE = True
except ImportError:  # pragma: no cover - when pypdf is missing
    pypdf = None
    PDF_AVAILABLE = False

# Public regular expressions expected by the tests ---------------------------------
TAG_RE = re.compile(r"<[^>]+>")
WHITESPACE_RE = re.compile(r"[ \t\f\v]+")
NBSP_RE = re.compile(r"(?:&nbsp;|\u00A0)", re.I)
PARA_BLOCK_RE = re.compile(r"</?(p|div|br|li|tr|td|th|blockquote|section|article|hr)[^>]*>", re.I)
STYLE_RE = re.compile(r"(?is)<style.*?>.*?</style>")
SCRIPT_RE = re.compile(r"(?is)<script.*?>.*?</script>")
ARTIFACT_RE = re.compile(r"\b(?:[\w\-/]+\.(?:xhtml|html|opf|ncx|css)|\d+_[\w-]+)\b", re.I)
H_TAG = re.compile(r"<h([1-6])[^>]*>(.*?)</h\1>", re.I | re.DOTALL)
PAGE_BREAK_RE = re.compile(
    r"page-break-before\s*:\s*always|page-break-after\s*:\s*always|break-before\s*:\s*page|break-after\s*:\s*page",
    re.I,
)

XML_NS = {
    "ocf": "urn:oasis:names:tc:opendocument:xmlns:container",
    "opf": "http://www.idpf.org/2007/opf",
    "dc": "http://purl.org/dc/elements/1.1/",
    "ncx": "http://www.daisy.org/z3986/2005/ncx/",
}


@dataclass(slots=True)
class Chapter:
    index: int | str
    name: str
    source_path: str
    text: str
    level: int = 1
    raw_html: Optional[str] = None
    formatting_segments: Optional[List[FormattingSegment]] = None
    speech_text: Optional[str] = None
    footnotes: Optional[List[Dict[str, str]]] = None


@dataclass(slots=True)
class TocItem:
    title: str
    href: str
    level: int
    children: List['TocItem'] = field(default_factory=list)


@dataclass(slots=True)
class Book:
    title: str
    author: str
    chapters: List[Chapter]
    toc: List[TocItem] = field(default_factory=list)


class TextProcessor:
    """Utility helpers for dealing with HTML text inside EPUB files."""

    @staticmethod
    def html_to_plain_text_with_formatting(content: Optional[str]) -> Tuple[str, List[FormattingSegment]]:
        """Convert HTML to plain text while preserving formatting information"""
        if not content:
            return "", []

        # Initialize formatting processor
        formatter = TextFormattingProcessor()

        # Extract formatting and convert to internal markers
        text_with_markers = formatter.extract_formatting(content)

        # Apply standard text processing
        text = str(text_with_markers)
        text = STYLE_RE.sub("", text)
        text = SCRIPT_RE.sub("", text)
        text = NBSP_RE.sub(" ", text)
        text = ARTIFACT_RE.sub(" ", text)
        text = re.sub(r"(?is)<head.*?>.*?</head>", "", text)
        text = text.replace("\r", "\n")
        text = PARA_BLOCK_RE.sub("\n", text)

        # Clean remaining HTML tags but preserve formatting markers
        text = re.sub(r'<(?!/?fmt)[^>]+>', '', text)  # Remove HTML tags but keep [[fmt:...]] markers
        text = WHITESPACE_RE.sub(" ", text)
        text = re.sub(r"\n{3,}", "\n\n", text)

        lines = [line.strip() for line in text.split("\n")]
        lines = [line for line in lines if line]
        clean_text = "\n".join(lines)

        # Parse the text with formatting markers into segments
        formatting_segments = formatter.parse_formatted_text(clean_text)

        # Render inline emphasis markers back into the text
        formatted_text = formatter.apply_inline_formatting(clean_text)
        formatted_text = re.sub(r"[ \t]{2,}", " ", formatted_text)
        formatted_text = re.sub(r"\s*\n\s*", "\n", formatted_text)
        formatted_text = formatted_text.strip()

        return formatted_text, formatting_segments

    @staticmethod
    def html_to_plain_text(content: Optional[str]) -> str:
        if not content:
            return ""

        text = str(content)
        text = STYLE_RE.sub("", text)
        text = SCRIPT_RE.sub("", text)
        text = NBSP_RE.sub(" ", text)
        text = ARTIFACT_RE.sub(" ", text)
        text = re.sub(r"(?is)<head.*?>.*?</head>", "", text)
        text = text.replace("\r", "\n")
        text = PARA_BLOCK_RE.sub("\n", text)
        text = TAG_RE.sub("", text)
        text = WHITESPACE_RE.sub(" ", text)
        text = re.sub(r"\n{3,}", "\n\n", text)

        lines = [line.strip() for line in text.split("\n")]
        lines = [line for line in lines if line]
        return "\n".join(lines)

    @staticmethod
    def inject_footnotes(
        markup: Optional[str],
        mode: str = "inline",
        context_words: int = 8,
        external_file_resolver = None,
    ) -> tuple[str, List[Dict[str, str]]]:
        if not markup:
            return "", []

        try:
            from bs4 import BeautifulSoup  # type: ignore
        except ImportError:  # pragma: no cover - optional dependency
            BeautifulSoup = None

        if BeautifulSoup is not None:
            processed_markup, footnotes = TextProcessor._collect_footnotes_bs4(str(markup), BeautifulSoup, external_file_resolver)
        else:
            processed_markup, footnotes = TextProcessor._collect_footnotes_fallback(str(markup))

        return processed_markup, footnotes

    @staticmethod
    def _collect_footnotes_bs4(markup: str, BeautifulSoup, external_file_resolver=None) -> Tuple[str, List[Dict[str, str]]]:
        soup = BeautifulSoup(markup, "html.parser")
        if soup is None:
            return markup, []

        footnotes: List[Dict[str, str]] = []
        note_numbers: Dict[str, str] = {}
        processed_targets: List[str] = []
        external_footnote_cache: Dict[str, any] = {}

        def normalise_fragment(href: str) -> str:
            if not href:
                return ""
            fragment = href.split('#', 1)[-1] if '#' in href else ""
            return fragment.strip()

        def looks_like_noteref(anchor, target_text: str) -> bool:
            if anchor is None or not hasattr(anchor, "get"):
                return False
            anchor_text = (anchor.get_text(" ", strip=True) or "").strip()
            role = (safe_get(anchor, "role", "") or "").lower()
            epub_type = ""
            for attr_name in ("epub:type", "epub:type", "epub-type", "type"):
                value = safe_get(anchor, attr_name)
                if value:
                    epub_type = str(value).lower()
                    break
            classes = normalise_classes(safe_get(anchor, "class", []))
            href_value = (safe_get(anchor, "href", "") or safe_get(anchor, "xlink:href", "") or "").lower()
            anchor_id = (safe_get(anchor, "id", "") or "").lower()

            if (
                "noteref" in classes
                or "footnote" in classes
                or role == "doc-noteref"
                or epub_type == "noteref"
                or "footnote" in href_value
                or "footnote" in anchor_id
                or "idfootnotelink" in classes
            ):
                return True
            if anchor_text:
                digits_only = "".join(ch for ch in anchor_text if ch.isdigit())
                if digits_only.isdigit():
                    return True
            if target_text and any(token in target_text.lower() for token in ("nota", "footnote", "rodapé", "rodape")):
                return True
            return False

        def safe_get(tag, key, default=None):
            """Safely access BeautifulSoup tag attributes even when attrs is missing."""
            if tag is None or not hasattr(tag, "attrs"):
                return default
            attrs = getattr(tag, "attrs", None)
            if not isinstance(attrs, dict):
                return default
            return attrs.get(key, default)

        def normalise_classes(value) -> List[str]:
            if not value:
                return []
            if isinstance(value, (list, tuple, set)):
                return [str(item).lower() for item in value]
            return [str(value).lower()]

        def extract_note_text(node) -> str:
            if node is None:
                return ""
            # If node is an empty anchor, use parent instead
            if node.name == 'a' and not node.get_text(strip=True) and node.parent:
                node = node.parent
            for backlink in node.find_all('a'):
                if backlink is None or not hasattr(backlink, "get"):
                    continue
                href = safe_get(backlink, 'href', '')
                if href.startswith('#'):
                    backlink.decompose()
            raw = node.get_text(" ", strip=True)
            return TextProcessor.normalise_whitespace(raw)

        def strip_leading_label(text: str, label: str) -> str:
            if not text:
                return ""
            cleaned = text.strip()
            label = (label or "").strip()
            if label:
                candidates = [label, f"[{label}]", f"({label})", f"{label}.", f"{label}:", f"{label}-"]
                lowered = cleaned.lower()
                for candidate in candidates:
                    candidate_clean = candidate.strip()
                    if not candidate_clean:
                        continue
                    if lowered.startswith(candidate_clean.lower()):
                        cleaned = cleaned[len(candidate_clean):].lstrip(" .:-)–—")
                        break
            return cleaned.strip()

        for anchor in list(soup.find_all('a')):
            if anchor is None or not hasattr(anchor, "get"):
                continue
            href = safe_get(anchor, 'href', '') or safe_get(anchor, 'xlink:href', '')
            fragment = normalise_fragment(href)
            if not fragment:
                continue

            # Try to find note in current document
            note_node = soup.find(id=fragment)

            # If not found and href points to external file, try to load it
            if not note_node and external_file_resolver and '#' in href:
                external_file = href.split('#')[0]
                if external_file and external_file not in external_footnote_cache:
                    try:
                        external_html = external_file_resolver(external_file)
                        if external_html:
                            external_footnote_cache[external_file] = BeautifulSoup(external_html, "html.parser")
                    except Exception:
                        external_footnote_cache[external_file] = None

                external_soup = external_footnote_cache.get(external_file)
                if external_soup:
                    note_node = external_soup.find(id=fragment)

            note_text = extract_note_text(note_node)
            if not note_text:
                continue
            if not looks_like_noteref(anchor, note_text):
                continue

            label = anchor.get_text(" ", strip=True)
            number_hint = "".join(ch for ch in label if ch.isdigit())
            if fragment in note_numbers:
                note_number = note_numbers[fragment]
            else:
                if number_hint.isdigit():
                    note_number = number_hint
                else:
                    note_number = str(len(note_numbers) + 1)
                note_numbers[fragment] = note_number
            cleaned_text = strip_leading_label(note_text, label)
            if not cleaned_text:
                cleaned_text = note_text.strip()

            marker_token = f"[[FOOTNOTE_{len(footnotes) + 1}]]"
            footnotes.append({
                "marker": marker_token,
                "number": note_number,
                "text": cleaned_text,
                "original_text": TextProcessor.normalise_whitespace(note_text),
            })

            anchor.replace_with(marker_token)
            parent = anchor.parent
            if parent and parent.name == 'sup' and not parent.get_text(strip=True):
                parent.decompose()

            processed_targets.append(fragment)

        for fragment in set(processed_targets):
            node = soup.find(id=fragment)
            if node is not None:
                node.decompose()

        return str(soup), footnotes

    @staticmethod
    def _collect_footnotes_fallback(markup: str) -> Tuple[str, List[Dict[str, str]]]:
        anchor_pattern = re.compile(
            r'(<sup[^>]*>\s*)?<a[^>]+href=["\"][^"#\']*#(?P<fragment>[^"\']+)["\"][^>]*>(?P<label>.*?)</a>(\s*</sup>)?',
            re.IGNORECASE | re.DOTALL,
        )

        referenced_fragments: set[str] = set()
        referenced_fragments_lower: set[str] = set()
        for match in anchor_pattern.finditer(markup):
            fragment = match.group('fragment')
            if not fragment:
                continue
            referenced_fragments.add(fragment)
            referenced_fragments_lower.add(fragment.lower())

        footnote_pattern = re.compile(
            r'<(?P<tag>div|p|section|aside|li)[^>]*id="(?P<id>[^"]+)"[^>]*>(?P<body>.*?)</(?P=tag)>',
            re.IGNORECASE | re.DOTALL,
        )
        footnote_map: Dict[str, str] = {}

        def looks_like_footnote_id(foot_id: str) -> bool:
            if not foot_id:
                return False
            lowered = foot_id.lower()
            if lowered in referenced_fragments_lower or foot_id in referenced_fragments:
                return True
            if re.search(r'(foot|note|rodape|rodapé)', lowered):
                return True
            if re.match(r'(?:fn|n|nota|rodape|rodapé)[\w\-]*\d*$', lowered):
                return True
            return False

        def capture(match: re.Match) -> str:
            foot_id = match.group('id')
            if not looks_like_footnote_id(foot_id):
                return match.group(0)
            body = match.group('body')
            plain = TextProcessor.html_to_plain_text(body)
            cleaned = TextProcessor.normalise_whitespace(plain)
            footnote_map[foot_id] = cleaned
            lower_id = foot_id.lower()
            if lower_id not in footnote_map:
                footnote_map[lower_id] = cleaned
            return ''

        markup_without_footnotes = footnote_pattern.sub(capture, markup)

        footnotes: List[Dict[str, str]] = []
        note_numbers: Dict[str, str] = {}
        counter = 0

        def replace(match: re.Match) -> str:
            nonlocal counter
            fragment = match.group('fragment')
            fragment_key = fragment.lower()
            if fragment not in footnote_map and fragment_key not in footnote_map:
                return match.group(0)
            lookup_key = fragment if fragment in footnote_map else fragment_key
            label = TextProcessor.html_to_plain_text(match.group('label'))
            digits = ''.join(ch for ch in label if ch.isdigit())
            if fragment_key in note_numbers:
                number = note_numbers[fragment_key]
            else:
                number = digits if digits else str(len(note_numbers) + 1)
                note_numbers[fragment_key] = number
            counter += 1
            marker_token = f"[[FOOTNOTE_{counter}]]"
            footnote_text = footnote_map.get(lookup_key, '').strip()
            if digits and footnote_text.startswith(digits):
                footnote_text = footnote_text[len(digits):].lstrip(' .:-)–—')
            if not footnote_text:
                footnote_text = footnote_map.get(lookup_key, '').strip()
            footnotes.append({
                "marker": marker_token,
                "number": number,
                "text": TextProcessor.normalise_whitespace(footnote_text),
                "original_text": TextProcessor.normalise_whitespace(footnote_map.get(lookup_key, '')),
            })
            return marker_token

        markup_with_markers = anchor_pattern.sub(replace, markup_without_footnotes)
        return markup_with_markers, footnotes

    @staticmethod
    def _render_footnotes(
        base_text: str,
        footnotes: List[Dict[str, str]],
        *,
        mode: str,
        context_words: int,
        phrases: Optional[Dict[str, str]] = None,
    ) -> str:
        if not footnotes:
            return base_text

        mode = (mode or "inline").lower()
        context_words = max(int(context_words or 0), 0)

        phrases = phrases or {}
        prefix = phrases.get("prefix", "\n")
        template = phrases.get("template", "nota de rodapé {number}: {text}")
        suffix_text = phrases.get("suffix_text", " fim da nota de rodapé")
        closing = phrases.get("closing", "")
        chapter_end_template = phrases.get("chapter_end_template", "nota de rodapé {number}: {snippet} - {text} fim da nota de rodapé")

        text = base_text

        if mode == "inline":
            for footnote in footnotes:
                marker = footnote["marker"]
                intro = template.format(number=footnote["number"], text=footnote["text"])
                suffix_part = suffix_text.format(number=footnote["number"], text=footnote["text"])
                replacement = f"{prefix}{intro}{suffix_part}{closing}"
                text = text.replace(marker, replacement, 1)
            return text

        appended_entries: List[Tuple[str, str, str]] = []
        for footnote in footnotes:
            marker = footnote["marker"]
            while marker in text:
                idx = text.find(marker)
                if idx == -1:
                    break
                preceding = text[:idx]
                snippet = TextProcessor._extract_context_snippet(preceding, context_words)
                text = text[:idx] + text[idx + len(marker):]
                if mode == "chapter_end":
                    appended_entries.append(
                        (footnote["number"], snippet, footnote["text"])
                    )
                break

            if mode == "chapter_end" and appended_entries:
                lines = []
                for number, snippet, note_text in appended_entries:
                    snippet_part = (snippet or "contexto não identificado").strip()
                    line = chapter_end_template.format(
                        number=number,
                        text=note_text,
                        snippet=snippet_part,
                    )
                    lines.append(line)
                text = text.rstrip() + "\n\n" + "\n".join(lines)

        return text

    @staticmethod
    def _apply_footnotes_to_segments(
        segments: Optional[List[FormattingSegment]],
        footnotes: List[Dict[str, str]],
        *,
        mode: str,
        context_words: int,
        phrases: Optional[Dict[str, str]] = None,
    ) -> Optional[List[FormattingSegment]]:
        if not segments or not footnotes:
            return segments

        mode = (mode or "inline").lower()
        if mode != "inline":
            return segments

        phrases = phrases or {}
        prefix = phrases.get("prefix", "\n")
        template = phrases.get("template", "nota de rodapé {number}: {text}")
        suffix_text = phrases.get("suffix_text", " fim da nota de rodapé")
        closing = phrases.get("closing", "")

        replacements: Dict[str, str] = {}
        for footnote in footnotes:
            intro = template.format(number=footnote["number"], text=footnote["text"])
            suffix_part = suffix_text.format(number=footnote["number"], text=footnote["text"])
            replacements[footnote["marker"]] = f"{prefix}{intro}{suffix_part}{closing}"

        for segment in segments:
            if not getattr(segment, "text", None):
                continue
            updated = segment.text
            for marker, replacement in replacements.items():
                if marker in updated:
                    updated = updated.replace(marker, replacement)
            segment.text = updated

        return segments

    @staticmethod
    def _extract_context_snippet(preceding_text: str, words: int) -> str:
        if words <= 0 or not preceding_text:
            return ""
        window = preceding_text[-200:]
        tokens = window.strip().split()
        if not tokens:
            return ""
        snippet_tokens = tokens[-words:]
        snippet = " ".join(snippet_tokens)
        return snippet.strip(" -–—,:;·\"'“”‘’")

    @staticmethod
    def html_to_text(content: str) -> str:
        if not content:
            return ""
        text = str(content)
        text = STYLE_RE.sub("", text)
        text = SCRIPT_RE.sub("", text)
        text = NBSP_RE.sub(" ", text)
        text = ARTIFACT_RE.sub(" ", text)
        text = PARA_BLOCK_RE.sub("\n", text)
        text = TAG_RE.sub("", text)
        text = PAGE_BREAK_RE.sub("\n", text)
        text = WHITESPACE_RE.sub(" ", text)
        text = re.sub(r"\n{2,}", "\n", text)
        return text.strip()

    @staticmethod
    def add_pause_before_dash(text: str) -> str:
        if not text:
            return ""

        def insert_break(match: re.Match) -> str:
            preceding = match.group(1)
            dash = match.group(2)
            trailing = match.group(3)
            return f"{preceding}\n{dash}{trailing}"

        pattern = re.compile(r"([^\s\n])\s*(—)(\s*)")
        updated = pattern.sub(insert_break, text)
        return updated

    @staticmethod
    def extract_title(markup: str, fallback: str) -> str:
        match = H_TAG.search(markup)
        if match:
            heading = TAG_RE.sub("", match.group(2)).strip()
            if heading:
                return heading
        # Fallback to the first meaningful words of the content
        text = TextProcessor.html_to_text(markup)
        if not text:
            return fallback
        words = text.split()
        max_words = 6
        truncated = len(words) > max_words
        if truncated:
            text = " ".join(words[:max_words])
            return text.rstrip(".,;:!?") or fallback
        return text.strip()

    @staticmethod
    def normalise_whitespace(text: str) -> str:
        return WHITESPACE_RE.sub(" ", text.strip())

    @staticmethod
    def looks_like_css(content: str) -> bool:
        if not content:
            return False
        lowered = content.lower()
        css_signals = ["@page", "@media", "{", "font-family", "margin:", "padding:"]
        signal_count = sum(1 for token in css_signals if token in lowered)
        if signal_count < 2:
            return False
        if '<html' in lowered or '<body' in lowered or '<div' in lowered:
            return False
        return True

    @staticmethod
    def extract_first_heading(content: Optional[str]) -> Optional[str]:
        if not content:
            return None
        match = H_TAG.search(content)
        if not match:
            return None
        heading = TAG_RE.sub("", match.group(2))
        return TextProcessor.normalise_whitespace(heading)

    @staticmethod
    def extract_title_from_text(text: Optional[str], max_words: int = 6) -> str:
        if not text:
            return ""
        cleaned = str(text).replace("\r", " ").replace("\n", " ").replace("\f", " ")
        cleaned = cleaned.replace("\t", " ")
        cleaned = TextProcessor.normalise_whitespace(cleaned)
        if not cleaned:
            return ""
        words = cleaned.split()
        if len(words) <= max_words:
            return " ".join(words)
        return " ".join(words[:max_words])


class EpubParser:
    """Parse a single EPUB file into a :class:`Book` instance."""

    def __init__(self, file_path: str | Path) -> None:
        self.file_path = str(file_path)
        self.path = Path(file_path)

    @staticmethod
    def _prepare_speech_text(text: str, formatting_segments: Optional[List[FormattingSegment]]) -> str:
        """
        Prepara o texto para envio ao TTS com pistas audíveis de formatação.

        Este método:
        1. PRESERVA tags [[lang:xx]] para TTS multiidioma
        2. Converte marcadores [[fmt:...]] em mensagens que o ouvinte entende (“em itálico”, “entre aspas” etc.)
        3. Remove apenas markdown auxiliar (_italic_, **bold**) que não contribui para o áudio

        Resultado: o texto retornado é exatamente o payload enviado ao TTS e salvo em -pre-tts.txt
        """
        if not text:
            return ""

        # Apenas remover markdown inline que foi adicionado pelo processador
        # IMPORTANTE: NÃO remover tags [[lang:]] nem [[fmt:]]
        if TextFormattingProcessor:
            formatter = TextFormattingProcessor()
            try:
                processed = formatter.to_audible_text(text, formatting_segments)
                if processed:
                    return processed
            except Exception:
                # Fallback para remoção básica caso algo falhe
                pass
            return TextFormattingProcessor.strip_inline_markdown(text)

        return text

    def parse(self) -> Book:
        with zipfile.ZipFile(self.path, "r") as archive:
            opf_path = self._find_opf_path(archive)
            manifest, spine_ids, title, author = self._parse_opf(archive, opf_path)
            base_dir = self._opf_dir(opf_path)
            chapters = self._extract_chapters(archive, manifest, spine_ids, base_dir)
            toc = self._parse_toc(archive, base_dir)

        title = title or self.path.stem
        author = author or ""
        return Book(title=title.strip(), author=author.strip(), chapters=chapters, toc=toc)

    def _find_opf_path(self, archive: zipfile.ZipFile) -> str:
        try:
            container_xml = archive.read("META-INF/container.xml").decode("utf-8")
        except KeyError as exc:
            raise RuntimeError("Invalid EPUB: missing container.xml") from exc

        container = ET.fromstring(container_xml)
        rootfile = container.find(".//ocf:rootfile", XML_NS)
        if rootfile is None or "full-path" not in rootfile.attrib:
            raise RuntimeError("Invalid EPUB: container has no rootfile")
        return rootfile.attrib["full-path"]

    def _parse_opf(
        self,
        archive: zipfile.ZipFile,
        opf_path: str,
    ) -> Tuple[Dict[str, str], List[str], str, str]:
        opf_content = self._read_zip_text(archive, opf_path)
        opf_tree = ET.fromstring(opf_content)

        manifest: Dict[str, str] = {}
        for item in opf_tree.findall("opf:manifest/opf:item", XML_NS):
            item_id = item.attrib.get("id")
            href = item.attrib.get("href")
            if item_id and href:
                manifest[item_id] = href

        spine: List[str] = []
        for itemref in opf_tree.findall("opf:spine/opf:itemref", XML_NS):
            idref = itemref.attrib.get("idref")
            if idref and idref in manifest:
                spine.append(idref)

        title = ""
        author = ""
        metadata = opf_tree.find("opf:metadata", XML_NS)
        if metadata is not None:
            title_elem = metadata.find("dc:title", XML_NS)
            author_elem = metadata.find("dc:creator", XML_NS)
            if title_elem is not None and title_elem.text:
                title = title_elem.text.strip()
            if author_elem is not None and author_elem.text:
                author = author_elem.text.strip()

        return manifest, spine, title, author

    def _extract_chapters(
        self,
        archive: zipfile.ZipFile,
        manifest: Dict[str, str],
        spine_ids: Iterable[str],
        base_dir: str,
    ) -> List[Chapter]:
        chapters: List[Chapter] = []
        index_counter = 1
        context_words = 8

        for item_id in spine_ids:
            href = manifest.get(item_id)
            if not href or not self._is_html_like(href):
                continue

            asset_path = self._join_path(base_dir, href)
            try:
                raw_content = self._read_zip_text(archive, asset_path)
            except KeyError:
                continue

            if TextProcessor.looks_like_css(raw_content):
                continue

            # Create resolver for external footnote files (relative to current chapter)
            chapter_dir = str(Path(asset_path).parent).replace("\\", "/") if "/" in asset_path else ""
            def resolve_external_file(relative_path: str) -> Optional[str]:
                try:
                    # Resolve relative to current chapter's directory
                    full_path = self._join_path(chapter_dir, relative_path)
                    return self._read_zip_text(archive, full_path)
                except (KeyError, Exception):
                    return None

            # Process text with formatting awareness
            markup_with_markers, footnotes = TextProcessor.inject_footnotes(
                raw_content,
                external_file_resolver=resolve_external_file
            )
            text_with_formatting, formatting_segments = TextProcessor.html_to_plain_text_with_formatting(markup_with_markers)
            if footnotes:
                text_with_footnotes = TextProcessor._render_footnotes(
                    text_with_formatting,
                    footnotes,
                    mode="inline",
                    context_words=context_words,
                )
                formatting_segments = TextProcessor._apply_footnotes_to_segments(
                    formatting_segments,
                    footnotes,
                    mode="inline",
                    context_words=context_words,
                )
            else:
                text_with_footnotes = text_with_formatting
            text = TextProcessor.add_pause_before_dash(text_with_footnotes)
            title = TextProcessor.extract_title(raw_content, f"Capítulo {index_counter}") if text else f"Capítulo {index_counter}"

            # Adicionar todos os capítulos, mesmo que estejam vazios
            # IMPORTANTE: speech_text deve ser o que será enviado ao TTS
            # - Remove apenas markdown inline (_italic_, **bold**, `code`)
            # - PRESERVA tags [[lang:xx]] para TTS multiidioma
            # - PRESERVA marcadores de formatação [[fmt:...]] para ênfase
            speech_text = self._prepare_speech_text(text_with_footnotes, formatting_segments)
            chapters.append(
                Chapter(
                    index=index_counter,
                    name=title,
                    source_path=asset_path,
                    text=text or "",  # Garantir que o texto não seja None
                    raw_html=raw_content,
                    formatting_segments=formatting_segments,
                    footnotes=list(footnotes) if footnotes else None,
                    speech_text=speech_text or "",
                )
            )
            index_counter += 1

        return chapters

    def _parse_toc(self, archive: zipfile.ZipFile, base_dir: str) -> List[TocItem]:
        candidates = [name for name in archive.namelist() if name.lower().endswith('.ncx')]
        if not candidates:
            return []

        try:
            raw = self._read_zip_text(archive, candidates[0])
        except KeyError:
            return []

        try:
            tree = ET.fromstring(raw)
        except ET.ParseError:
            return []

        nav_map = tree.find('ncx:navMap', XML_NS)

        if nav_map is None:
            return []

        def build(entries, level=1):
            items = []
            for nav_point in entries:
                label_elem = nav_point.find('ncx:navLabel/ncx:text', XML_NS)
                content_elem = nav_point.find('ncx:content', XML_NS)
                title = label_elem.text.strip() if label_elem is not None and label_elem.text else ''
                href = content_elem.attrib.get('src', '') if content_elem is not None else ''
                children_points = nav_point.findall('ncx:navPoint', XML_NS)
                items.append(TocItem(
                    title=title,
                    href=href,
                    level=level,
                    children=build(children_points, level + 1)
                ))
            return items

        top_level_points = nav_map.findall('ncx:navPoint', XML_NS)
        return build(top_level_points, level=1)

    @staticmethod
    def _opf_dir(opf_path: str) -> str:
        return str(Path(opf_path).parent).replace("\\", "/") if "/" in opf_path else ""

    @staticmethod
    def _join_path(base_dir: str, href: str) -> str:
        if href.startswith("/"):
            path = href.lstrip("/")
        else:
            href = href.lstrip("/")
            if not base_dir:
                path = href
            else:
                path = f"{base_dir.rstrip('/')}/{href}"
        return unquote(path)

    @staticmethod
    def _is_html_like(href: str) -> bool:
        return href.lower().endswith((".xhtml", ".html", ".htm", ".xml"))

    @staticmethod
    def _read_zip_text(archive: zipfile.ZipFile, member: str) -> str:
        try:
            data = archive.read(member)
        except KeyError:
            data = archive.read(unquote(member))
        try:
            return data.decode("utf-8")
        except UnicodeDecodeError:
            return data.decode("latin-1", errors="ignore")


class PdfParser:
    """Very small PDF parser that extracts each page as a chapter."""

    def __init__(self, file_path: str | Path) -> None:
        self.file_path = str(file_path)
        self.path = Path(file_path)

    def parse(self) -> Book:
        if not PDF_AVAILABLE:
            raise ImportError("pypdf library not installed")

        with open(self.file_path, "rb") as handle:  # pragma: no cover - exercised in tests
            reader = pypdf.PdfReader(handle)  # type: ignore[arg-type]

            metadata = reader.metadata or {}
            title = metadata.get("/Title") or metadata.get("Title") or self.path.stem
            author = metadata.get("/Author") or metadata.get("Author") or ""

            chapters: List[Chapter] = []
            for idx, page in enumerate(reader.pages, start=1):
                try:
                    raw_text = page.extract_text() or ""
                except Exception:
                    chapters.append(
                        Chapter(index=idx, name=f"Página {idx} (erro)", source_path=f"page_{idx}", text="")
                    )
                    continue

                cleaned = TextProcessor.normalise_whitespace(raw_text)
                if not cleaned:
                    continue
                cleaned = TextProcessor.add_pause_before_dash(cleaned)
                chapters.append(
                    Chapter(index=idx, name=f"Página {idx}", source_path=f"page_{idx}", text=cleaned)
                )

        return Book(title=str(title), author=str(author), chapters=chapters)


class EbookReader:
    """Facade used by the rest of the code base."""

    def __init__(self, file_path: Optional[str | Path] = None) -> None:
        self.file_path: Optional[Path] = None
        self.book: Optional[Book] = None
        if file_path is not None:
            self.file_path = Path(file_path)
            self.load(file_path)

    def load(self, file_path: str | Path) -> None:
        path = Path(file_path)
        if not path.exists():
            raise FileNotFoundError(f"File not found: {path}")

        suffix = path.suffix.lower()
        if suffix not in {".epub", ".pdf"}:
            raise ValueError(f"Unsupported format: {suffix}")

        self.file_path = path
        if suffix == ".epub":
            self.book = EpubParser(str(path)).parse()
        else:
            self.book = PdfParser(str(path)).parse()

    @property
    def title(self) -> str:
        return self.book.title if self.book else ""

    @property
    def author(self) -> str:
        return self.book.author if self.book else ""

    def get_chapters(self) -> List[Chapter]:
        return list(self.book.chapters) if self.book else []

    def _ensure_loaded(self) -> Optional[Book]:
        if not self.book:
            if not self.file_path:
                raise RuntimeError("Reader has no file loaded")
            self.load(self.file_path)
        return self.book

    def get_chapter_structure(self, preserve_all: bool = True) -> List[Chapter]:
        chapters = self.get_chapters()
        if preserve_all:
            return chapters
        return [chapter for chapter in chapters if len(chapter.text.strip()) >= 100]

    def read_ebook(self, file_path: str | Path) -> Tuple[str, str, List[Tuple[str, str]]]:
        self.load(file_path)
        if not self.book:
            return "", "", []
        chapters = [(chapter.name, chapter.text) for chapter in self.book.chapters]
        return self.book.title, self.book.author, chapters

    def get_toc(self) -> List[TocItem]:
        book = self._ensure_loaded()
        if not book:
            return []
        return list(book.toc)


def read_book(file_path: str | Path) -> Book:
    reader = EbookReader(file_path)
    if not reader.book:
        raise RuntimeError("Failed to read book")
    return reader.book


__all__ = ["EbookReader", "read_book", "Book", "Chapter"]
