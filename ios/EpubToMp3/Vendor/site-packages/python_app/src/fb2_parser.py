"""FictionBook 2.0 (.fb2) parser.

FB2 is a single XML file (no zip container, no manifest/spine) — the closest
analogue to EPUB's spine is the nested `<section>` tree under `<body>`. This
parser reuses `EpubParser._html_fragment_to_chapters` (the shared HTML→Chapter
pipeline: footnote inlining, structural speech cues, paragraph-boundary size
guard) for every section instead of reimplementing any of that: each
`<section>` is serialized to a small HTML fragment (excluding nested
`<section>` children, which get their own recursive `Chapter`) and fed
through the same pipeline EPUB chapters go through.
"""

from __future__ import annotations

import html
from pathlib import Path
from typing import List, Optional

from lxml import etree

from .ebook_reader import Book, Chapter, EpubParser, TocItem

_FB2_NS = {"fb": "http://www.gribuser.ru/xml/fictionbook/2.0"}

_INLINE_TAG_MAP = {
    "emphasis": "i",
    "strong": "b",
    "strikethrough": "s",
    "sub": "sub",
    "sup": "sup",
    "code": "code",
}


class Fb2ParseError(Exception):
    """Raised when a file cannot be parsed as valid FictionBook 2.0 XML."""


class Fb2Parser:
    """Parses FictionBook 2.0 XML into the shared `Book`/`Chapter` model."""

    def __init__(self, file_path: str | Path) -> None:
        self.file_path = Path(file_path)

    def parse(self) -> Book:
        try:
            root = etree.fromstring(self.file_path.read_bytes())
        except etree.XMLSyntaxError as exc:
            raise Fb2ParseError(f"Invalid FB2/XML: {exc}") from exc

        title_info = root.find(".//fb:description/fb:title-info", _FB2_NS)
        title = (
            _text_of(title_info.find("fb:book-title", _FB2_NS)) if title_info is not None else None
        ) or self.file_path.stem
        author = _author_of(title_info) if title_info is not None else ""
        lang_el = title_info.find("fb:lang", _FB2_NS) if title_info is not None else None
        language = _text_of(lang_el) or None
        cue_locale = (language or "en").split("-")[0].lower()

        chapters: List[Chapter] = []
        toc: List[TocItem] = []
        # The main body has no `name` attribute; a second `<body name="notes">`
        # (or similar) holds footnote bodies referenced via `<a>` — only the
        # unnamed body is real chapter content.
        main_body = None
        for body in root.findall("fb:body", _FB2_NS):
            if body.get("name") is None:
                main_body = body
                break

        if main_body is not None:
            _walk_sections(main_body, chapters, toc, prefix="", cue_locale=cue_locale)

        return Book(title=title, author=author, chapters=chapters, toc=toc, language=language)


def _walk_sections(
    parent: etree._Element,
    chapters: List[Chapter],
    toc_children: List[TocItem],
    prefix: str,
    cue_locale: str,
) -> None:
    sections = [c for c in parent if etree.QName(c).localname == "section"]
    for position, section in enumerate(sections, 1):
        idx = f"{prefix}{position}" if not prefix else f"{prefix}.{position}"
        title_el = _direct_child(section, "title")
        title_text = _text_only(title_el).strip() if title_el is not None else f"Chapter {idx}"

        section_html = _section_to_html(section)
        new_chapters = EpubParser._html_fragment_to_chapters(
            markup_with_markers=section_html,
            raw_content=section_html,
            chapter_idx=idx,
            asset_path=f"section-{idx}",
            toc_chapter_title=title_text,
            footnotes=None,
            cue_locale=cue_locale,
        )
        chapters.extend(new_chapters)

        toc_node = TocItem(title=title_text, href=f"section-{idx}", level=idx.count(".") + 1)
        toc_children.append(toc_node)
        _walk_sections(section, chapters, toc_node.children, idx, cue_locale)


def _section_to_html(section: etree._Element) -> str:
    """Serialize a section's direct content (title/p/subtitle/empty-line/
    poem/cite) to minimal HTML, excluding nested `<section>` children —
    those are handled as their own chapters by the recursive walk."""
    parts: List[str] = []
    for child in section:
        tag = etree.QName(child).localname
        if tag == "section":
            continue
        parts.append(_fb2_element_to_html(child))
    return "".join(parts)


def _fb2_element_to_html(el: etree._Element) -> str:
    tag = etree.QName(el).localname
    if tag == "title":
        return f"<h1>{html.escape(_text_only(el).strip())}</h1>" if _text_only(el).strip() else ""
    if tag == "subtitle":
        return f"<h2>{html.escape(_text_only(el).strip())}</h2>"
    if tag == "p":
        return f"<p>{_inline_to_html(el)}</p>"
    if tag == "empty-line":
        return "<br/>"
    if tag in ("poem", "cite", "epigraph", "annotation"):
        return "".join(_fb2_element_to_html(c) for c in el if etree.QName(c).localname != "section")
    if tag == "image":
        return ""
    # Unknown container — recurse into children as a best-effort fallback.
    return "".join(_fb2_element_to_html(c) for c in el if etree.QName(c).localname != "section")


def _inline_to_html(el: etree._Element) -> str:
    """Render a `<p>`'s inline content (text + emphasis/strong/etc + tails)."""
    parts: List[str] = [html.escape(el.text or "")]
    for child in el:
        tag = etree.QName(child).localname
        html_tag = _INLINE_TAG_MAP.get(tag)
        inner = _inline_to_html(child)
        if html_tag:
            parts.append(f"<{html_tag}>{inner}</{html_tag}>")
        else:
            parts.append(inner)
        parts.append(html.escape(child.tail or ""))
    return "".join(parts)


def _direct_child(el: etree._Element, local_name: str) -> Optional[etree._Element]:
    for child in el:
        if etree.QName(child).localname == local_name:
            return child
    return None


def _text_only(el: Optional[etree._Element]) -> str:
    if el is None:
        return ""
    return "".join(el.itertext())


def _text_of(el: Optional[etree._Element]) -> str:
    if el is None:
        return ""
    return (el.text or "").strip()


def _author_of(title_info: etree._Element) -> str:
    author_el = title_info.find("fb:author", _FB2_NS)
    if author_el is None:
        return ""
    first = _text_of(author_el.find("fb:first-name", _FB2_NS))
    last = _text_of(author_el.find("fb:last-name", _FB2_NS))
    nick = _text_of(author_el.find("fb:nickname", _FB2_NS))
    full = " ".join(part for part in (first, last) if part)
    return full or nick


__all__ = ["Fb2Parser", "Fb2ParseError"]
