# -*- coding: utf-8 -*-
"""NCX and navigation hierarchy parsing and assignment."""

from __future__ import annotations

import zipfile
from typing import Dict, List, Optional
from xml.etree import ElementTree as ET

from .ebook_models import Chapter, TocItem


class EpubNavigation:
    """NCX and navigation hierarchy parsing and assignment."""

    def _parse_toc(
        self,
        archive: zipfile.ZipFile,
        base_dir: str,
        *,
        opf_path: Optional[str] = None,
    ) -> List[TocItem]:
        """Parse the table of contents, trying NCX (EPUB2) then nav.xhtml (EPUB3)."""
        from . import ebook_reader as _runtime
        cached = _runtime._toc_cache_get(self.file_path, opf_path)
        if cached is not None:
            return cached
        # --- EPUB2: NCX ---
        candidates = [name for name in archive.namelist() if name.lower().endswith(".ncx")]
        if candidates:
            try:
                raw = self._read_zip_text(archive, candidates[0])
                tree = _runtime.ET.fromstring(raw)
                nav_map = tree.find("ncx:navMap", _runtime.XML_NS)
                if nav_map is not None:

                    def build(entries, level=1):
                        items = []
                        for nav_point in entries:
                            label_elem = nav_point.find("ncx:navLabel/ncx:text", _runtime.XML_NS)
                            content_elem = nav_point.find("ncx:content", _runtime.XML_NS)
                            title = (
                                label_elem.text.strip()
                                if label_elem is not None and label_elem.text
                                else ""
                            )
                            href = (
                                content_elem.attrib.get("src", "")
                                if content_elem is not None
                                else ""
                            )
                            children_points = nav_point.findall("ncx:navPoint", _runtime.XML_NS)
                            items.append(
                                _runtime.TocItem(
                                    title=title,
                                    href=href,
                                    level=level,
                                    children=build(children_points, level + 1),
                                )
                            )
                        return items

                    top_level_points = nav_map.findall("ncx:navPoint", _runtime.XML_NS)
                    built = build(top_level_points, level=1)
                    _runtime._toc_cache_put(self.file_path, opf_path, built)
                    return built
            except (_runtime.ET.ParseError, KeyError):
                pass

        # --- EPUB3: nav.xhtml (fallback) ---
        if opf_path:
            nav_items = self._parse_nav_toc_from_opf(archive, opf_path, base_dir)
            if nav_items:
                _runtime._toc_cache_put(self.file_path, opf_path, nav_items)
                return nav_items

        _runtime._toc_cache_put(self.file_path, opf_path, [])
        return []

    @staticmethod
    def _parse_nav_toc_from_opf(
        archive: zipfile.ZipFile,
        opf_path: str,
        base_dir: str,
    ) -> List[TocItem]:
        """Locate and parse the EPUB3 nav document declared in the OPF manifest."""
        from . import ebook_reader as _runtime
        try:
            opf_content = _runtime.EpubParser._read_zip_text(archive, opf_path)
            opf_tree = _runtime.ET.fromstring(opf_content)
        except Exception:
            return []

        nav_href: Optional[str] = None
        for item in opf_tree.findall("opf:manifest/opf:item", _runtime.XML_NS):
            props = item.attrib.get("properties", "")
            if "nav" in props.lower().split():
                nav_href = item.attrib.get("href", "") or None
                break

        if not nav_href:
            return []

        nav_path = _runtime.EpubParser._join_path(base_dir, nav_href)
        try:
            nav_content = _runtime.EpubParser._read_zip_text(archive, nav_path)
        except (KeyError, Exception):
            return []

        return _runtime.EpubParser._parse_nav_html(nav_content)

    @staticmethod
    def _parse_nav_html(nav_content: str) -> List[TocItem]:
        """Parse an EPUB3 nav.xhtml document and return a TocItem hierarchy."""
        from . import ebook_reader as _runtime
        EPUB_NS_URI = "http://www.idpf.org/2007/ops"

        # Strip DOCTYPE which ElementTree cannot handle
        cleaned = _runtime.re.sub(r"<!DOCTYPE[^>]*>", "", nav_content, count=1)
        try:
            root = _runtime.ET.fromstring(cleaned)
        except _runtime.ET.ParseError:
            return []

        def _tag_local(elem) -> str:
            tag = elem.tag
            return tag.split("}", 1)[-1] if "}" in tag else tag

        def _find_toc_nav(node) -> Optional[ET.Element]:
            """Find <nav epub:type="toc"> anywhere in the tree."""
            if _tag_local(node) == "nav":
                epub_type = (
                    node.attrib.get(f"{{{EPUB_NS_URI}}}type") or node.attrib.get("epub:type") or ""
                )
                if "toc" in epub_type.lower():
                    return node
            for child in node:
                found = _find_toc_nav(child)
                if found is not None:
                    return found
            return None

        toc_nav = _find_toc_nav(root)
        if toc_nav is None:
            return []

        def parse_ol(ol_elem, level: int) -> List[TocItem]:
            items: List[_runtime.TocItem] = []
            for child in ol_elem:
                if _tag_local(child) != "li":
                    continue
                href = ""
                title = ""
                children: List[_runtime.TocItem] = []
                for sub in child:
                    local = _tag_local(sub)
                    if local == "a":
                        href = sub.attrib.get("href", "")
                        title = "".join(sub.itertext()).strip()
                    elif local == "span":
                        # Some nav docs use <span> instead of <a> for headings
                        if not title:
                            title = "".join(sub.itertext()).strip()
                    elif local == "ol":
                        children = parse_ol(sub, level + 1)
                if href or title:
                    items.append(_runtime.TocItem(title=title, href=href, level=level, children=children))
            return items

        for child in toc_nav:
            if _tag_local(child) == "ol":
                return parse_ol(child, level=1)

        return []

    @staticmethod
    def _build_toc_level_map(toc: List[TocItem]) -> Dict[str, int]:
        """Return a map from file path (anchor stripped) to its minimum TOC level.

        When the same file appears at multiple levels (e.g. a split file referenced
        at L1 with one anchor and at L2 with another anchor), the *minimum* (highest
        in the hierarchy) level wins.
        """
        level_map: Dict[str, int] = {}

        def walk(items: List[TocItem]) -> None:
            for item in items:
                href = item.href
                if href:
                    file_path = href.split("#")[0] if "#" in href else href
                    if file_path:
                        prev = level_map.get(file_path)
                        level_map[file_path] = (
                            min(prev, item.level) if prev is not None else item.level
                        )
                walk(item.children)

        walk(toc)
        return level_map

    def _build_toc_title_map(self, toc: List[TocItem], base_dir: str) -> Dict[str, str]:
        title_map: Dict[str, str] = {}

        def walk(items: List[TocItem]) -> None:
            for item in items:
                href = item.href.split("#")[0] if item.href else ""
                if href and item.title:
                    asset_path = self._join_path(base_dir, href)
                    title_map.setdefault(asset_path, item.title.strip())
                    title_map.setdefault(href, item.title.strip())
                walk(item.children)

        walk(toc)
        return title_map

    def _assign_levels_from_toc(
        self,
        chapters: List[Chapter],
        toc: List[TocItem],
        base_dir: str,
    ) -> None:
        """Set chapter.level for every chapter based on its position in the TOC.

        Chapters whose source file is not found in the TOC keep their default
        level (1).  When a file is referenced at multiple TOC depths (e.g. an
        anchor-split file) the shallowest (lowest numeric) level is used.
        """
        if not toc:
            return
        level_map = self._build_toc_level_map(toc)
        if not level_map:
            return

        # Pre-compute normalised keys once to avoid repeated work.
        # TOC hrefs are relative to the OPF dir (base_dir); chapter source_paths
        # are stored as full archive paths (base_dir/relative).
        def _relative(source_path: str) -> str:
            """Strip base_dir prefix so the key matches TOC hrefs."""
            prefix = base_dir.rstrip("/") + "/"
            if source_path.startswith(prefix):
                return source_path[len(prefix) :]
            return source_path

        for chapter in chapters:
            src = chapter.source_path
            # Strip any trailing anchor from the source_path (rare, but safe)
            src_file = src.split("#")[0] if "#" in src else src
            rel = _relative(src_file)

            level = level_map.get(rel)
            if level is None:
                # Basename-only fallback (handles books where base_dir is unknown)
                basename = rel.split("/")[-1] if "/" in rel else rel
                level = level_map.get(basename)

            if level is not None:
                chapter.level = level

    @staticmethod
    def _opf_dir(opf_path: str) -> str:
        from . import ebook_reader as _runtime
        return str(_runtime.Path(opf_path).parent).replace("\\", "/") if "/" in opf_path else ""

    @staticmethod
    def _join_path(base_dir: str, href: str) -> str:
        from . import ebook_reader as _runtime
        if href.startswith("/"):
            path = href.lstrip("/")
        else:
            href = href.lstrip("/")
            if not base_dir:
                path = href
            else:
                path = f"{base_dir.rstrip('/')}/{href}"
        return _runtime.posixpath.normpath(_runtime.unquote(path))

    @staticmethod
    def _is_html_like(href: str) -> bool:
        return href.lower().endswith((".xhtml", ".html", ".htm", ".xml"))

    @staticmethod
    def _read_zip_text(archive: zipfile.ZipFile, member: str) -> str:
        from . import ebook_reader as _runtime
        try:
            data = archive.read(member)
        except KeyError:
            data = archive.read(_runtime.unquote(member))
        try:
            return data.decode("utf-8")
        except UnicodeDecodeError:
            return data.decode("latin-1", errors="ignore")
