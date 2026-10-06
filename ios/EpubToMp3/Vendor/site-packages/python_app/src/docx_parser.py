"""DOCX (Office Open XML word-processing document) parser.

DOCX is a zip of XML, same access pattern EPUB already uses — this parses
`word/document.xml` directly via `zipfile` + `lxml` instead of adding the
`python-docx` dependency (which still needs its own object model translated
to HTML before it could reuse the shared chapter pipeline, so it wouldn't
save code, only add a dependency). Paragraphs are grouped into chapters at
each `Heading1`-styled paragraph; the resulting HTML fragment per chapter is
fed through `EpubParser._html_fragment_to_chapters`, the same pipeline EPUB
and FB2 use.

Footnotes (`word/footnotes.xml`) are extracted and attached to
`Chapter.footnotes` for the reader's footnotes sheet, but — unlike EPUB,
where `TextProcessor.inject_footnotes` leaves markers in the markup for
`_render_footnotes` to find — they are intentionally NOT threaded through
inline speech injection here: that mechanism expects EPUB's specific
noteref/anchor convention, and guessing at it for OOXML risks silently
garbled narration. This is a deliberate, documented scope line: DOCX
footnotes are captured and viewable, not (yet) narrated inline.
"""

from __future__ import annotations

import html
import zipfile
from pathlib import Path
from typing import Dict, List, Optional

from lxml import etree

from .ebook_reader import Book, Chapter, EpubParser

_W_NS = {"w": "http://schemas.openxmlformats.org/wordprocessingml/2006/main"}
_CORE_NS = {
    "cp": "http://schemas.openxmlformats.org/package/2006/metadata/core-properties",
    "dc": "http://purl.org/dc/elements/1.1/",
}

_HEADING_STYLE_PREFIX = "Heading"


class DocxParseError(Exception):
    """Raised when a file cannot be parsed as a valid DOCX/OOXML document."""


class DocxParser:
    """Parses a DOCX document into the shared `Book`/`Chapter` model."""

    def __init__(self, file_path: str | Path) -> None:
        self.file_path = Path(file_path)

    def parse(self) -> Book:
        try:
            with zipfile.ZipFile(self.file_path, "r") as archive:
                names = set(archive.namelist())
                if "word/document.xml" not in names:
                    raise DocxParseError("Not a DOCX: missing word/document.xml")
                doc_xml = archive.read("word/document.xml")
                footnotes_xml = (
                    archive.read("word/footnotes.xml") if "word/footnotes.xml" in names else None
                )
                core_xml = (
                    archive.read("docProps/core.xml") if "docProps/core.xml" in names else None
                )
        except zipfile.BadZipFile as exc:
            raise DocxParseError(f"Invalid DOCX (not a zip archive): {exc}") from exc

        title, author = _read_core_properties(core_xml, self.file_path.stem)
        footnote_bodies = _parse_footnotes(footnotes_xml) if footnotes_xml else {}

        try:
            root = etree.fromstring(doc_xml)
        except etree.XMLSyntaxError as exc:
            raise DocxParseError(f"Invalid DOCX XML: {exc}") from exc
        body = root.find("w:body", _W_NS)
        if body is None:
            return Book(title=title, author=author, chapters=[])

        paragraphs = [p for p in body if etree.QName(p).localname == "p"]
        sections = _split_by_heading1(paragraphs)

        chapters: List[Chapter] = []
        for idx, (section_title, section_paragraphs) in enumerate(sections, 1):
            html_fragment = "".join(_paragraph_to_html(p) for p in section_paragraphs)
            referenced_ids = _referenced_footnote_ids(section_paragraphs)
            new_chapters = EpubParser._html_fragment_to_chapters(
                markup_with_markers=html_fragment,
                raw_content=html_fragment,
                chapter_idx=idx,
                asset_path=f"docx-section-{idx}",
                toc_chapter_title=section_title,
                footnotes=None,
                cue_locale="en",
            )
            if referenced_ids:
                section_footnotes = [
                    {"number": fid, "text": footnote_bodies[fid]}
                    for fid in referenced_ids
                    if fid in footnote_bodies
                ]
                for chapter in new_chapters:
                    if section_footnotes:
                        chapter.footnotes = section_footnotes
            chapters.extend(new_chapters)

        return Book(title=title, author=author, chapters=chapters)


