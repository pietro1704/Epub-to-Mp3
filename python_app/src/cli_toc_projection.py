"""Toc projection for the retained legacy CLI."""

from .cli_runtime_dependencies import (
    Any as Any,
    Chapter as Chapter,
    ChapterStructureItem as ChapterStructureItem,
    Dict as Dict,
    EbookReader as EbookReader,
    List as List,
    Optional as Optional,
    Tuple as Tuple,
)

class CLITocProjection:
    def _create_items_from_toc_outline_entries(
        self,
        chapter: Chapter,
        toc_outline_entries: List[Dict[str, Any]],
        book_title: str,
        book_author: str = "",
    ) -> List[ChapterStructureItem]:
        """Expand chapter entries preserving exact TOC hierarchy (1, 1.2, 1.2.3...)."""
        text = str(getattr(chapter, "text", ""))
        if not toc_outline_entries:
            return []

        deduped: List[Dict[str, Any]] = []
        seen_paths: set[Tuple[int, ...]] = set()
        for entry in toc_outline_entries:
            path = tuple(entry.get("path_indices") or tuple())
            if not path or path in seen_paths:
                continue
            seen_paths.add(path)
            deduped.append(entry)
        if not deduped:
            return []

        path_set = {tuple(entry.get("path_indices") or tuple()) for entry in deduped}

        # Skip parent entries if descendants share the same href; this avoids duplicate content.
        leaf_entries: List[Dict[str, Any]] = []
        for entry in deduped:
            path = tuple(entry.get("path_indices") or tuple())
            has_descendant = any(
                other != path and len(other) > len(path) and other[: len(path)] == path
                for other in path_set
            )
            if has_descendant:
                continue
            leaf_entries.append(entry)

        if not leaf_entries:
            leaf_entries = deduped

        titles_for_split = [str(entry.get("title", "") or "").strip() for entry in leaf_entries]
        valid_titles = [title for title in titles_for_split if title]
        segments_by_title: Dict[str, str] = {}
        if len(valid_titles) > 1 and text:
            segments = self._split_text_by_titles(text, valid_titles)
            for title, segment in zip(valid_titles, segments):
                if title and segment:
                    segments_by_title[title] = segment

        items: List[ChapterStructureItem] = []
        for entry in leaf_entries:
            path = tuple(entry.get("path_indices") or tuple())
            if not path:
                continue
            title = str(entry.get("title", "") or "").strip()
            titles_path = tuple(entry.get("path_titles") or tuple())
            index = ".".join(str(part) for part in path)

            segment_text = segments_by_title.get(title) if title else None
            if not segment_text:
                segment_text = text
            if not str(segment_text).strip():
                segment_text = title or str(getattr(chapter, "name", "") or "")
            if not str(segment_text).strip():
                continue

            main_name = str(titles_path[0]).strip() if titles_path else title
            sub_parts = [str(part).strip() for part in titles_path[1:] if str(part).strip()]
            sub_name = " - ".join(sub_parts) if sub_parts else None

            clean_name = self._clean_chapter_name(title or getattr(chapter, "name", ""))
            preview = self._extract_smart_first_words(
                segment_text,
                clean_name,
                main_name,
                max_words=self.PREVIEW_WORD_LIMIT,
            )

            main_name, sub_name, preview = self._sanitize_display_values(
                main_name, sub_name, preview, book_title, book_author
            )
            preview = self._remove_duplicate_prefix(preview, main_name, sub_name)

            display_name = index
            ordered_values = [value for value in (main_name, sub_name, preview) if value]
            for idx_value, value in enumerate(ordered_values):
                separator = " - "
                if idx_value == len(ordered_values) - 1 and value[:1].islower():
                    separator = " "
                if value[:1] in {",", ";", ":", ".", "!", "?"}:
                    separator = " "
                if separator == " ":
                    display_name = f"{display_name} {value}"
                else:
                    display_name = f"{display_name}{separator}{value}"

            items.append(
                self._cli_runtime.ChapterStructureItem(
                    chapter=chapter,
                    index=index,
                    main_title=main_name,
                    sub_title=sub_name,
                    preview=preview,
                    display_name=display_name,
                    text_override=segment_text,
                    speak_heading=True,
                )
            )

        return items

    def _validate_chapter_count(
        self, chapters: List[Any], reader: EbookReader, duplicates_removed: int = 0
    ) -> Tuple[List[Any], bool]:
        """Validate chapter count against TOC and auto-correct if needed.

        Returns:
            Tuple of (chapters_list, was_corrected)
        """
        expected_count = getattr(reader, "_toc_expected_chapters", 0)

        # Skip validation if no TOC info or too few chapters in TOC
        if expected_count == 0 or expected_count < 3:
            return chapters, False

        actual_count = len(chapters)

        # If counts match or differ by 1 (common due to cover/title pages), everything is good
        diff = abs(actual_count - expected_count)
        if diff == 0:
            return chapters, False

        if diff == 1:
            # Small difference (likely cover page, title page, etc.) - just warn
            print(f"\nℹ️  TOC: {expected_count} chapters | Detected: {actual_count} chapters")
            if actual_count < expected_count:
                print(f"💡 Difference: {diff} (likely cover page or title page ignored)")
            return chapters, False

        # Significant count mismatch - attempt auto-correction
        print(
            f"\n⚠️  VALIDAÇÃO: TOC indica {expected_count} capítulos, mas foram detectados {actual_count}"
        )

        # If we removed duplicates and that caused the mismatch, restore original
        if duplicates_removed > 0 and (actual_count + duplicates_removed) == expected_count:
            print(
                f"🔄 Auto-correction: restoring {duplicates_removed} chapter(s) removed as duplicate"
            )
            print("💡 Reason: deduplication removed valid chapters")

            # Return the chapters WITHOUT deduplication
            # Note: we need to re-generate or get the original list
            # For now, we'll signal that deduplication should be skipped
            return chapters, True

        # If actual > expected, deduplication might help
        if actual_count > expected_count:
            print(f"💡 Detected {actual_count - expected_count} more chapters than expected")
            print("✓ Keeping current result (possible sub-chapters in TOC)")
        else:
            print(f"⚠️  Missing {expected_count - actual_count} chapter(s)!")
            print("💡 Verifique se o EPUB tem estrutura complexa ou TOC incorreto")

        return chapters, False

    def _create_items_from_toc_entries(
        self,
        chapter: Chapter,
        toc_entries: List[Tuple[int, str, Optional[str]]],
        book_title: str,
        division_counters: Dict[int, int],
        remap_division,
        book_author: str = "",
    ) -> List[ChapterStructureItem]:
        """Expand a chapter into structure items using TOC anchors"""

        if not toc_entries:
            return []

        text = str(getattr(chapter, "text", ""))
        has_child_entries = any(
            entry[2] is not None and str(entry[2]).strip() and str(entry[2]).lower() != "none"
            for entry in toc_entries
        )

        # Filter entries that have child_title (excluding None and 'None' string)
        entries_with_titles = [
            entry
            for entry in toc_entries
            if entry[2] is not None and str(entry[2]).lower() != "none"
        ]
        segments_map: Dict[str, str] = {}

        # If we have multiple entries for the same file but only one has content (others are None),
        # we should use division_label as the split key instead
        if not entries_with_titles and len(toc_entries) > 1:
            # Use division_label (entry[1]) as title for splitting
            titles_for_split = [entry[1] for entry in toc_entries if entry[1]]
            if titles_for_split:
                segments = self._split_text_by_titles(text, titles_for_split)
                for entry, segment in zip(toc_entries, segments):
                    if segment and entry[1]:
                        # Map by division_label since child_title is None
                        segments_map[entry[1]] = segment

        if entries_with_titles and not segments_map:
            titles = [entry[2] for entry in entries_with_titles]
            segments = self._split_text_by_titles(text, titles)
            for entry, segment in zip(entries_with_titles, segments):
                if segment:
                    segments_map[entry[2]] = segment

        parent_title: Optional[str] = None
        items: List[ChapterStructureItem] = []

        for division_index, division_label, child_title in toc_entries:
            # When TOC has parent + children pointing to the same file, keeping the
            # parent item duplicates the first child segment. Skip the parent item.
            if has_child_entries and not child_title:
                continue

            normalized_division = remap_division(division_index)
            division_counters.setdefault(normalized_division, 0)

            if child_title:
                division_counters[normalized_division] += 1
                index = f"{normalized_division}.{division_counters[normalized_division]}"
            else:
                division_counters[normalized_division] = 0
                index = f"{normalized_division}.0"

            if child_title and not parent_title and not child_title.strip().startswith("§"):
                parent_title = child_title.strip()

            # Try to get segment from map (check both child_title and division_label)
            segment_text = None
            if child_title:
                segment_text = segments_map.get(child_title)
            elif division_label:
                segment_text = segments_map.get(division_label)
            if not segment_text:
                segment_text = text
            if not str(segment_text).strip():
                continue

            clean_name = self._clean_chapter_name(child_title or getattr(chapter, "name", ""))
            main_name = division_label or clean_name
            sub_name = child_title if child_title else None

            if parent_title and child_title and child_title.strip().startswith("§"):
                sub_name = f"{parent_title} - {child_title.strip()}"

            preview = (
                self._extract_smart_first_words(
                    segment_text, clean_name, division_label, max_words=self.PREVIEW_WORD_LIMIT
                )
                if child_title
                else self._extract_first_words(segment_text, self.PREVIEW_WORD_LIMIT)
            )

            main_name, sub_name, preview = self._sanitize_display_values(
                main_name, sub_name, preview, book_title, book_author
            )

            preview = self._remove_duplicate_prefix(preview, main_name, sub_name)

            display_name = index
            ordered_values = [value for value in (main_name, sub_name, preview) if value]
            for idx_value, value in enumerate(ordered_values):
                separator = " - "
                if idx_value == len(ordered_values) - 1 and value[:1].islower():
                    separator = " "
                if value[:1] in {",", ";", ":", ".", "!", "?"}:
                    separator = " "

                if separator == " ":
                    display_name = f"{display_name} {value}"
                else:
                    display_name = f"{display_name}{separator}{value}"

            items.append(
                self._cli_runtime.ChapterStructureItem(
                    chapter=chapter,
                    index=index,
                    main_title=main_name,
                    sub_title=sub_name,
                    preview=preview,
                    display_name=display_name,
                    text_override=segment_text,
                )
            )

        return items

    def _split_text_by_titles(self, text: str, titles: List[str]) -> List[str]:
        """Split chapter text according to the provided titles"""

        if not titles:
            return []

        lowered = text.lower()
        positions: List[int] = []
        cursor = 0

        for title in titles:
            if not title:
                positions.append(-1)
                continue

            normalized = self._cli_runtime.re.sub(r"\s+", " ", title.strip().lower())

            # Headings appear at line start - look for title after newline or at text start
            # Search in full text and find first match >= cursor to avoid ^ matching substring start
            pattern = r"(^|\n)\s*" + self._cli_runtime.re.escape(normalized) + r"\b"
            idx = -1
            for match in self._cli_runtime.re.finditer(pattern, lowered):
                # Calculate actual position (skip newline if present, then skip whitespace)
                temp_idx = match.start() + (1 if match.group(1) == "\n" else 0)
                while temp_idx < len(lowered) and lowered[temp_idx] in " \t":
                    temp_idx += 1

                # Use first match that comes at or after cursor
                if temp_idx >= cursor:
                    idx = temp_idx
                    break

            if idx == -1 and normalized.startswith("§"):
                section_marker = normalized.split(" ", 1)[0]
                idx = lowered.find(section_marker, cursor)
                if idx == -1:
                    idx = lowered.find(section_marker)

            positions.append(idx)

            if idx != -1:
                cursor = idx + 1

        starts: List[int] = []
        last_valid = 0
        for pos in positions:
            if pos is None or pos < 0:
                starts.append(last_valid)
            else:
                starts.append(pos)
                last_valid = pos

        for idx in range(1, len(starts)):
            if starts[idx] < starts[idx - 1]:
                starts[idx] = starts[idx - 1]

        segments: List[str] = []
        for idx, start in enumerate(starts):
            end = starts[idx + 1] if idx + 1 < len(starts) else len(text)
            segments.append(text[start:end].strip())

        return segments
