"""Chapter selection for the retained legacy CLI."""

from .cli_runtime_dependencies import ChapterStructureItem as ChapterStructureItem
from .cli_runtime_dependencies import List as List
from .cli_runtime_dependencies import Optional as Optional
from .cli_runtime_dependencies import Tuple as Tuple


class CLIChapterSelection:
    @staticmethod
    def _normalize_lookup(value: Optional[str], *, namespace) -> str:
        if not value:
            return ""
        normalised = namespace.unicodedata.normalize("NFKD", value)
        stripped = "".join(ch for ch in normalised if not namespace.unicodedata.combining(ch))
        return stripped.lower().strip()

    def _filter_structure_selection(
        self, items: List[ChapterStructureItem], selectors: Optional[List[str]]
    ) -> Tuple[List[ChapterStructureItem], bool]:
        if not selectors:
            return items, False

        normalised_selectors = [self._normalize_lookup(sel) for sel in selectors if sel]
        normalised_selectors = [sel for sel in normalised_selectors if sel]
        if not normalised_selectors:
            return items, False

        matched: List[ChapterStructureItem] = []
        for item in items:
            matched_selector = False
            for selector in normalised_selectors:
                if self._selector_matches(item, selector):
                    matched_selector = True
                    break

            if not matched_selector:
                continue

            source_key = (
                self._normalize_lookup(str(item.index)),
                self._normalize_lookup(item.display_name),
            )
            if source_key in matched:
                continue
            matched.append(item)

        if not matched:
            selector_preview = ", ".join(selectors)
            available = ", ".join(str(item.index) for item in items[:10])
            print(
                self.localization.t(
                    "selectors_not_found", selectors=selector_preview, available=available
                )
            )
            return [], True

        return matched, True

    def _filter_structure_range(
        self,
        items: List[ChapterStructureItem],
        start_selector: Optional[str],
        end_selector: Optional[str],
    ) -> Tuple[List[ChapterStructureItem], bool]:
        if not start_selector and not end_selector:
            return items, False

        start_selector = (start_selector or "").strip()
        end_selector = (end_selector or "").strip()
        if not start_selector:
            return items, False

        start_norm = self._normalize_lookup(start_selector)
        end_norm = self._normalize_lookup(end_selector) if end_selector else ""

        start_idx = self._find_selector_index(items, start_norm, 0)
        if start_idx is None:
            self._print_selector_not_found(items, start_selector)
            return [], True

        if not end_norm:
            return items[start_idx:], True

        end_idx = self._find_selector_index(items, end_norm, start_idx)
        if end_idx is None:
            self._print_selector_not_found(items, end_selector)
            return [], True

        return items[start_idx : end_idx + 1], True

    def _selector_matches(self, item: ChapterStructureItem, selector_norm: str) -> bool:
        if not selector_norm:
            return False
        index_str = str(item.index)
        index_norm = self._normalize_lookup(index_str)
        base_index_norm = self._normalize_lookup(index_str.split(".", 1)[0]) if index_str else ""
        display_norm = self._normalize_lookup(item.display_name)
        chapter_name_norm = self._normalize_lookup(getattr(item.chapter, "name", ""))

        if selector_norm == index_norm:
            return True
        if selector_norm == base_index_norm and base_index_norm:
            return True
        if index_norm and selector_norm and index_norm.startswith(f"{selector_norm}."):
            return True
        if any(ch.isalpha() for ch in selector_norm):
            if selector_norm in display_norm or selector_norm in chapter_name_norm:
                return True
        return False

    def _find_selector_index(
        self,
        items: List[ChapterStructureItem],
        selector_norm: str,
        start_at: int,
    ) -> Optional[int]:
        for idx in range(max(start_at, 0), len(items)):
            if self._selector_matches(items[idx], selector_norm):
                return idx
        return None

    def _print_selector_not_found(self, items: List[ChapterStructureItem], selector: str) -> None:
        available = ", ".join(str(item.index) for item in items[:10])
        print(self.localization.t("selectors_not_found", selectors=selector, available=available))

    @staticmethod
    def _parse_range_selector(value: Optional[str]) -> Optional[Tuple[str, str]]:
        if not value:
            return None
        raw = str(value).strip()
        if not raw:
            return None
        separator_index = -1
        separator_width = 1
        for token in ("..", ":", ","):
            index = raw.find(token)
            if index >= 0 and (separator_index < 0 or index < separator_index):
                separator_index = index
                separator_width = len(token)
        if separator_index < 0:
            return None
        start = raw[:separator_index].strip()
        end = raw[separator_index + separator_width :].strip()
        if not start or not end:
            return None
        return start, end

    @staticmethod
    def _expand_selector_args(values: Optional[List[str]]) -> List[str]:
        """Allow comma/semicolon separated selectors in a single flag use."""
        expanded: List[str] = []
        for raw in values or []:
            if raw is None:
                continue
            text = str(raw)
            for part in text.replace(";", ",").split(","):
                cleaned = part.strip()
                if cleaned:
                    expanded.append(cleaned)
        return expanded
