# -*- coding: utf-8 -*-
"""Structured footnote reference and body collection."""

from __future__ import annotations

from typing import Dict, List, Tuple


class FootnoteMarkupCollection:
    """Structured footnote reference and body collection."""

    @staticmethod
    def _collect_footnotes_bs4(
        markup: str, BeautifulSoup, external_file_resolver=None
    ) -> Tuple[str, List[Dict[str, str]]]:
        from . import ebook_reader as _runtime
        soup = BeautifulSoup(markup, "html.parser")
        if soup is None:
            return markup, []

        footnotes: List[Dict[str, str]] = []
        note_numbers: Dict[str, str] = {}
        processed_targets: List[str] = []
        external_footnote_cache: Dict[str, any] = {}

        def normalise_fragment(href: str) -> str:
            if not href:
                return ""
            fragment = href.split("#", 1)[-1] if "#" in href else ""
            return fragment.strip()

        def looks_like_noteref(anchor, target_text: str, note_node=None) -> bool:
            if anchor is None or not hasattr(anchor, "get"):
                return False
            role = (safe_get(anchor, "role", "") or "").lower()
            epub_type = ""
            for attr_name in ("epub:type", "epub:type", "epub-type", "type"):
                value = safe_get(anchor, attr_name)
                if value:
                    epub_type = str(value).lower()
                    break
            classes = normalise_classes(safe_get(anchor, "class", []))
            href_value = (
                safe_get(anchor, "href", "") or safe_get(anchor, "xlink:href", "") or ""
            ).lower()
            anchor_id = (safe_get(anchor, "id", "") or "").lower()
            fragment_value = href_value.split("#", 1)[-1] if "#" in href_value else ""
            parent_name = (getattr(getattr(anchor, "parent", None), "name", "") or "").lower()
            is_superscript = parent_name == "sup"

            target_tag = (getattr(note_node, "name", "") or "").lower() if note_node else ""
            target_role = (safe_get(note_node, "role", "") or "").lower() if note_node else ""
            target_epub_type = ""
            if note_node is not None:
                for attr_name in ("epub:type", "epub-type", "type"):
                    value = safe_get(note_node, attr_name)
                    if value:
                        target_epub_type = str(value).lower()
                        break
            target_classes = (
                normalise_classes(safe_get(note_node, "class", [])) if note_node else []
            )

            if (
                role == "doc-noteref"
                or epub_type == "noteref"
                or "noteref" in classes
                or "footnote" in classes
                or "idfootnotelink" in classes
                or "footnote" in anchor_id
                or "footnote" in href_value
            ):
                return True

            anchor_text = (anchor.get_text(" ", strip=True) or "").strip()

            # --- Early-reject guards -----------------------------------------------
            # 1. Navigation links: anchor text with 3+ whitespace-separated tokens
            #    (e.g. "NOTE ON THE ILLUSTRATIONS") is a cross-reference / nav link,
            #    not a note reference.  Only short anchors (symbol, number, "*", "†")
            #    are valid note references.  Skip unless the anchor has an explicit
            #    noteref role/type that overrides the heuristic.
            has_explicit_noteref = bool(
                role == "doc-noteref"
                or epub_type == "noteref"
                or "noteref" in classes
                or "footnote" in classes
                or "idfootnotelink" in classes
                or "footnote" in anchor_id
            )
            if not has_explicit_noteref and anchor_text and len(anchor_text.split()) >= 3:
                return False

            # 2. Heading targets: when the resolved target node is a heading element
            #    (h1–h6) it is a section/chapter anchor, not a footnote target.
            #    Navigation TOC files use <a id="chapterId"> inside headings as jump
            #    targets; these must never be collected as footnotes.
            if target_tag in {"h1", "h2", "h3", "h4", "h5", "h6"}:
                if not has_explicit_noteref:
                    return False
            # Also reject when the target *anchor* lives inside a heading.
            if note_node is not None and note_node.name == "a":
                parent_of_target = getattr(note_node, "parent", None)
                if parent_of_target and getattr(parent_of_target, "name", "").lower() in {
                    "h1",
                    "h2",
                    "h3",
                    "h4",
                    "h5",
                    "h6",
                }:
                    if not has_explicit_noteref:
                        return False
            # -----------------------------------------------------------------------

            explicit_href_hint = bool(
                _runtime.re.search(r"(?:^|[#/_-])(foot|fn|note|rodape|rodapé)\w*", href_value)
            )
            explicit_target_hint = bool(
                target_tag in {"aside", "li"}
                or "footnote" in target_role
                or "footnote" in target_epub_type
                or any("footnote" in cls or "nota" in cls for cls in target_classes)
                or _runtime.re.search(r"(foot|fn|note|rodape|rodapé)\w*", fragment_value)
            )

            if explicit_target_hint or explicit_href_hint:
                return True
            if anchor_text:
                digits_only = "".join(ch for ch in anchor_text if ch.isdigit())
                if digits_only.isdigit():
                    # Do not treat any numeric internal link as footnote; this
                    # can remove legitimate section numbers (e.g. chapter starts with "1").
                    return is_superscript
            if target_text and any(
                token in target_text.lower() for token in ("nota", "footnote", "rodapé", "rodape")
            ):
                return True
            return False

        def safe_get(tag, key, default=None):
            """Safely access BeautifulSoup tag attributes even when attrs is missing."""
            if tag is None or not hasattr(tag, "attrs"):
                return default
            attrs = getattr(tag, "attrs", None)
            if not isinstance(attrs, dict):
                return default
            return attrs.get(key, default)

        def normalise_classes(value) -> List[str]:
            if not value:
                return []
            if isinstance(value, (list, tuple, set)):
                return [str(item).lower() for item in value]
            return [str(value).lower()]

        def extract_note_text(node) -> str:
            if node is None:
                return ""
            # If node is an anchor that is empty or contains only a numeric label
            # (i.e. it's a backlink target, not the actual footnote container),
            # use the parent element which holds the full note content.
            if node.name == "a" and node.parent:
                anchor_text = node.get_text(strip=True)
                is_numeric_label = anchor_text.isdigit() or (
                    anchor_text.startswith("[")
                    and anchor_text.endswith("]")
                    and anchor_text[1:-1].isdigit()
                )
                if not anchor_text or is_numeric_label:
                    node = node.parent
            # Fast-path: plain-text nodes are the common case and do not need a
            # descendant walk. This keeps large noteref-heavy documents under the
            # benchmark threshold without changing the fallback path for notes
            # that contain backlinks or embedded markup.
            if node is not None and getattr(node, "string", None) is not None:
                raw = str(node.string)
                return _runtime.TextProcessor.normalise_whitespace(raw)
            for backlink in node.find_all("a"):
                if backlink is None or not hasattr(backlink, "get"):
                    continue
                href = safe_get(backlink, "href", "")
                if href.startswith("#"):
                    backlink.decompose()
            raw = node.get_text(" ", strip=True)
            return _runtime.TextProcessor.normalise_whitespace(raw)

        def strip_leading_label(text: str, label: str) -> str:
            if not text:
                return ""
            cleaned = text.strip()
            label = (label or "").strip()

            # Extract only digits from label for comparison
            label_digits = "".join(ch for ch in label if ch.isdigit())

            if label_digits:
                # Try to remove various forms of number/label at the beginning
                candidates = [
                    label,  # Full label (e.g.: "[1]")
                    f"[{label}]",
                    f"({label})",
                    f"{label}.",
                    f"{label}:",
                    f"{label}-",
                    f"[{label_digits}]",
                    f"({label_digits})",
                    f"{label_digits}.",
                    f"{label_digits}:",
                    f"{label_digits}-",
                    label_digits,  # Just the number (e.g.: "1")
                ]

                lowered = cleaned.lower()
                for candidate in candidates:
                    candidate_clean = candidate.strip()
                    if not candidate_clean:
                        continue
                    if lowered.startswith(candidate_clean.lower()):
                        cleaned = cleaned[len(candidate_clean) :].lstrip(" .:-)–—")
                        break

            return cleaned.strip()

        # Build a one-time O(n) id→node index for the current document so that
        # every subsequent fragment lookup is O(1) instead of O(n) per anchor.
        # Without this index, a document with thousands of anchors (e.g. LOTR)
        # causes O(n²) behaviour that appears as an indefinite hang.
        _soup_id_index: Dict[str, any] = {}
        # Same index keyed per external document (built lazily, but only once per file).
        _external_id_index: Dict[str, Dict[str, any]] = {}

        # Casefolded set of the document's heading texts. A "footnote" whose
        # text is identical to a heading is spurious: it happens when a nav /
        # jump anchor points at a section heading (e.g. a "Maps" plate whose
        # only text is the title "Maps", or "NOTE ON THE ILLUSTRATIONS"),
        # which would otherwise be spoken as "Maps. footnote 1... Maps. end
        # of footnote...". Built once; used to reject such notes below.
        _heading_texts: set = set()

        all_anchors: List[any] = []
        for node in soup.descendants:
            if not hasattr(node, "get"):
                continue
            node_name = (getattr(node, "name", "") or "").lower()
            if node_name == "a":
                all_anchors.append(node)
            node_id = node.get("id")
            if node_id:
                _soup_id_index[str(node_id)] = node
            if node_name in {"h1", "h2", "h3", "h4", "h5", "h6"}:
                key = (node.get_text(" ", strip=True) or "").rstrip(".!?;:").casefold()
                if key:
                    _heading_texts.add(key)

        # Maps fragment id → the soup node to decompose during cleanup.
        # When the target node is a backlink anchor, its parent container is used
        # so that the full footnote block is removed (not just the anchor).
        cleanup_targets: Dict[str, any] = {}

        # Safety budget: bail out early if the document has an absurd number of
        # anchors to prevent indefinite hangs on pathological documents.
        _MAX_ANCHORS = 20_000
        if len(all_anchors) > _MAX_ANCHORS:
            import logging as _logging

            _logging.getLogger(__name__).warning(
                "Footnote collection skipped: document has %d anchors (limit %d). "
                "Returning document unchanged.",
                len(all_anchors),
                _MAX_ANCHORS,
            )
            return str(soup), []

        for anchor in list(all_anchors):
            if anchor is None or not hasattr(anchor, "get"):
                continue
            href = safe_get(anchor, "href", "") or safe_get(anchor, "xlink:href", "")
            fragment = normalise_fragment(href)
            if not fragment:
                continue

            # O(1) lookup via pre-built id index
            note_node = _soup_id_index.get(fragment)

            # If not found and href points to external file, try to load it
            if not note_node and external_file_resolver and "#" in href:
                external_file = href.split("#")[0]
                if external_file and external_file not in external_footnote_cache:
                    try:
                        external_html = external_file_resolver(external_file)
                        if external_html:
                            ext_bs = BeautifulSoup(external_html, "html.parser")
                            external_footnote_cache[external_file] = ext_bs
                            # Build id index for this external document once
                            _external_id_index[external_file] = {
                                tag.get("id"): tag
                                for tag in ext_bs.find_all(id=True)
                                if tag.get("id")
                            }
                    except Exception:
                        external_footnote_cache[external_file] = None

                external_soup = external_footnote_cache.get(external_file)
                if external_soup:
                    # Use pre-built index when available, fall back to .find() once
                    if external_file not in _external_id_index:
                        _external_id_index[external_file] = {
                            tag.get("id"): tag
                            for tag in external_soup.find_all(id=True)
                            if tag.get("id")
                        }
                    note_node = _external_id_index[external_file].get(fragment)

            # Determine the cleanup target before extract_note_text may decompose
            # the anchor.  When the target is a backlink anchor (contains only a
            # numeric label or is empty), the actual note content lives in its
            # parent container — remove that parent during cleanup so no duplicate
            # text remains in the document.
            if note_node is not None and note_node.name == "a":
                anchor_text = note_node.get_text(strip=True)
                is_numeric_label = anchor_text.isdigit() or (
                    anchor_text.startswith("[")
                    and anchor_text.endswith("]")
                    and anchor_text[1:-1].isdigit()
                )
                if not anchor_text or is_numeric_label:
                    cleanup_targets[fragment] = note_node.parent or note_node
                else:
                    cleanup_targets[fragment] = note_node
            elif note_node is not None:
                cleanup_targets[fragment] = note_node

            note_text = extract_note_text(note_node)
            if not note_text:
                continue
            if not looks_like_noteref(anchor, note_text, note_node):
                continue
            # Reject a note whose text is just a section heading of this
            # document (a nav/jump anchor mistaken for a noteref). Otherwise
            # an image-only plate like "Maps" is spoken as
            # "Maps. footnote 1... Maps. end of footnote...".
            if _heading_texts:
                _note_key = _runtime.TextProcessor.normalise_whitespace(note_text).rstrip(".!?;:").casefold()
                if _note_key in _heading_texts:
                    continue

            label = anchor.get_text(" ", strip=True)
            number_hint = "".join(ch for ch in label if ch.isdigit())
            if fragment in note_numbers:
                note_number = note_numbers[fragment]
            else:
                if number_hint.isdigit():
                    note_number = number_hint
                else:
                    note_number = str(len(note_numbers) + 1)
                note_numbers[fragment] = note_number
            cleaned_text = strip_leading_label(note_text, label)
            if not cleaned_text:
                cleaned_text = note_text.strip()

            marker_token = f"[[FOOTNOTE_{len(footnotes) + 1}]]"
            footnotes.append(
                {
                    "marker": marker_token,
                    "number": note_number,
                    "text": cleaned_text,
                    "original_text": _runtime.TextProcessor.normalise_whitespace(note_text),
                }
            )

            anchor.replace_with(marker_token)
            parent = anchor.parent
            if parent and parent.name == "sup" and not parent.get_text(strip=True):
                parent.decompose()

            processed_targets.append(fragment)

        # `Tag.extract()` maintains BeautifulSoup's parent/sibling links. Group
        # direct children by parent and remove them from back to front so each
        # list deletion is at the end of its parent's remaining child list.
        cleanup_by_parent: Dict[int, Tuple[any, set[int]]] = {}
        for fragment in set(processed_targets):
            node = cleanup_targets.get(fragment) or _soup_id_index.get(fragment)
            parent = getattr(node, "parent", None) if node is not None else None
            if parent is not None:
                parent_id = id(parent)
                if parent_id not in cleanup_by_parent:
                    cleanup_by_parent[parent_id] = (parent, set())
                cleanup_by_parent[parent_id][1].add(id(node))

        for parent, node_ids in cleanup_by_parent.values():
            direct_targets = [
                (index, child)
                for index, child in enumerate(parent.contents)
                if id(child) in node_ids
            ]
            for index, node in reversed(direct_targets):
                # `extract` updates BeautifulSoup's tree bookkeeping; providing
                # the known index avoids a second linear lookup per footnote.
                node.extract(_self_index=index)

        return str(soup), footnotes
