# -*- coding: utf-8 -*-
"""EPUB resources, stylesheets and cover extraction."""

from __future__ import annotations

from typing import Dict, List, Optional
from xml.etree import ElementTree as ET

from .ebook_models import Chapter, CoverImage


class EbookResources:
    """EPUB resources, stylesheets and cover extraction."""

    def extract_cover_image(self) -> Optional[CoverImage]:
        """Return the raw cover image bundled in the source, if available."""
        from . import ebook_reader as _runtime
        if not self.file_path:
            return None

        suffix = self.file_path.suffix.lower()

        # EPUB cover extraction
        if suffix == ".epub":
            try:
                parser = _runtime.EpubParser(str(self.file_path))
                with _runtime.zipfile.ZipFile(self.file_path, "r") as archive:
                    opf_path = parser._find_opf_path(archive)
                    opf_dir = parser._opf_dir(opf_path)
                    opf_content = parser._read_zip_text(archive, opf_path)
                    opf_tree = _runtime.ET.fromstring(opf_content)

                    manifest: Dict[str, Dict[str, str]] = {}
                    for item in opf_tree.findall("opf:manifest/opf:item", _runtime.XML_NS):
                        item_id = item.attrib.get("id")
                        href = item.attrib.get("href")
                        if not item_id or not href:
                            continue
                        manifest[item_id] = {
                            "href": href,
                            "media_type": item.attrib.get("media-type", ""),
                            "properties": item.attrib.get("properties", ""),
                        }

                    cover_entry = self._detect_cover_entry(opf_tree, manifest)
                    if not cover_entry:
                        return None

                    cover_href = cover_entry.get("href")
                    if not cover_href:
                        return None

                    cover_path = parser._join_path(opf_dir, cover_href)
                    try:
                        data = archive.read(cover_path)
                    except KeyError:
                        data = archive.read(_runtime.unquote(cover_path))

                    media_type = cover_entry.get("media_type") or "image/jpeg"
                    if not media_type or media_type == "image/jpeg":
                        if _runtime.mimetypes is not None:
                            media_type = _runtime.mimetypes.guess_type(cover_href)[0] or "image/jpeg"
                    extension = _runtime.Path(cover_path).suffix
                    if not extension:
                        if _runtime.mimetypes is not None:
                            extension = _runtime.mimetypes.guess_extension(media_type) or ".jpg"
                        else:
                            extension = ".jpg"
                    if not extension.startswith("."):
                        extension = f".{extension}"
                    return _runtime.CoverImage(data=data, media_type=media_type, extension=extension)
            except Exception:
                return None

        # PDF cover extraction
        elif suffix == ".pdf":
            return self._extract_pdf_cover()

        # CBZ cover extraction: the first page image, in reading order.
        elif suffix in {".cbz", ".cbr"}:
            if not self.book or not self.book.chapters:
                return None
            first_page = self.book.chapters[0]
            try:
                if suffix == ".cbz":
                    with _runtime.zipfile.ZipFile(self.file_path, "r") as archive:
                        data = archive.read(first_page.source_path)
                    media_type = _runtime.mimetypes.guess_type(first_page.source_path)[0] or "image/jpeg"
                    extension = _runtime.Path(first_page.source_path).suffix or ".jpg"
                else:
                    from .cbr_parser import read_page

                    data, media_type, extension = read_page(self.file_path, first_page.source_path)
            except Exception:
                return None
            return _runtime.CoverImage(data=data, media_type=media_type, extension=extension)

        return None

    def extract_chapter_resources(self, chapter: Chapter) -> list[dict[str, str]]:
        """Return bounded image resources referenced by a chapter, or the
        single page image for CBZ/CBR chapters."""
        from . import ebook_reader as _runtime
        if not self.file_path:
            return []
        suffix = self.file_path.suffix.lower()

        if suffix in {".cbz", ".cbr"}:
            if not chapter.source_path:
                return []
            try:
                if suffix == ".cbz":
                    with _runtime.zipfile.ZipFile(self.file_path, "r") as archive:
                        data = archive.read(chapter.source_path)
                    media_type = _runtime.mimetypes.guess_type(chapter.source_path)[0] or "image/jpeg"
                else:
                    from .cbr_parser import read_page

                    data, media_type, _ = read_page(self.file_path, chapter.source_path)
            except Exception:
                return []
            return [
                {
                    "href": chapter.source_path,
                    "mediaType": media_type,
                    "dataBase64": _runtime.base64.b64encode(data).decode("ascii"),
                }
            ]

        if suffix != ".epub":
            return []
        raw_html = (chapter.raw_html or "").strip()
        source_path = (chapter.source_path or "").split("#", 1)[0].strip()
        if not raw_html or not source_path:
            return []
        try:
            parser = _runtime.EpubParser(str(self.file_path))
            with _runtime.zipfile.ZipFile(self.file_path, "r") as archive:
                # `chapter.source_path` is already zip-root-relative (it's
                # set from the resolved manifest href during parsing, not
                # merely opf-dir-relative) — joining it with `opf_dir` again
                # here would double-prefix the path (e.g.
                # "OEBPS/OEBPS/chapter1.xhtml") and every asset lookup below
                # would silently miss.
                chapter_dir = _runtime.posixpath.dirname(source_path)
                asset_refs: list[tuple[str, str]] = []
                asset_refs.extend(
                    (href, chapter_dir)
                    for href in _runtime.re.findall(
                        r"<(?:img|image)\b[^>]*\b(?:src|xlink:href|href)\s*=\s*['\"]([^'\"]+)['\"]",
                        raw_html,
                        _runtime.re.I,
                    )
                )
                asset_refs.extend(
                    (href, chapter_dir)
                    for href in _runtime.re.findall(r"url\(\s*['\"]?([^)'\"\s]+)", raw_html, _runtime.re.I)
                )
                for link in _runtime.re.findall(r"<link\b[^>]*>", raw_html, _runtime.re.I):
                    stylesheet = _runtime.re.search(r"\bhref\s*=\s*['\"]([^'\"]+)['\"]", link, _runtime.re.I)
                    if not stylesheet:
                        continue
                    css_path = parser._join_path(chapter_dir, _runtime.unquote(stylesheet.group(1)))
                    try:
                        css = archive.read(css_path).decode("utf-8", errors="replace")
                    except (KeyError, UnicodeDecodeError):
                        continue
                    css_dir = _runtime.posixpath.dirname(css_path)
                    asset_refs.extend(
                        (href, css_dir)
                        for href in _runtime.re.findall(r"url\(\s*['\"]?([^)'\"\s]+)", css, _runtime.re.I)
                    )
                if not asset_refs:
                    return []
                resources: list[dict[str, str]] = []
                seen: set[str] = set()
                for href, base_dir in asset_refs[:64]:
                    if href.lower().startswith(("data:", "http:", "https:")):
                        continue
                    clean_href = href.split("#", 1)[0].split("?", 1)[0]
                    asset_path = parser._join_path(base_dir, _runtime.unquote(clean_href))
                    if asset_path in seen:
                        continue
                    seen.add(asset_path)
                    try:
                        data = archive.read(asset_path)
                    except KeyError:
                        continue
                    if not data or len(data) > 12 * 1024 * 1024:
                        continue
                    media_type = _runtime.mimetypes.guess_type(asset_path)[0] if _runtime.mimetypes else None
                    if not media_type or not media_type.startswith("image/"):
                        continue
                    resources.append(
                        {
                            "href": href,
                            "mediaType": media_type,
                            "dataBase64": _runtime.base64.b64encode(data).decode("ascii"),
                        }
                    )
                return resources
        except Exception:
            return []

    def extract_chapter_stylesheet(self, chapter: Chapter) -> str:
        """Return the concatenated CSS referenced by a chapter XHTML file."""
        from . import ebook_reader as _runtime
        if not self.file_path or self.file_path.suffix.lower() != ".epub":
            return ""
        raw_html = (chapter.raw_html or "").strip()
        source_path = (chapter.source_path or "").split("#", 1)[0].strip()
        if not raw_html or not source_path:
            return ""

        hrefs: list[str] = []
        for tag_match in _runtime.re.finditer(r"<link\b[^>]*>", raw_html, _runtime.re.IGNORECASE):
            attributes = dict(
                _runtime.re.findall(
                    r"([:\w-]+)\s*=\s*[\"']([^\"']*)[\"']",
                    tag_match.group(0),
                    _runtime.re.IGNORECASE,
                )
            )
            rel_tokens = attributes.get("rel", "").lower().split()
            href = attributes.get("href", "").strip()
            if "stylesheet" in rel_tokens and "alternate" not in rel_tokens and href:
                hrefs.append(href)
        if not hrefs:
            return ""

        parser = _runtime.EpubParser(str(self.file_path))
        css_parts: List[str] = []

        try:
            with _runtime.zipfile.ZipFile(self.file_path, "r") as archive:
                # See the matching comment in `extract_chapter_resources`:
                # `source_path` is already zip-root-relative, so it must not
                # be re-joined with `opf_dir` here.
                chapter_dir = _runtime.posixpath.dirname(source_path)

                seen_paths: set[str] = set()
                for href in hrefs:
                    stylesheet_path = parser._join_path(chapter_dir, href)
                    if stylesheet_path in seen_paths:
                        continue
                    seen_paths.add(stylesheet_path)
                    try:
                        css_parts.append(parser._read_zip_text(archive, stylesheet_path))
                    except Exception:
                        continue
        except Exception:
            return ""

        return "\n\n".join(part for part in css_parts if part.strip())

    def _extract_pdf_cover(self) -> Optional[CoverImage]:
        """Extract cover image from PDF's first page."""
        from . import ebook_reader as _runtime
        if not _runtime.PDF_AVAILABLE or not _runtime.pypdf:
            return None

        try:
            # Open PDF and get first page
            with open(self.file_path, "rb") as handle:
                reader = _runtime.pypdf.PdfReader(handle)  # type: ignore[arg-type]
                if not reader.pages:
                    return None

                first_page = reader.pages[0]

                # Try to extract images from first page
                if hasattr(first_page, "images"):
                    # pypdf >= 3.1.0 has images property
                    images = first_page.images
                    if images:
                        # Get the largest image (likely the cover)
                        largest_image = max(
                            images, key=lambda img: len(img.data) if hasattr(img, "data") else 0
                        )
                        if hasattr(largest_image, "data") and largest_image.data:
                            # Determine media type and extension
                            image_name = getattr(largest_image, "name", "") or ""
                            extension = _runtime.Path(image_name).suffix if image_name else ""

                            # Try to detect image format from data
                            data = largest_image.data
                            if data.startswith(b"\xff\xd8\xff"):
                                media_type = "image/jpeg"
                                extension = extension or ".jpg"
                            elif data.startswith(b"\x89PNG\r\n\x1a\n"):
                                media_type = "image/png"
                                extension = extension or ".png"
                            elif data.startswith(b"GIF87a") or data.startswith(b"GIF89a"):
                                media_type = "image/gif"
                                extension = extension or ".gif"
                            else:
                                media_type = "image/jpeg"
                                extension = extension or ".jpg"

                            if not extension.startswith("."):
                                extension = f".{extension}"

                            return _runtime.CoverImage(data=data, media_type=media_type, extension=extension)

                # Fallback: Try XObject images (older pypdf versions or complex PDFs)
                if "/Resources" in first_page and "/XObject" in first_page["/Resources"]:
                    xobject = first_page["/Resources"]["/XObject"]
                    if hasattr(xobject, "get_object"):
                        xobject = xobject.get_object()

                    # Find largest image
                    largest_data = None
                    largest_size = 0
                    image_filter = None

                    for obj_name in xobject:
                        obj = xobject[obj_name]
                        if hasattr(obj, "get_object"):
                            obj = obj.get_object()

                        if obj.get("/Subtype") == "/Image":
                            try:
                                data = obj.get_data()
                                if len(data) > largest_size:
                                    largest_size = len(data)
                                    largest_data = data
                                    image_filter = obj.get("/Filter", "")
                            except Exception:
                                continue

                    if largest_data:
                        # Determine format from filter
                        if "DCTDecode" in str(image_filter):
                            media_type = "image/jpeg"
                            extension = ".jpg"
                        elif "FlateDecode" in str(image_filter):
                            media_type = "image/png"
                            extension = ".png"
                        else:
                            # Try to detect from data
                            if largest_data.startswith(b"\xff\xd8\xff"):
                                media_type = "image/jpeg"
                                extension = ".jpg"
                            elif largest_data.startswith(b"\x89PNG\r\n\x1a\n"):
                                media_type = "image/png"
                                extension = ".png"
                            else:
                                media_type = "image/jpeg"
                                extension = ".jpg"

                        return _runtime.CoverImage(
                            data=largest_data, media_type=media_type, extension=extension
                        )

        except Exception:
            return None

        return None

    def _detect_cover_entry(
        self,
        opf_tree: ET.Element,
        manifest: Dict[str, Dict[str, str]],
    ) -> Optional[Dict[str, str]]:
        from . import ebook_reader as _runtime
        metadata = opf_tree.find("opf:metadata", _runtime.XML_NS)
        cover_id = None
        if metadata is not None:
            meta_cover = metadata.find("opf:meta[@name='cover']", _runtime.XML_NS)
            if meta_cover is None:
                for meta in metadata.findall(".//*"):
                    tag = meta.tag.split("}", 1)[-1]
                    if tag.lower() == "meta" and meta.attrib.get("name") == "cover":
                        meta_cover = meta
                        break
            if meta_cover is not None:
                cover_id = meta_cover.attrib.get("content")
        if cover_id and cover_id in manifest:
            return manifest[cover_id]

        for item_id, entry in manifest.items():
            props = (entry.get("properties") or "").lower()
            href = entry.get("href") or ""
            media_type = (entry.get("media_type") or "").lower()
            if "cover-image" in props:
                return entry
            if item_id.lower() in {"cover", "cover-image"}:
                return entry
            if media_type.startswith("image/") and "cover" in href.lower():
                return entry
        return None