def _split_by_heading1(
    paragraphs: List[etree._Element],
) -> List[tuple[Optional[str], List[etree._Element]]]:
    """Group paragraphs into (title, paragraphs) sections at each Heading1."""
    sections: List[tuple[Optional[str], List[etree._Element]]] = []
    current_title: Optional[str] = None
    current: List[etree._Element] = []
    for p in paragraphs:
        if _heading_level(p) == 1:
            if current:
                sections.append((current_title, current))
            current_title = _paragraph_text(p).strip() or None
            current = []
        else:
            current.append(p)
    if current or not sections:
        sections.append((current_title, current))
    return sections


def _heading_level(p: etree._Element) -> Optional[int]:
    ppr = p.find("w:pPr", _W_NS)
    if ppr is None:
        return None
    style = ppr.find("w:pStyle", _W_NS)
    if style is None:
        return None
    val = style.get(f"{{{_W_NS['w']}}}val", "")
    if val.startswith(_HEADING_STYLE_PREFIX):
        suffix = val[len(_HEADING_STYLE_PREFIX) :]
        if suffix.isdigit():
            return int(suffix)
    return None


def _paragraph_text(p: etree._Element) -> str:
    return "".join(t.text or "" for t in p.iter(f"{{{_W_NS['w']}}}t"))


def _paragraph_to_html(p: etree._Element) -> str:
    level = _heading_level(p)
    inner = _runs_to_html(p)
    if not inner.strip():
        return ""
    if level and level >= 2:
        tag = f"h{min(level, 6)}"
        return f"<{tag}>{inner}</{tag}>"
    return f"<p>{inner}</p>"


def _runs_to_html(p: etree._Element) -> str:
    parts: List[str] = []
    for run in p.findall("w:r", _W_NS):
        rpr = run.find("w:rPr", _W_NS)
        is_bold = rpr is not None and rpr.find("w:b", _W_NS) is not None
        is_italic = rpr is not None and rpr.find("w:i", _W_NS) is not None
        text = "".join(t.text or "" for t in run.findall("w:t", _W_NS))
        if not text:
            continue
        escaped = html.escape(text)
        if is_bold:
            escaped = f"<b>{escaped}</b>"
        if is_italic:
            escaped = f"<i>{escaped}</i>"
        parts.append(escaped)
    return "".join(parts)


def _referenced_footnote_ids(paragraphs: List[etree._Element]) -> List[str]:
    ids: List[str] = []
    for p in paragraphs:
        for ref in p.iter(f"{{{_W_NS['w']}}}footnoteReference"):
            fid = ref.get(f"{{{_W_NS['w']}}}id")
            if fid and fid not in ids:
                ids.append(fid)
    return ids


def _parse_footnotes(footnotes_xml: Optional[bytes]) -> Dict[str, str]:
    if not footnotes_xml:
        return {}
    try:
        root = etree.fromstring(footnotes_xml)
    except etree.XMLSyntaxError:
        return {}
    bodies: Dict[str, str] = {}
    for footnote in root.findall("w:footnote", _W_NS):
        fid = footnote.get(f"{{{_W_NS['w']}}}id")
        ftype = footnote.get(f"{{{_W_NS['w']}}}type")
        if not fid or ftype in ("separator", "continuationSeparator"):
            continue
        text = " ".join(_paragraph_text(p).strip() for p in footnote.findall("w:p", _W_NS)).strip()
        if text:
            bodies[fid] = text
    return bodies


def _read_core_properties(core_xml: Optional[bytes], fallback_title: str) -> tuple[str, str]:
    if not core_xml:
        return fallback_title, ""
    try:
        root = etree.fromstring(core_xml)
    except etree.XMLSyntaxError:
        return fallback_title, ""
    title_el = root.find("dc:title", _CORE_NS)
    creator_el = root.find("dc:creator", _CORE_NS)
    title = (title_el.text or "").strip() if title_el is not None else ""
    author = (creator_el.text or "").strip() if creator_el is not None else ""
    return title or fallback_title, author


__all__ = ["DocxParser", "DocxParseError"]
