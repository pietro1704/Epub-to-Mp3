"""Speech transforms for the retained legacy CLI."""

from .cli_runtime_dependencies import (
    ChapterStructureItem as ChapterStructureItem,
    ConversionConfig as ConversionConfig,
    Dict as Dict,
    EbookReader as EbookReader,
    FormattingSegment as FormattingSegment,
    LanguageMarkup as LanguageMarkup,
    List as List,
)

class CLISpeechTransforms:
    def _apply_text_transforms(
        self,
        items: List[ChapterStructureItem],
        config: ConversionConfig,
        reader: EbookReader,
    ) -> List[ChapterStructureItem]:
        footnote_mode = (getattr(config, "footnote_mode", "inline") or "inline").lower()
        if footnote_mode not in {"inline", "skip", "chapter_end"}:
            footnote_mode = "inline"
        context_words = getattr(config, "footnote_context_words", 8)
        try:
            context_words = max(int(context_words), 0)
        except (TypeError, ValueError):
            context_words = 8

        processed_data: List[dict] = []
        primary_language = getattr(config, "primary_language", None) or self.localization.language
        phrases = self._footnote_phrases(primary_language)

        def build_inline_replacements(footnotes_list: List[Dict[str, str]]) -> dict[str, str]:
            if not footnotes_list or footnote_mode != "inline":
                return {}
            prefix = phrases.get("prefix", "\n")
            template = phrases.get("template", "nota de rodapé {number}: {text}")
            suffix_text = phrases.get("suffix_text", " fim da nota de rodapé")
            closing = phrases.get("closing", "")
            replacements_map: dict[str, str] = {}
            for footnote in footnotes_list:
                intro = template.format(number=footnote["number"], text=footnote["text"])
                suffix_part = suffix_text.format(number=footnote["number"], text=footnote["text"])
                replacements_map[footnote["marker"]] = f"{prefix}{intro}{suffix_part}{closing}"
            return replacements_map

        for chapter_num, item in enumerate(items, 1):
            chapter = item.chapter
            raw_html = getattr(chapter, "raw_html", None)
            if raw_html is not None and not isinstance(raw_html, str):
                raw_html = None
            chapter_footnotes = getattr(chapter, "footnotes", None)
            if chapter_footnotes is not None and not isinstance(chapter_footnotes, list):
                chapter_footnotes = None
            text_source = (
                item.text_override
                if item.text_override is not None
                else getattr(chapter, "text", "")
            )
            if text_source is None or not isinstance(text_source, str):
                text_source = str(text_source or "")
            if item.text_override is not None:
                raw_html = None

            # Reuse text already enriched with footnotes when mode is inline
            if footnote_mode == "inline" and chapter_footnotes:
                raw_html = None

            chapter_label = str(
                item.display_name
                or getattr(chapter, "name", None)
                or (item.index if isinstance(item.index, str) else None)
                or ""
            )
            # Show ordinal number (1/179) + structural identifier (4.23)
            index_display = (
                f"{chapter_num}/{len(items)} [{item.index}]"
                if item.index
                else f"{chapter_num}/{len(items)}"
            )
            print(
                self.localization.t(
                    "preprocess_chapter",
                    index=index_display,
                    title=chapter_label,
                ),
                flush=True,
            )

            if raw_html:
                markup_with_markers, footnotes = self._cli_runtime.TextProcessor.inject_footnotes(
                    raw_html,
                    mode=footnote_mode,
                    context_words=context_words,
                )
                text_with_formatting, formatting_segments = (
                    self._cli_runtime.TextProcessor.html_to_plain_text_with_formatting(markup_with_markers)
                )
                updated_text = self._cli_runtime.TextProcessor._render_footnotes(
                    text_with_formatting,
                    footnotes,
                    mode=footnote_mode,
                    context_words=context_words,
                    phrases=phrases,
                )
                updated_text = self._cli_runtime.TextProcessor.add_pause_before_dash(updated_text)
                if footnotes:
                    setattr(chapter, "footnotes", list(footnotes))
                replacements = build_inline_replacements(footnotes or [])
                if formatting_segments:
                    updated_segments: list[FormattingSegment] = []
                    markers = [fn["marker"] for fn in (footnotes or [])]
                    for segment in formatting_segments:
                        segment_text = segment.text
                        if replacements:
                            for marker, replacement in replacements.items():
                                segment_text = segment_text.replace(marker, replacement)
                        elif markers:
                            for marker in markers:
                                segment_text = segment_text.replace(marker, "")
                        updated_segments.append(
                            self._cli_runtime.FormattingSegment(
                                text=segment_text,
                                formatting=segment.formatting,
                                language=segment.language,
                            )
                        )
                    chapter.formatting_segments = updated_segments
                else:
                    chapter.formatting_segments = None
            else:
                footnotes = list(chapter_footnotes or [])
                if footnote_mode == "skip":
                    updated_text = self._remove_inline_footnotes(text_source)
                else:
                    needs_render = (
                        "[[FOOTNOTE_" in text_source or "[[footnote_" in text_source.lower()
                    )
                    if footnotes and needs_render:
                        updated_text = self._cli_runtime.TextProcessor._render_footnotes(
                            text_source,
                            footnotes,
                            mode=footnote_mode,
                            context_words=context_words,
                            phrases=phrases,
                        )
                    else:
                        updated_text = text_source
                formatting_segments = getattr(chapter, "formatting_segments", None)
                if formatting_segments is not None and not isinstance(formatting_segments, list):
                    formatting_segments = None
                replacements = build_inline_replacements(footnotes or [])
                if formatting_segments:
                    updated_segments: list[FormattingSegment] = []
                    markers = [fn["marker"] for fn in (footnotes or [])]
                    for segment in formatting_segments:
                        segment_text = segment.text
                        if replacements:
                            for marker, replacement in replacements.items():
                                segment_text = segment_text.replace(marker, replacement)
                        elif markers:
                            for marker in markers:
                                segment_text = segment_text.replace(marker, "")
                        updated_segments.append(
                            self._cli_runtime.FormattingSegment(
                                text=segment_text,
                                formatting=segment.formatting,
                                language=segment.language,
                            )
                        )
                    chapter.formatting_segments = updated_segments
                else:
                    chapter.formatting_segments = None

            book_title = config.book_title or reader.title
            final_text = self._prepare_chapter_text(
                updated_text,
                display_name=chapter_label,
                book_title=book_title,
            )
            if not final_text:
                continue

            # Strip inline markdown for speech (remove *, _, etc.)
            processor = self._cli_runtime.TextFormattingProcessor()
            processor.apply_inline_formatting(final_text)
            speech_text = processor.strip_inline_markdown(final_text)

            # Re-apply structural speech cues over the cleaned text so
            # chapter title announcements ("Capítulo 1...") and "<N> |"
            # number markers survive the markdown stripping. The
            # ebook_reader.TextProcessor runs this once during parse,
            # but `_apply_text_transforms` regenerates speech_text from
            # the raw `chapter.text` (which has no cues) — without this
            # second pass the pre-tts cache loses every pause and Edge
            # reads "Capítulo 1 1 a transformação..." in one breath.
            _raw_html = getattr(item.chapter, "raw_html", None)
            _chapter_title = getattr(item.chapter, "name", None)
            if _raw_html is not None and not isinstance(_raw_html, str):
                _raw_html = None
            if _chapter_title is not None and not isinstance(_chapter_title, str):
                _chapter_title = None
            from src.ebook_reader import TextProcessor as _EReader_TP

            speech_text = _EReader_TP.apply_structural_speech_cues(
                speech_text,
                raw_html=_raw_html,
                chapter_title=_chapter_title,
            )

            # **NEW**: Apply automatic language detection if enabled
            if getattr(config, "use_language_detection", True):
                try:
                    from src.language import LanguageMarkup

                    markup = LanguageMarkup()
                    speech_text = markup.annotate(
                        speech_text,
                        primary_language,
                        prioritize_primary_language=getattr(
                            config, "prioritize_primary_language", True
                        ),
                    )
                except (ImportError, Exception) as e:
                    # Silent failure — continue without detection
                    if config.verbose:
                        print(f"⚠️ Language detection disabled: {e}")

            chapter.speech_text = speech_text  # Clean text for TTS

            lines = [line.strip() for line in final_text.splitlines() if line.strip()]
            if not lines:
                continue

            processed_data.append(
                {
                    "item": item,
                    "lines": lines,
                    "line_sigs": [self._text_signature(line) for line in lines],
                    "text": "\n".join(lines),
                }
            )

        index_to_data: dict[str, dict] = {}
        for chapter_record in processed_data:
            index = getattr(chapter_record["item"], "index", None)
            if isinstance(index, str):
                index_to_data[index] = chapter_record

        children_map: dict[str, list[dict]] = {}
        for chapter_record in processed_data:
            index = getattr(chapter_record["item"], "index", None)
            if not isinstance(index, str) or "." not in index:
                continue
            parent_index = index.rsplit(".", 1)[0]
            parent_data = index_to_data.get(parent_index)
            if parent_data is None and parent_index:
                parent_data = index_to_data.get(f"{parent_index}.0")
            if parent_data is chapter_record:
                continue
            if parent_data is None:
                continue
            children_map.setdefault(parent_index, []).append(chapter_record)

        for parent_index, child_list in children_map.items():
            parent_data = index_to_data.get(parent_index)
            if parent_data is None and parent_index:
                parent_data = index_to_data.get(f"{parent_index}.0")
            if not parent_data:
                continue
            child_signatures = {sig for child in child_list for sig in child["line_sigs"] if sig}
            parent_lines = parent_data["lines"]
            parent_sigs = parent_data["line_sigs"]
            new_lines = [
                line
                for line, sig in zip(parent_lines, parent_sigs)
                if sig and sig not in child_signatures
            ]
            if child_list:
                if new_lines:
                    first_child = child_list[0]
                    existing = set(first_child["line_sigs"])
                    prepended: list[str] = []
                    for line in new_lines:
                        sig = self._text_signature(line)
                        if sig and sig not in existing:
                            prepended.append(line)
                            existing.add(sig)
                    # **FIXED**: Remove content duplication bug - don't prepend parent content to children
                    # This was causing chapters 1.1 and 1.2 to have identical content
                    if False:  # Disabled to prevent content duplication
                        first_child_lines = prepended + first_child["lines"]
                        first_child["lines"] = first_child_lines
                        first_child["line_sigs"] = [
                            self._text_signature(line) for line in first_child_lines
                        ]
                        first_child["text"] = "\n".join(first_child_lines)
                # **FIXED**: Only skip parent if it has no remaining content after removing children content
                if not new_lines:
                    parent_data["skip"] = True
                else:
                    parent_data["lines"] = new_lines
                    parent_data["line_sigs"] = [self._text_signature(line) for line in new_lines]
                    parent_data["text"] = "\n".join(new_lines)
            else:
                if not new_lines:
                    parent_data["skip"] = True
                else:
                    parent_data["lines"] = new_lines
                    parent_data["line_sigs"] = [self._text_signature(line) for line in new_lines]
                    parent_data["text"] = "\n".join(new_lines)

        transformed_items: List[ChapterStructureItem] = []
        seen_signatures: set[str] = set()

        for chapter_record in processed_data:
            if chapter_record.get("skip"):
                continue
            text = chapter_record["text"].strip()
            if not text:
                continue

            # Preserve top-level chapters ("1") and legacy ".0" main chapters.
            item = chapter_record["item"]
            item_index = str(getattr(item, "index", "") or "")
            is_main_chapter = ("." not in item_index) or item_index.endswith(".0")

            # Skip length filter for main chapters to preserve all content
            if not is_main_chapter and len(text) < 20:
                continue

            lines = chapter_record["lines"]

            text_signature = self._text_signature(text)

            # Less aggressive filtering for main chapters.
            if not is_main_chapter:
                if text_signature == self._text_signature(item.display_name):
                    continue

                name_parts = [part.strip() for part in item.display_name.split("-") if part.strip()]
                trailing_part = name_parts[-1] if name_parts else item.display_name
                if len(lines) == 1 and self._text_signature(lines[0]) == self._text_signature(
                    trailing_part
                ):
                    continue

                if text_signature in seen_signatures:
                    continue

            seen_signatures.add(text_signature)
            item.text_override = text
            transformed_items.append(item)

        return transformed_items
