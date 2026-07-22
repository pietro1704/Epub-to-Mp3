"""Allowlist-based sanitization for EPUB content rendered by the web reader."""

from __future__ import annotations

import html
import re
from html.parser import HTMLParser
from urllib.parse import urlparse

_ALLOWED_TAGS = {
    "a",
    "abbr",
    "article",
    "b",
    "blockquote",
    "br",
    "caption",
    "cite",
    "code",
    "dd",
    "div",
    "dl",
    "dt",
    "em",
    "figcaption",
    "figure",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
    "hr",
    "i",
    "img",
    "li",
    "mark",
    "ol",
    "p",
    "pre",
    "q",
    "s",
    "small",
    "span",
    "strong",
    "sub",
    "sup",
    "table",
    "tbody",
    "td",
    "tfoot",
    "th",
    "thead",
    "tr",
    "u",
    "ul",
}
_VOID_TAGS = {"br", "hr", "img"}
_ALLOWED_ATTRIBUTES = {
    "a": {"href", "title", "id", "class", "lang"},
    "img": {"src", "alt", "title", "width", "height", "id", "class"},
}
_GLOBAL_ATTRIBUTES = {"id", "class", "lang", "title", "dir", "style"}
_SAFE_SCHEMES = {"", "http", "https", "mailto"}
_DANGEROUS_CSS = re.compile(
    r"(?:expression|behavior|-moz-binding|javascript\s*:|vbscript\s*:|data\s*:\s*text/html|@import|url\s*\()",
    re.IGNORECASE,
)
_CSS_PROPERTY = re.compile(r"^[-a-z]+$")
_SAFE_CSS_PROPERTIES = {
    "background-color",
    "border",
    "border-bottom",
    "border-color",
    "border-left",
    "border-radius",
    "border-right",
    "border-spacing",
    "border-style",
    "border-top",
    "border-width",
    "color",
    "display",
    "float",
    "font-family",
    "font-size",
    "font-style",
    "font-variant",
    "font-weight",
    "height",
    "letter-spacing",
    "line-height",
    "margin",
    "margin-bottom",
    "margin-left",
    "margin-right",
    "margin-top",
    "max-height",
    "max-width",
    "min-height",
    "min-width",
    "opacity",
    "padding",
    "padding-bottom",
    "padding-left",
    "padding-right",
    "padding-top",
    "text-align",
    "text-decoration",
    "text-indent",
    "text-transform",
    "vertical-align",
    "white-space",
    "width",
}


def _safe_url(value: str) -> bool:
    normalized = value.strip().replace("\x00", "").lower()
    parsed = urlparse(normalized)
    return parsed.scheme in _SAFE_SCHEMES and not normalized.startswith("//")


def sanitize_reader_css(css: str | None) -> str:
    """Keep only simple declarations supported by the reader's isolated surface."""
    if not isinstance(css, str):
        return ""
    css = re.sub(r"/\*.*?\*/", "", css, flags=re.DOTALL)
    output: list[str] = []
    for block in re.findall(r"([^{}@]+)\{([^{}]*)\}", css):
        selector, declarations = block
        if "</style" in selector.lower() or "<script" in selector.lower():
            continue
        safe_declarations: list[str] = []
        for declaration in declarations.split(";"):
            if ":" not in declaration:
                continue
            property_name, value = (part.strip() for part in declaration.split(":", 1))
            property_name = property_name.lower()
            if (
                property_name not in _SAFE_CSS_PROPERTIES
                or not _CSS_PROPERTY.fullmatch(property_name)
                or not value
                or _DANGEROUS_CSS.search(value)
                or "<" in value
                or ">" in value
            ):
                continue
            safe_declarations.append(f"{property_name}: {value}")
        if safe_declarations:
            output.append(f"{selector.strip()} {{ {'; '.join(safe_declarations)}; }}")
    return "\n".join(output)


class _ReaderHTMLParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.output: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        tag = tag.lower()
        if tag not in _ALLOWED_TAGS:
            return
        allowed = _ALLOWED_ATTRIBUTES.get(tag, set()) | _GLOBAL_ATTRIBUTES
        rendered: list[str] = []
        for name, value in attrs:
            name = name.lower()
            if name.startswith("on") or name not in allowed or value is None:
                continue
            if name in {"href", "src"} and not _safe_url(value):
                continue
            if name == "style":
                value = sanitize_reader_css(f"x {{{value}}}")
                value = value.partition("{")[2].rpartition("}")[0].strip()
                if not value:
                    continue
            rendered.append(f' {name}="{html.escape(value, quote=True)}"')
        self.output.append(f"<{tag}{''.join(rendered)}>")

    def handle_startendtag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        self.handle_starttag(tag, attrs)

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() in _ALLOWED_TAGS and tag.lower() not in _VOID_TAGS:
            self.output.append(f"</{tag.lower()}>")

    def handle_data(self, data: str) -> None:
        self.output.append(html.escape(data))


def sanitize_reader_html(markup: str | None) -> str:
    """Serialize only allowlisted EPUB markup and safe URL-bearing attributes."""
    if not isinstance(markup, str):
        return ""
    parser = _ReaderHTMLParser()
    parser.feed(markup)
    parser.close()
    return "".join(parser.output)
