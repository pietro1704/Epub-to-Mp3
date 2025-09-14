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

            text = TextProcessor.html_to_text(raw_content)
            title = TextProcessor.extract_title(raw_content, f"Capítulo {index_counter}") if text else f"Capítulo {index_counter}"

            chapters.append(
                Chapter(
                    index=index_counter,
                    name=title,
                    source_path=asset_path,
                    text=text,
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

    def _ensure_loaded(self) -> Book:
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
        return list(self._ensure_loaded().toc)


def read_book(file_path: str | Path) -> Book:
    reader = EbookReader(file_path)
    if not reader.book:
        raise RuntimeError("Failed to read book")
    return reader.book


__all__ = ["EbookReader", "read_book", "Book", "Chapter"]
