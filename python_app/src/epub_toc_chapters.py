# -*- coding: utf-8 -*-
"""TOC-directed chapter extraction and spine indexing."""

from __future__ import annotations

import zipfile

from typing import Any, Dict, Iterable, List, Optional

from .ebook_models import Chapter, TocItem


class EpubTocChapters:
    """TOC-directed chapter extraction and spine indexing."""

    def _extract_chapters_from_toc(
        self,
        archive: zipfile.ZipFile,
        manifest: Dict[str, str],
        spine_ids: Iterable[str],
        base_dir: str,
        toc: List[TocItem],
        cue_locale: str = "en",
    ) -> List[Chapter]:
        """Extract chapters based on the TOC (Table of Contents) structure.

        This avoids content duplication by using the book's actual hierarchy.
        """
        from . import ebook_reader as _runtime
        chapters: List[Chapter] = []
        index_counter = 1
        context_words = 8

        # Cache of already-read HTML content
        html_cache: Dict[str, str] = {}
        # Track already-processed files (without anchor)
        processed_full_files: set = set()

        def get_html_content(href: str) -> str:
            """Get HTML content from a file, using cache."""
            # Extract only the file (without anchor)
            file_path = href.split("#")[0] if "#" in href else href
            if not file_path:
                return ""

            if file_path in html_cache:
                return html_cache[file_path]

            asset_path = self._join_path(base_dir, file_path)
            try:
                content = self._read_zip_text(archive, asset_path)
                html_cache[file_path] = content
                return content
            except KeyError:
                return ""

        def get_all_split_files_content(href: str) -> str:
            """Get content from all related split files.

            If the file is part0006_split_000.html, also loads:
            part0006_split_001.html, part0006_split_002.html, etc.
            """
            file_path = href.split("#")[0] if "#" in href else href
            if not file_path:
                return ""

            # Check if it's a split file
            if "_split_" in file_path:
                # Extract base and split number
                base_pattern = file_path.rsplit("_split_", 1)[0]

                # Collect all splits of this file
                all_content = []
                split_num = 0

                while True:
                    split_file = f"{base_pattern}_split_{split_num:03d}.html"
                    content = get_html_content(split_file)
                    if content:
                        all_content.append(content)
                        split_num += 1
                    else:
                        break

                if all_content:
                    return "\n".join(all_content)

            # If it's not a split or no splits were found, return single file
            return get_html_content(href)

        def process_toc_item(item: TocItem, level: int = 1) -> None:
            """Process a TOC item and its children recursively."""
            nonlocal index_counter

            # Extract file and anchor
            if "#" in item.href:
                file_path_only = item.href.split("#")[0]
                anchor = item.href.split("#")[1]
            else:
                file_path_only = item.href
                anchor = ""

            # For split files, use base without split number
            base_file = file_path_only
            if "_split_" in file_path_only:
                base_file = file_path_only.rsplit("_split_", 1)[0]

            # If there's no anchor and the file/base was already processed, skip
            if not anchor and base_file in processed_full_files:
                return

            # Get HTML content of this item (including all splits)
            raw_content = get_all_split_files_content(item.href)
            if not raw_content or _runtime.TextProcessor.looks_like_css(raw_content):
                return

            # Mark base as processed
            if not anchor:
                processed_full_files.add(base_file)

            # Create resolver for external footnotes
            file_path = item.href.split("#")[0] if "#" in item.href else item.href
            chapter_dir = str(_runtime.Path(self._join_path(base_dir, file_path)).parent).replace("\\", "/")

            def resolve_external_file(relative_path: str) -> Optional[str]:
                try:
                    full_path = self._join_path(chapter_dir, relative_path)
                    return self._read_zip_text(archive, full_path)
                except (KeyError, Exception):
                    return None

            # Process text
            markup_with_markers, footnotes = _runtime.TextProcessor.inject_footnotes(
                raw_content, external_file_resolver=resolve_external_file
            )
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

            # Use TOC title
            raw_title = item.title.strip() if item.title else f"Chapter {index_counter}"
            chapter_title = _runtime.TextProcessor.clean_chapter_title(raw_title)

            # Prepare speech text
            speech_text = self._prepare_speech_text(
                text,
                formatting_segments,
                raw_html=raw_content,
                chapter_title=chapter_title,
            )

            # Create chapter
            chapters.append(
                _runtime.Chapter(
                    index=index_counter,
                    name=chapter_title,
                    source_path=item.href,
                    text=text or "",
                    level=level,
                    raw_html=raw_content,
                    formatting_segments=formatting_segments,
                    footnotes=list(footnotes) if footnotes else None,
                    speech_text=speech_text or "",
                )
            )
            index_counter += 1

            # Do NOT process children - use only level 1 TOC items
            # to avoid content duplication

        # Process only level 1 TOC items (main chapters)
        for toc_item in toc:
            process_toc_item(toc_item, level=1)

        return chapters

    @staticmethod
    def _build_toc_index_map(toc: List["TocItem"]) -> Dict[str, Any]:
        """Build a file-href → hierarchical index mapping for a nested TOC.

        Level-1 items receive integer indices (1, 2, 3, …).
        Level-2 children receive string indices ``"N.M"`` where N is the
        parent's integer index and M is the child's position within that parent.
        Only the first occurrence of each file wins (URL anchors are stripped).

        Returns an empty dict for flat TOCs that have no nested children.
        """
        result: Dict[str, Any] = {}
        for level1_idx, item in enumerate(toc, 1):
            file_href = item.href.split("#")[0] if "#" in item.href else item.href
            if file_href and file_href not in result:
                result[file_href] = level1_idx
            for level2_idx, child in enumerate(item.children, 1):
                child_href = child.href.split("#")[0] if "#" in child.href else child.href
                if child_href and child_href not in result:
                    result[child_href] = f"{level1_idx}.{level2_idx}"
        return result
