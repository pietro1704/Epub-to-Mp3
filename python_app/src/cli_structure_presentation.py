"""Structure presentation for the retained legacy CLI."""

from .cli_runtime_dependencies import (
    Chapter as Chapter,
    Dict as Dict,
    EbookReader as EbookReader,
    List as List,
    Optional as Optional,
    Tuple as Tuple,
    re as re,
)

class CLIStructurePresentation:
    def _show_structure(self, reader: EbookReader, *, filter_chapters: bool = True):
        """Display book structure and save cache txt files"""
        print(f"{self.localization.t('book_label')}: {reader.title}")
        print(f"{self.localization.t('author_label')}: {reader.author}")
        structure_items = self._generate_structure_items(reader, filter_chapters=filter_chapters)

        preview_config = self.config.create_conversion_config(
            engine="edge",
            output_dir=str(self.cache_root),
            book_title=reader.title,
        )
        preview_config.footnote_mode = "inline"
        preview_config.footnote_context_words = self.FOOTNOTE_CONTEXT_WORDS

        structure_items = self._apply_text_transforms(structure_items, preview_config, reader)

        # Store original before deduplication for potential restoration
        original_items = structure_items.copy()

        structure_items, duplicates_removed = self._cli_runtime.deduplicate_chapters_by_content(structure_items)
        if duplicates_removed:
            print(f"🧹 {duplicates_removed} duplicate chapter(s) hidden")

        # Validate chapter count against TOC
        structure_items, was_corrected = self._validate_chapter_count(
            structure_items, reader, duplicates_removed
        )

        # If correction was needed, restore original without deduplication
        if was_corrected:
            print(
                f"✅ Restoring {duplicates_removed} chapter(s) — using version without deduplication\n"
            )
            structure_items = original_items

        print(f"{self.localization.t('chapters_label')}: {len(structure_items)}")

        # **Save text cache** when showing structure
        from src.cache_manager import CacheManager

        cache_manager = CacheManager(cache_dir=self.cache_root)

        chapters_data = {
            "title": reader.title or "Unknown",
            "author": reader.author or "Unknown",
            "chapters": [],
        }
        if getattr(getattr(reader, "book", None), "source_format", None) == "pdf_scan_ocr":
            chapters_data["source_format"] = "pdf_scan_ocr"

        for item in structure_items:
            cleaned_text = str(item.text_override or "")
            text_length = len(cleaned_text)
            print(
                self.localization.t(
                    "structure_item_entry", name=item.display_name, chars=text_length
                )
            )

            # Add chapter to cache data
            chapters_data["chapters"].append({"title": item.display_name, "text": cleaned_text})

        # Save to cache
        if hasattr(reader, "file_path") and reader.file_path:
            success = cache_manager.save_chapters_to_cache(reader.file_path, chapters_data)
            if success:
                # **FIXED**: Do not use override_name to avoid duplicate directories
                cache_txt_path = cache_manager._get_cache_path(self._cli_runtime.Path(reader.file_path)) / "txt"
                print(f"\n💾 Text cache saved to: {cache_txt_path}")
            else:
                print("\n⚠️  Error saving text cache")

    def _should_skip_chapter(
        self,
        chapters: List[Chapter],
        index: int,
        toc_map: Dict[str, List[Tuple[int, str, Optional[str]]]],
    ) -> bool:
        """Heuristically skip duplicate heading fragments that lack TOC links"""

        if index < 0 or index >= len(chapters):
            return True

        chapter = chapters[index]
        href_key = self._normalize_href(str(getattr(chapter, "source_path", "")))
        if self._resolve_toc_entries(href_key, toc_map):
            return False

        text = str(getattr(chapter, "text", "")).strip()
        if not text:
            return True

        # Only skip very short fragments (stray headings, HTML residue).
        # Dedicatórias and epigraphs are typically 50-500 chars and must
        # NOT be dropped — they are real book content.
        if len(text) <= 12:
            return True

        source_path = str(getattr(chapter, "source_path", "")).lower()
        if "_split_000" in source_path and len(text) < 400:
            return True

        clean_name = self._clean_chapter_name(str(getattr(chapter, "name", "")))

        if len(text) <= 120:
            if self._is_heading_like(clean_name):
                return True

            next_chapter = chapters[index + 1] if index + 1 < len(chapters) else None
            if next_chapter:
                next_key = self._normalize_href(str(getattr(next_chapter, "source_path", "")))
                if self._resolve_toc_entries(next_key, toc_map):
                    next_name = self._clean_chapter_name(str(getattr(next_chapter, "name", "")))
                    if next_name:
                        stem_current = self._heading_stem(clean_name)
                        stem_next = self._heading_stem(next_name)
                        if (
                            stem_current
                            and stem_next
                            and (stem_current in stem_next or stem_next in stem_current)
                        ):
                            return True

        return False

    def _is_heading_like(self, name: str) -> bool:
        if not name:
            return False
        lowered = name.lower()
        keywords = (
            "capítulo",
            "capitulo",
            "livro",
            "prefácio",
            "prefacio",
            "posfácio",
            "posfacio",
            "post-scriptum",
            "post scriptum",
            "pos-scriptum",
            "imagem",
        )
        return any(keyword in lowered for keyword in keywords)

    def _heading_stem(self, name: str) -> str:
        if not name:
            return ""
        lowered = name.lower()
        lowered = self._cli_runtime.re.sub(r"cap[íi]tulo\s*\d+", "", lowered)
        lowered = self._cli_runtime.re.sub(r"livro\s*[ivx]+", "", lowered)
        lowered = lowered.replace("post-scriptum", "")
        lowered = lowered.replace("post scriptum", "")
        lowered = lowered.replace("pos-scriptum", "")
        lowered = lowered.replace("prefácio", "")
        lowered = lowered.replace("prefacio", "")
        lowered = lowered.replace("posfácio", "")
        lowered = lowered.replace("posfacio", "")
        lowered = lowered.replace("imagem", "")
        lowered = lowered.replace("§", " ")
        lowered = self._cli_runtime.re.sub(r"\s+", " ", lowered)
        return lowered.strip()

    def _build_toc_map(
        self, reader: EbookReader
    ) -> Dict[str, List[Tuple[int, str, Optional[str]]]]:
        mapping: Dict[str, List[Tuple[int, str, Optional[str]]]] = {}
        get_toc = getattr(reader, "get_toc", None)
        if not callable(get_toc):
            return mapping

        try:
            toc_entries = list(get_toc() or [])
        except Exception:
            return mapping

        counter = 0

        def walk(entries, parent: Optional[Tuple[int, str]] = None):
            nonlocal counter
            for entry in entries:
                href = self._normalize_href(entry.href)
                title = entry.title.strip() if entry.title else ""
                if parent is None:
                    counter += 1
                    division_index = counter
                    division_title = title
                    if href:
                        mapping.setdefault(href, []).append((division_index, division_title, None))
                        alt_key = self._cli_runtime.Path(href).name
                        if alt_key and alt_key != href:
                            alt_key_lower = alt_key.lower()
                            mapping.setdefault(alt_key_lower, []).append(
                                (division_index, division_title, None)
                            )
                    walk(entry.children, (division_index, division_title))
                else:
                    division_index, division_title = parent
                    if href:
                        mapping.setdefault(href, []).append((division_index, division_title, title))
                        alt_key = self._cli_runtime.Path(href).name
                        if alt_key and alt_key != href:
                            alt_key_lower = alt_key.lower()
                            mapping.setdefault(alt_key_lower, []).append(
                                (division_index, division_title, title)
                            )
                    walk(entry.children, parent)

        walk(toc_entries)
        return mapping

    @staticmethod
    def _select_toc_entry(
        entries: Optional[List[Tuple[int, str, Optional[str]]]],
    ) -> Optional[Tuple[int, str, Optional[str]]]:
        if not entries:
            return None
        for entry in entries:
            if entry[2]:
                return entry
        return entries[0]

    @staticmethod
    def _normalize_href(href: str, *, namespace) -> str:
        if not href:
            return ""
        base = href.split("#", 1)[0]
        normalized = base.lstrip("./")
        normalized = normalized.strip()
        normalized = namespace.unquote(normalized)
        return normalized.lower()

    @staticmethod
    def _split_group_key(href_key: str, *, namespace) -> Optional[str]:
        if not href_key:
            return None
        match = namespace.re.search(r"^(.*)_split_\d{3}(\.[a-z0-9]+)$", href_key, flags=namespace.re.IGNORECASE)
        if not match:
            return None
        return f"{match.group(1)}{match.group(2)}".lower()

    def _resolve_toc_entries(
        self, href_key: str, toc_map: Dict[str, List[Tuple[int, str, Optional[str]]]]
    ) -> Optional[List[Tuple[int, str, Optional[str]]]]:
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
            entries = toc_map.get(candidate)
            if entries:
                return entries
        return None

    def _clean_chapter_name(self, name: str) -> str:
        """Clean up chapter name to avoid redundancy"""
        if not name:
            return ""

        import re

        # Remove redundant patterns like "0.7 -  - Livro primeiro - livro primeiro DUNA"
        # Split by " - " and remove empty parts and redundant parts
        parts = [part.strip() for part in name.split(" - ") if part.strip()]

        cleaned_parts = []
        seen_parts = set()

        for part in parts:
            # Skip parts that look like indices (e.g., "0.7", "1.0")
            if re.match(r"^\d+\.\d+$", part):
                continue
            # Skip empty or very short parts (but allow single characters for important parts)
            if len(part) == 0:
                continue
            if len(part) == 1 and part in ["@", "#", "*", "-"]:
                continue
            # Skip parts that are duplicates (case-insensitive)
            part_lower = part.lower()
            if part_lower not in seen_parts:
                seen_parts.add(part_lower)
                cleaned_parts.append(part)

        # Final cleanup for specific redundancies
        result = " - ".join(cleaned_parts) if cleaned_parts else name

        # Remove specific redundancies like "Livro primeiro - livro primeiro DUNA"
        if "Livro primeiro" in result and "livro primeiro" in result.lower():
            # Keep only the properly capitalized version
            result = re.sub(r" - livro primeiro.*?$", "", result, flags=re.IGNORECASE)

        return result
