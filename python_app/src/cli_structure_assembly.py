"""Structure assembly for the retained legacy CLI."""

from .cli_runtime_dependencies import Any as Any
from .cli_runtime_dependencies import ChapterStructureItem as ChapterStructureItem
from .cli_runtime_dependencies import Dict as Dict
from .cli_runtime_dependencies import EbookReader as EbookReader
from .cli_runtime_dependencies import List as List
from .cli_runtime_dependencies import Optional as Optional
from .cli_runtime_dependencies import Tuple as Tuple


class CLIStructureAssembly:
    def _generate_structure_items(
        self, reader: EbookReader, *, filter_chapters: bool = True
    ) -> List[ChapterStructureItem]:
        """Prepare structured information for chapters shared across features"""

        try:
            chapters = list(reader.get_chapters())
        except TypeError:
            return []

        if not chapters:
            return []

        book_title = reader.title
        book_author = reader.author
        toc_map = self._build_toc_map(reader)
        toc_outline_map = self._build_toc_outline_map(reader)
        toc_outline_enabled = bool(toc_outline_map)

        structure_items: List[ChapterStructureItem] = []
        division_counters: Dict[int, int] = {}
        fallback_division = 0
        fallback_counter = 0
        fallback_label: Optional[str] = None
        last_toc_split_group: Optional[str] = None

        division_remap: Dict[int, int] = {}
        next_division_index = 1

        def remap_division(original: Optional[int]) -> int:
            nonlocal next_division_index
            if original is None or original <= 0:
                value = next_division_index
                next_division_index += 1
                return value
            if original not in division_remap:
                division_remap[original] = next_division_index
                next_division_index += 1
            return division_remap[original]

        def allocate_division() -> int:
            nonlocal next_division_index
            value = next_division_index
            next_division_index += 1
            return value

        for i, chapter in enumerate(chapters):
            speak_heading = True
            if filter_chapters and self._should_skip_chapter(chapters, i, toc_map):
                continue

            href_key = self._normalize_href(str(getattr(chapter, "source_path", "")))
            split_group_key = self._split_group_key(href_key)
            toc_outline_entries = self._resolve_toc_outline_entries(href_key, toc_outline_map)
            if toc_outline_entries:
                generated_items = self._create_items_from_toc_outline_entries(
                    chapter,
                    toc_outline_entries,
                    book_title,
                    book_author,
                )
                if generated_items:
                    structure_items.extend(generated_items)
                    last_toc_split_group = split_group_key
                    last_item = generated_items[-1]
                    try:
                        division_index = int(str(last_item.index).split(".", 1)[0])
                    except (ValueError, TypeError):
                        division_index = fallback_division
                    fallback_division = division_index
                    fallback_counter = division_counters.get(division_index, fallback_counter)
                    fallback_label = last_item.main_title
                    continue
                if toc_outline_enabled:
                    continue
            elif (
                split_group_key
                and last_toc_split_group
                and split_group_key == last_toc_split_group
                and structure_items
            ):
                # Some EPUBs have extra split files with no TOC entry.
                # To keep numbering equal to TOC, append this content to the
                # last TOC chapter in the same split group instead of creating
                # a synthetic chapter label.
                extra_text = str(getattr(chapter, "text", "") or "").strip()
                if extra_text:
                    last_item = structure_items[-1]
                    base_text = (
                        str(last_item.text_override)
                        if last_item.text_override is not None
                        else str(getattr(last_item.chapter, "text", "") or "")
                    ).strip()
                    last_item.text_override = (
                        f"{base_text}\n\n{extra_text}" if base_text else extra_text
                    )
                continue
            elif toc_outline_enabled:
                # When TOC exists, keep output strictly aligned with TOC labels
                # — BUT preserve chapters with substantive text (dedicatórias,
                # epigraphs, etc.) even if they lack a TOC entry.
                orphan_text = str(getattr(chapter, "text", "") or "").strip()
                if len(orphan_text) <= 12:
                    continue
                # Fall through to create a synthetic item for this orphan chapter

            toc_entries = self._resolve_toc_entries(href_key, toc_map)
            last_toc_split_group = None

            if toc_entries:
                generated_items = self._create_items_from_toc_entries(
                    chapter, toc_entries, book_title, division_counters, remap_division, book_author
                )

                if generated_items:
                    structure_items.extend(generated_items)

                    last_item = generated_items[-1]
                    try:
                        division_index = int(str(last_item.index).split(".", 1)[0])
                    except (ValueError, TypeError):
                        division_index = fallback_division

                    fallback_division = division_index
                    fallback_counter = division_counters.get(division_index, fallback_counter)
                    fallback_label = last_item.main_title
                    continue

            toc_entry = self._select_toc_entry(toc_entries)

            clean_name = self._clean_chapter_name(str(getattr(chapter, "name", "")))

            try:
                main_name, sub_name, first_words = self._format_chapter_display(
                    chapter, chapters, i, book_title, book_author
                )[1:]
            except Exception:
                text = str(getattr(chapter, "text", ""))
                main_name = self._clean_chapter_name(
                    str(getattr(chapter, "name", f"Chapter {i + 1}"))
                )
                sub_name = None
                first_words = self._extract_first_words(text, self.PREVIEW_WORD_LIMIT)

            if toc_entry:
                division_index, division_label, child_title = toc_entry
                division_index = remap_division(division_index)
                division_counters.setdefault(division_index, 0)

                if child_title:
                    division_counters[division_index] += 1
                    index = f"{division_index}.{division_counters[division_index]}"
                    main_name = division_label
                    sub_name = child_title
                else:
                    division_counters[division_index] = 0
                    index = f"{division_index}.0"
                    main_name = division_label
                    sub_name = None

                fallback_division = division_index
                fallback_counter = division_counters[division_index]
                fallback_label = division_label

                preview = self._extract_smart_first_words(
                    str(getattr(chapter, "text", "")),
                    clean_name,
                    division_label,
                    max_words=self.PREVIEW_WORD_LIMIT,
                )
                if preview:
                    first_words = preview
            else:
                is_division = self._is_division_candidate(chapter, chapters, i)
                if fallback_division == 0 or is_division:
                    fallback_division = allocate_division()
                    division_counters[fallback_division] = 0
                    fallback_counter = 0
                    index = f"{fallback_division}.0"
                    fallback_label = main_name or fallback_label
                    main_name = fallback_label or main_name
                    sub_name = None
                    speak_heading = True
                else:
                    fallback_counter += 1
                    division_counters[fallback_division] = fallback_counter
                    index = f"{fallback_division}.{fallback_counter}"
                    if fallback_label:
                        if main_name and main_name.lower() != fallback_label.lower():
                            sub_name = sub_name or main_name
                        main_name = fallback_label
                    speak_heading = False

            main_name, sub_name, first_words = self._sanitize_display_values(
                main_name, sub_name, first_words, book_title, book_author
            )

            first_words = self._remove_duplicate_prefix(first_words, main_name, sub_name)

            display_name = index
            ordered_values = [value for value in (main_name, sub_name, first_words) if value]

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

            structure_items.append(
                self._cli_runtime.ChapterStructureItem(
                    chapter=chapter,
                    index=index,
                    main_title=main_name,
                    sub_title=sub_name,
                    preview=first_words,
                    display_name=display_name,
                    speak_heading=speak_heading,
                )
            )

        # Store expected chapter count from TOC for later validation
        if hasattr(reader, "_toc_expected_chapters"):
            delattr(reader, "_toc_expected_chapters")
        expected_count = self._count_toc_chapters(reader)
        if expected_count > 0:
            reader._toc_expected_chapters = expected_count

        # Assign unique sub-indices to split chapters that share the same index.
        # When a large chapter is split at paragraph boundaries or CSS markers, all
        # resulting parts initially receive the same TOC-derived index (e.g. "4.3").
        # Rename them to "4.3.1", "4.3.2", etc. so each part has a unique,
        # addressable index for file naming and resume logic.
        index_counts: Dict[str, int] = {}
        for item in structure_items:
            index_counts[item.index] = index_counts.get(item.index, 0) + 1

        index_seen: Dict[str, int] = {}
        resolved: List[ChapterStructureItem] = []
        for item in structure_items:
            if index_counts[item.index] > 1:
                index_seen[item.index] = index_seen.get(item.index, 0) + 1
                section_num = str(index_seen[item.index])
                new_idx = f"{item.index}.{section_num}"
                # Include the section number as visible text (not just in the
                # numeric prefix) so it appears in filenames and show-structure.
                new_sub = f"{item.sub_title} - {section_num}" if item.sub_title else section_num
                # Rebuild display_name from components using the same separator
                # rules as the original builder: " - " between title parts,
                # space before a preview that starts with lowercase or punctuation.
                parts = [v for v in (item.main_title, new_sub, item.preview) if v]
                new_display = new_idx
                for i, val in enumerate(parts):
                    if (i == len(parts) - 1) and (val[:1].islower() or val[:1] in ",;:.!?"):
                        new_display = f"{new_display} {val}"
                    else:
                        new_display = f"{new_display} - {val}"
                item = self._cli_runtime._dc_replace(item, index=new_idx, sub_title=new_sub, display_name=new_display)
            resolved.append(item)

        return resolved

    def _count_toc_chapters(self, reader: EbookReader) -> int:
        """Count expected chapters from TOC (leaf entries with href)."""
        get_toc = getattr(reader, "get_toc", None)
        if not callable(get_toc):
            return 0

        try:
            toc_entries = list(get_toc() or [])
        except Exception:
            return 0

        count = 0

        def walk(entries):
            nonlocal count
            for entry in entries:
                children = list(getattr(entry, "children", []) or [])
                if getattr(entry, "href", "") and not children:
                    count += 1
                if children:
                    walk(children)

        walk(toc_entries)
        return count

    def _build_toc_outline_map(self, reader: EbookReader) -> Dict[str, List[Dict[str, Any]]]:
        """Build href -> hierarchical TOC entries map with full numbering path."""
        mapping: Dict[str, List[Dict[str, Any]]] = {}
        get_toc = getattr(reader, "get_toc", None)
        if not callable(get_toc):
            return mapping

        try:
            toc_entries = list(get_toc() or [])
        except Exception:
            return mapping

        def register(href: str, payload: Dict[str, Any]) -> None:
            if not href:
                return
            keys = {href}
            name = self._cli_runtime.Path(href).name
            if name:
                keys.add(name.lower())
            for key in keys:
                mapping.setdefault(key, []).append(payload)

        def walk(entries, path_indices: Tuple[int, ...], path_titles: Tuple[str, ...]) -> None:
            for position, entry in enumerate(entries, start=1):
                title = (getattr(entry, "title", "") or "").strip()
                href = self._normalize_href(str(getattr(entry, "href", "") or ""))
                current_indices = path_indices + (position,)
                current_titles = path_titles + ((title,) if title else tuple())

                payload: Dict[str, Any] = {
                    "path_indices": current_indices,
                    "path_titles": current_titles,
                    "title": title,
                    "level": len(current_indices),
                }
                if href:
                    register(href, payload)

                children = list(getattr(entry, "children", []) or [])
                if children:
                    walk(children, current_indices, current_titles)

        walk(toc_entries, tuple(), tuple())
        return mapping

    def _resolve_toc_outline_entries(
        self, href_key: str, outline_map: Dict[str, List[Dict[str, Any]]]
    ) -> Optional[List[Dict[str, Any]]]:
        if not href_key:
            return None

        candidates = []
        lowered = href_key.lower()
        candidates.append(lowered)
        if "/" in lowered:
            parts = lowered.split("/")
            for start in range(1, len(parts)):
                candidates.append("/".join(parts[start:]))
        candidates.append(self._cli_runtime.Path(lowered).name)

        seen = set()
        for candidate in candidates:
            candidate = candidate.strip()
            if not candidate or candidate in seen:
                continue
            seen.add(candidate)
            entries = outline_map.get(candidate)
            if entries:
                return entries
        return None
