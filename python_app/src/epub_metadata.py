# -*- coding: utf-8 -*-
"""EPUB package metadata and chapter speech preparation."""

from __future__ import annotations

import zipfile

from typing import Dict, List, Optional, Tuple

from .text_formatting import FormattingSegment


class EpubMetadata:
    """Prepare package metadata and speech-ready chapter text."""

    @staticmethod
    def _prepare_speech_text(
        text: str,
        formatting_segments: Optional[List[FormattingSegment]],
        *,
        raw_html: Optional[str] = None,
        chapter_title: Optional[str] = None,
        cue_locale: str = "en",
    ) -> str:
        """
        Prepare text for TTS submission with audible formatting cues.

        This method:
        1. PRESERVES [[lang:xx]] tags for multilingual TTS
        2. Converts [[fmt:...]] markers into messages the listener understands ("in italics", "in quotes", etc.)
        3. Removes only auxiliary markdown (_italic_, **bold**) that doesn't contribute to audio

        Result: the returned text is exactly the payload sent to TTS and saved in -pre-tts.txt
        """
        from . import ebook_reader as _runtime
        if not text:
            return ""

        prepared_text = text
        if _runtime.TextFormattingProcessor:
            try:
                prepared_text = _runtime.TextFormattingProcessor.enhance_natural_pauses(prepared_text)
            except Exception:
                prepared_text = text

        # Only remove inline markdown that was added by the processor
        # IMPORTANT: Do NOT remove [[lang:]] or [[fmt:]] tags
        if _runtime.TextFormattingProcessor:
            formatter = _runtime.TextFormattingProcessor(cue_locale=cue_locale)
            try:
                processed = formatter.to_audible_text(prepared_text, formatting_segments)
                if processed:
                    structured = _runtime.TextProcessor.apply_structural_speech_cues(
                        processed,
                        raw_html=raw_html,
                        chapter_title=chapter_title,
                    )
                    enhanced = _runtime.TextFormattingProcessor.enhance_natural_pauses(structured)
                    return _runtime.TextProcessor.apply_structural_speech_cues(
                        enhanced,
                        raw_html=raw_html,
                        chapter_title=chapter_title,
                    )
            except Exception:
                # Fallback to basic removal if something fails
                pass
            fallback = _runtime.TextProcessor.apply_structural_speech_cues(
                _runtime.TextFormattingProcessor.strip_inline_markdown(prepared_text),
                raw_html=raw_html,
                chapter_title=chapter_title,
            )
            enhanced_fallback = _runtime.TextFormattingProcessor.enhance_natural_pauses(fallback)
            return _runtime.TextProcessor.apply_structural_speech_cues(
                enhanced_fallback,
                raw_html=raw_html,
                chapter_title=chapter_title,
            )

        return prepared_text

    def _find_opf_path(self, archive: zipfile.ZipFile) -> str:
        from . import ebook_reader as _runtime
        try:
            container_xml = archive.read("META-INF/container.xml").decode("utf-8")
        except KeyError as exc:
            raise RuntimeError("Invalid EPUB: missing container.xml") from exc

        container = _runtime.ET.fromstring(container_xml)
        rootfile = container.find(".//ocf:rootfile", _runtime.XML_NS)
        if rootfile is None or "full-path" not in rootfile.attrib:
            raise RuntimeError("Invalid EPUB: container has no rootfile")
        return rootfile.attrib["full-path"]

    def _parse_opf(
        self,
        archive: zipfile.ZipFile,
        opf_path: str,
    ) -> Tuple[Dict[str, str], List[str], str, str, Optional[str]]:
        from . import ebook_reader as _runtime
        opf_content = self._read_zip_text(archive, opf_path)
        opf_tree = _runtime.ET.fromstring(opf_content)

        manifest: Dict[str, str] = {}
        for item in opf_tree.findall("opf:manifest/opf:item", _runtime.XML_NS):
            item_id = item.attrib.get("id")
            href = item.attrib.get("href")
            if item_id and href:
                manifest[item_id] = href

        spine: List[str] = []
        for itemref in opf_tree.findall("opf:spine/opf:itemref", _runtime.XML_NS):
            idref = itemref.attrib.get("idref")
            if idref and idref in manifest:
                spine.append(idref)

        title = ""
        author = ""
        language = None
        metadata = opf_tree.find("opf:metadata", _runtime.XML_NS)
        if metadata is not None:
            title_elem = metadata.find("dc:title", _runtime.XML_NS)
            author_elem = metadata.find("dc:creator", _runtime.XML_NS)
            language_elem = metadata.find("dc:language", _runtime.XML_NS)
            if title_elem is not None and title_elem.text:
                title = title_elem.text.strip()
            if author_elem is not None and author_elem.text:
                author = author_elem.text.strip()
            if language_elem is not None and language_elem.text:
                # Normalize to lowercase 2-letter code (e.g., 'en-US' -> 'en')
                lang_code = language_elem.text.strip().lower()
                language = lang_code.split("-")[0] if lang_code else None

        return manifest, spine, title, author, language
