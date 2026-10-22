import os
import tempfile
import unittest
import zipfile

from src.ebook_reader import EpubParser, TocItem

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _container_xml(opf_path="OEBPS/content.opf"):
    return f"""<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
    <rootfiles>
        <rootfile full-path="{opf_path}"
                  media-type="application/oebps-package+xml"/>
    </rootfiles>
</container>"""


def _opf(spine_ids, manifest_extra="", version="2.0", metadata_extra=""):
    items = "\n".join(
        f'<item id="{sid}" href="{sid}.xhtml" media-type="application/xhtml+xml"/>'
        for sid in spine_ids
    )
    spine = "\n".join(f'<itemref idref="{sid}"/>' for sid in spine_ids)
    return f"""<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="{version}">
    <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:title>Test Book</dc:title>
        <dc:creator>Test Author</dc:creator>
        <dc:language>en</dc:language>
        {metadata_extra}
    </metadata>
    <manifest>
        {items}
        {manifest_extra}
    </manifest>
    <spine>{spine}</spine>
</package>"""


def _ncx(nav_points_xml):
    return f"""<?xml version="1.0"?>
<!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN"
    "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
    <head><meta name="dtb:uid" content="uid"/></head>
    <docTitle><text>Test Book</text></docTitle>
    <navMap>
        {nav_points_xml}
    </navMap>
</ncx>"""


def _nav_point(pid, title, href, children=""):
    return f"""<navPoint id="{pid}">
    <navLabel><text>{title}</text></navLabel>
    <content src="{href}"/>
    {children}
</navPoint>"""


def _xhtml(body="<p>Content.</p>"):
    return f"""<?xml version="1.0"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title/></head>
<body>{body}</body>
</html>"""


def _nav_xhtml(ol_content):
    return f"""<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"
      xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>nav</title></head>
<body>
<nav epub:type="toc">
  <ol>
    {ol_content}
  </ol>
</nav>
</body>
</html>"""


class EpubBuilder:
    """Fluent builder for synthetic EPUBs used in tests."""

    def __init__(self):
        self._spine = []  # list of (id, html_content)
        self._ncx = None
        self._nav = None  # (href_in_oebps, content)
        self._base = "OEBPS"

    def add_spine_file(self, file_id, content="<p>Text.</p>"):
        self._spine.append((file_id, content))
        return self

    def set_ncx(self, ncx_content):
        self._ncx = ncx_content
        return self

    def set_nav(self, nav_content, href="nav.xhtml"):
        self._nav = (href, nav_content)
        return self

    def write(self, path):
        spine_ids = [sid for sid, _ in self._spine]

        nav_manifest = ""
        if self._nav:
            nav_href, _ = self._nav
            nav_manifest = (
                f'<item id="nav" href="{nav_href}" '
                f'media-type="application/xhtml+xml" properties="nav"/>'
            )

        version = "3.0" if (self._nav and not self._ncx) else "2.0"
        opf_content = _opf(spine_ids, manifest_extra=nav_manifest, version=version)

        with zipfile.ZipFile(path, "w") as zf:
            zf.writestr("META-INF/container.xml", _container_xml())
            zf.writestr(f"{self._base}/content.opf", opf_content)

            for file_id, html_body in self._spine:
                zf.writestr(
                    f"{self._base}/{file_id}.xhtml",
                    _xhtml(html_body),
                )

            if self._ncx:
                zf.writestr(f"{self._base}/toc.ncx", self._ncx)

            if self._nav:
                nav_href, nav_content = self._nav
                zf.writestr(f"{self._base}/{nav_href}", nav_content)

        return path


__all__ = [
    "EpubBuilder",
    "EpubParser",
    "TocItem",
    "_container_xml",
    "_nav_point",
    "_nav_xhtml",
    "_ncx",
    "_opf",
    "_xhtml",
    "os",
    "tempfile",
    "unittest",
    "zipfile",
]
