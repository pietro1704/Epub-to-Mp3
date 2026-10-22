# -*- coding: utf-8 -*-
"""EPUB fragment assembly and spine chapter extraction."""

from __future__ import annotations

import zipfile
from typing import Any, Dict, Iterable, List, Optional

from .ebook_models import Chapter, TocItem


class EpubChapterAssembly:
    """EPUB fragment assembly and spine chapter extraction."""

    @staticmethod
    def _html_fragment_to_chapters(
        markup_with_markers: str,
        raw_content: str,
        chapter_idx: Any,
        asset_path: str,
        toc_chapter_title: Optional[str],
        footnotes: Optional[List[Dict[str, str]]],
        cue_locale: str,
        context_words: int = 8,
        paragraph_split_chars: Optional[int] = None,
    ) -> List[Chapter]:
        """Turn one prepared HTML fragment (a spine item, or an equivalent
        section from a non-EPUB format) into one or more `Chapter` objects.

        This is the reusable core extracted from `_extract_chapters`: CSS/
        numeric-heading subchapter detection, footnote inlining, structural
        speech cues, and the paragraph-boundary size-guard split — all format
        -agnostic once the caller has produced HTML + footnotes for a single
        section. Non-EPUB parsers (FB2, DOCX, MOBI) should call this directly
        (`EpubParser._html_fragment_to_chapters(...)`, no EPUB instance
        needed — it's a `@staticmethod`) instead of reimplementing any of the
        above; only EPUB's spine/manifest traversal and CBZ (no HTML/text at
        all) live outside of it.
        """
        from . import ebook_reader as _runtime
        chapters: List[_runtime.Chapter] = []
        paragraph_split_chars = paragraph_split_chars or _runtime.SUBCHAPTER_MAX_CHARS

        # --- Subchapter detection ---
        # Try to split the spine file at known CSS subchapter-title markers.
        sub_splits = _runtime.EpubParser._split_html_on_subchapter_markers(
            markup_with_markers,
            chapter_idx,
            _runtime.SUBCHAPTER_NUMBER_CLASSES,
            _runtime.SUBCHAPTER_TITLE_CLASS,
        )
        # Fallback: detect numeric headings (e.g. <h3>1</h3>, <h3>2</h3>...).
        if sub_splits is None:
            sub_splits = _runtime.EpubParser._split_html_on_numeric_headings(
                markup_with_markers, chapter_idx
            )

        if sub_splits:
            # Each CSS-marker fragment becomes an independent Chapter.
            for sec_num, (sub_index, sub_title, sub_html, has_explicit_title) in enumerate(
                sub_splits, 1
            ):
                # When the section has no dedicated title element (class_sG5),
                # the title was derived from the first content paragraph.
                # Prefix it with the parent chapter title and section number
                # so that each file is identifiable without extra context.
                if has_explicit_title:
                    chapter_name = sub_title
                else:
                    if toc_chapter_title:
                        chapter_name = f"{toc_chapter_title} - {sec_num} - {sub_title}"
                    else:
                        chapter_name = f"{sec_num} - {sub_title}"

                sub_text_fmt, sub_segments = _runtime.TextProcessor.html_to_plain_text_with_formatting(
                    sub_html
                )
                if footnotes:
                    sub_text_fn = _runtime.TextProcessor._render_footnotes(
                        sub_text_fmt,
                        footnotes,
                        mode="inline",
                        context_words=context_words,
                        phrases=_runtime._footnote_phrases_for_locale(cue_locale),
                    )
                    sub_segments = _runtime.TextProcessor._apply_footnotes_to_segments(
                        sub_segments,
                        footnotes,
                        mode="inline",
                        context_words=context_words,
                        phrases=_runtime._footnote_phrases_for_locale(cue_locale),
                    )
                else:
                    sub_text_fn = sub_text_fmt
                sub_text = _runtime.TextProcessor.add_pause_before_dash(sub_text_fn)
                # Use only the parent TOC title (not the full chapter_name which
                # includes the derived sub_title snippet) so that the first-sentence
                # content is not double-spoken: once as a structural heading and
                # again as the opening line of the section.
                speech_title = toc_chapter_title or chapter_name
                sub_speech = _runtime.EpubParser._prepare_speech_text(
                    sub_text,
                    sub_segments,
                    raw_html=sub_html,
                    chapter_title=speech_title,
                    cue_locale=cue_locale,
                )

                # A CSS sub-chapter can still be very long (e.g. a long
                # chapter with no further heading markers).  Apply the same
                # paragraph-boundary split so no single chapter exceeds the
                # max size threshold.
                if sub_text and len(sub_text) > paragraph_split_chars:
                    para_splits = _runtime.EpubParser._split_text_at_paragraph_boundaries(
                        sub_text, paragraph_split_chars, sub_index
                    )
                    for p_idx, p_text in para_splits:
                        p_speech = _runtime.EpubParser._prepare_speech_text(
                            p_text,
                            None,  # re-parse from fragment, not full-chapter segments
                            raw_html=sub_html,
                            chapter_title=speech_title,
                            cue_locale=cue_locale,
                        )
                        chapters.append(
                            _runtime.Chapter(
                                index=p_idx,
                                name=chapter_name,
                                source_path=asset_path,
                                text=p_text,
                                raw_html=sub_html,
                                formatting_segments=sub_segments,
                                footnotes=list(footnotes) if footnotes else None,
                                speech_text=p_speech or "",
                            )
                        )
                else:
                    chapters.append(
                        _runtime.Chapter(
                            index=sub_index,
                            name=chapter_name,
                            source_path=asset_path,
                            text=sub_text or "",
                            raw_html=sub_html,
                            formatting_segments=sub_segments,
                            footnotes=list(footnotes) if footnotes else None,
                            speech_text=sub_speech or "",
                        )
                    )
        else:
            # No CSS markers — process as a single chapter.
            text_with_formatting, formatting_segments = (
                _runtime.TextProcessor.html_to_plain_text_with_formatting(markup_with_markers)
            )
            if footnotes:
                text_with_footnotes = _runtime.TextProcessor._render_footnotes(
                    text_with_formatting,
                    footnotes,
                    mode="inline",
                    context_words=context_words,
                    phrases=_runtime._footnote_phrases_for_locale(cue_locale),
                )
                formatting_segments = _runtime.TextProcessor._apply_footnotes_to_segments(
                    formatting_segments,
                    footnotes,
                    mode="inline",
                    context_words=context_words,
                    phrases=_runtime._footnote_phrases_for_locale(cue_locale),
                )
            else:
                text_with_footnotes = text_with_formatting
            text = _runtime.TextProcessor.add_pause_before_dash(text_with_footnotes)
            raw_title = toc_chapter_title or (
                _runtime.TextProcessor.extract_title(raw_content, f"Chapter {chapter_idx}")
                if text
                else f"Chapter {chapter_idx}"
            )
            title = _runtime.TextProcessor.clean_chapter_title(raw_title)

            # IMPORTANT: speech_text preserves [[lang:xx]] and [[fmt:...]] tags
            # while stripping only inline markdown (_italic_, **bold**, `code`).
            speech_text = _runtime.EpubParser._prepare_speech_text(
                text,
                formatting_segments,
                raw_html=raw_content,
                chapter_title=title,
                cue_locale=cue_locale,
            )

            # --- Paragraph-boundary fallback split ---
            # When a chapter has no CSS subchapter markers but exceeds the
            # size threshold (computed from Edge concurrency / timeout),
            # split at paragraph boundaries to prevent Edge-TTS timeouts.
            if text and len(text) > paragraph_split_chars:
                para_splits = _runtime.EpubParser._split_text_at_paragraph_boundaries(
                    text, paragraph_split_chars, chapter_idx
                )
                for split_idx, split_text in para_splits:
                    split_speech = _runtime.EpubParser._prepare_speech_text(
                        split_text,
                        None,  # re-parse from fragment, not full-chapter segments
                        raw_html=markup_with_markers,
                        chapter_title=title,
                        cue_locale=cue_locale,
                    )
                    chapters.append(
                        _runtime.Chapter(
                            index=split_idx,
                            name=title,
                            source_path=asset_path,
                            text=split_text,
                            raw_html=markup_with_markers,
                            formatting_segments=formatting_segments,
                            footnotes=list(footnotes) if footnotes else None,
                            speech_text=split_speech or "",
                        )
                    )
            else:
                chapters.append(
                    _runtime.Chapter(
                        index=chapter_idx,
                        name=title,
                        source_path=asset_path,
                        text=text or "",
                        raw_html=raw_content,
                        formatting_segments=formatting_segments,
                        footnotes=list(footnotes) if footnotes else None,
                        speech_text=speech_text or "",
                    )
                )

        return chapters

    def _extract_chapters(
        self,
        archive: zipfile.ZipFile,
        manifest: Dict[str, str],
        spine_ids: Iterable[str],
        base_dir: str,
        toc_title_map: Optional[Dict[str, str]] = None,
        toc: Optional[List[TocItem]] = None,
        book_language: Optional[str] = None,
    ) -> List[Chapter]:
        from . import ebook_reader as _runtime
        import os as _os
        from concurrent.futures import ThreadPoolExecutor

        chapters: List[Chapter] = []
        index_counter = 1
        context_words = 8

        # Derive the cue locale from the book's declared language so that
        # italic/bold verbal cues ("in italics" vs "em itálico") match the
        # language being read.  Falls back to "en" when language is unknown.
        cue_locale = (book_language or "en").split("-")[0].lower()

        # When the TOC has nested items (e.g. Part > Chapter), build a
        # file-href → hierarchical index map so chapters inherit the TOC
        # hierarchy (e.g. Parte 2 = 5, Capítulo 4 = "5.1").
        has_nested_toc = toc is not None and any(item.children for item in toc)
        toc_index_map: Dict[str, Any] = self._build_toc_index_map(toc) if has_nested_toc else {}
        # Orphan counter for spine items that are not in the TOC index map.
        # Starts after the last level-1 TOC index to avoid collisions.
        _max_toc_idx = max(
            (v for v in toc_index_map.values() if isinstance(v, int)),
            default=0,
        )
        orphan_counter = _max_toc_idx

        # --- Pre-pass: parallel read + footnote injection -------------------
        # The zip read + footnote walk is the I/O-heaviest part of parsing
        # and is independent per spine item. We materialise the spine list,
        # parallelise the prep step (gated by env var, default on), then
        # iterate the prepared payload in spine order so the orphan_counter
        # and chapter assembly remain deterministic.
        spine_list = list(spine_ids)

        archive_lock = _runtime.threading.Lock()
        parallel_enabled = _os.getenv("EPUB_PARSE_PARALLEL", "1").strip() != "0"
        max_workers = max(1, min(8, len(spine_list)))
        prepared: List[Optional[Dict[str, Any]]]
        if parallel_enabled and len(spine_list) > 4:
            with ThreadPoolExecutor(max_workers=max_workers) as ex:
                prepared = list(
                    ex.map(
                        lambda iid: self._prepare_spine_item(
                            archive, archive_lock, iid, manifest, base_dir
                        ),
                        spine_list,
                    )
                )
        else:
            prepared = [
                self._prepare_spine_item(archive, archive_lock, iid, manifest, base_dir)
                for iid in spine_list
            ]

        for payload in prepared:
            if payload is None:
                continue
            href = payload["href"]
            asset_path = payload["asset_path"]
            raw_content = payload["raw_content"]
            markup_with_markers = payload["markup_with_markers"]
            footnotes = payload["footnotes"]

            # Determine the hierarchical index for this spine file.
            # When the TOC has nested items, look up the file in the TOC index
            # map; fall back to a sequential orphan counter for files not in the
            # TOC (e.g. blank pages, dedication pages).
            if toc_index_map:
                chapter_idx: Any = toc_index_map.get(href) or toc_index_map.get(asset_path)
                if chapter_idx is None:
                    orphan_counter += 1
                    chapter_idx = orphan_counter
            else:
                chapter_idx = index_counter

            # Look up the TOC title for this file (used for naming derived splits).
            toc_chapter_title: Optional[str] = None
            if toc_title_map:
                toc_chapter_title = toc_title_map.get(asset_path) or toc_title_map.get(href)

            chapters.extend(
                self._html_fragment_to_chapters(
                    markup_with_markers=markup_with_markers,
                    raw_content=raw_content,
                    chapter_idx=chapter_idx,
                    asset_path=asset_path,
                    toc_chapter_title=toc_chapter_title,
                    footnotes=footnotes,
                    cue_locale=cue_locale,
                    context_words=context_words,
                    paragraph_split_chars=self.paragraph_split_chars,
                )
            )

            index_counter += 1

        # Drop chapters whose text is empty (or only whitespace) after extraction.
        # These arise from spine items that have no prose content (cover images,
        # blank separators, map plates) and would otherwise produce silent MP3s
        # or corrupt the chapter index.
        nonempty: List[Chapter] = []
        for ch in chapters:
            if ch.text and ch.text.strip():
                nonempty.append(ch)
            else:
                import logging as _logging

                _logging.getLogger(__name__).debug(
                    "Dropping empty chapter: index=%s name=%r", ch.index, ch.name
                )
        return nonempty
