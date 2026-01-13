#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Simplified EBook to Audiobook Converter - SOLID principles applied
Reduced from 564 to ~100 lines while maintaining all functionality
"""

import argparse
import asyncio
import copy
import glob
import os
import re
import shutil
import sys
import time
import traceback
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional, Set, Tuple
from urllib.parse import unquote

try:  # Optional dependency for shell tab completion
    import argcomplete  # type: ignore
    from argcomplete.completers import ChoicesCompleter, FilesCompleter
except ImportError:  # pragma: no cover - argcomplete is optional
    argcomplete = None
    ChoicesCompleter = None
    FilesCompleter = None

# Local imports
from src.benchmark_profile import apply_benchmark_profile
from src.chapter_utils import deduplicate_chapters_by_content
from src.config import AppConfig, ConversionConfig
from src.converter import AudioConverter, ConversionResult
from src.ebook_reader import Chapter, EbookReader, FormattingSegment, TextProcessor
from src.i18n import get_localization
from src.language import (
    LanguageDetector,
    LanguageMarkup,
    LanguageProfile,
    get_language_detector,
)
from src.text_formatting import TextFormattingProcessor
from src.ui.menu import MenuInterface
from src.utils import FileManager, resolve_cache_root


@dataclass
class ChapterStructureItem:
    chapter: Chapter
    index: str
    main_title: Optional[str]
    sub_title: Optional[str]
    preview: Optional[str]
    display_name: str
    text_override: Optional[str] = None
    speak_heading: bool = True


class ConverterApplication:
    """Main application class following SRP"""

    PREVIEW_WORD_LIMIT = 30
    FOOTNOTE_CONTEXT_WORDS = 8
    SUPPORTED_INPUT_SUFFIXES = (".epub", ".pdf")

    def __init__(self):
        self.localization = get_localization()
        self.config = AppConfig()
        self.menu = MenuInterface(localization=self.localization)
        self.converter = AudioConverter(localization=self.localization)
        self.cache_root = resolve_cache_root()
        self.language_detector: LanguageDetector = get_language_detector()
        self.language_markup = LanguageMarkup(self.language_detector)
        self.language_profile: Optional[LanguageProfile] = None
        self._interactive_mode = True
        self._footnote_summary_printed = False

    @staticmethod
    def _resolve_verbose(args: argparse.Namespace) -> bool:
        raw = getattr(args, "verbose", None)
        if raw is None:
            return True
        return bool(raw)

    @staticmethod
    def _resolve_formatting_cues(args: argparse.Namespace, default: bool = True) -> bool:
        raw = getattr(args, "formatting_cues", None)
        if raw is None:
            return default
        return bool(raw)

    @staticmethod
    def _apply_no_parallel_env(args: argparse.Namespace) -> None:
        if getattr(args, "no_parallel", False):
            os.environ["CHAPTER_PARALLEL_COUNT"] = "1"
            os.environ["CHAPTER_PARALLEL_MAX"] = "1"
            os.environ["EDGE_ENABLE_PARALLEL"] = "false"

    def run(self, args: argparse.Namespace) -> int:
        """Entry point that orchestrates optional batch conversion."""
        if getattr(args, "command", None) == "clear_cache":
            return self._handle_clear_cache()

        verbose = self._resolve_verbose(args)
        hardware_profile = None
        try:
            from src.hardware_detector import HardwareDetector

            hardware_profile = HardwareDetector.detect()
            HardwareDetector.apply_optimizations(hardware_profile)
            if verbose:
                HardwareDetector.print_profile(hardware_profile, verbose=True)
        except Exception:
            hardware_profile = None

        self._apply_no_parallel_env(args)

        targets, batch_requested = self._resolve_batch_targets(args)
        if not targets:
            print("⚠️ Nenhum arquivo EPUB/PDF encontrado para converter.")
            return 1

        if len(targets) == 1 and not batch_requested:
            args.input_file = str(targets[0])
            return self._run_single_conversion(args, hardware_profile=hardware_profile)

        return self._run_batch(args, targets, hardware_profile=hardware_profile)

    def _resolve_batch_targets(self, args: argparse.Namespace) -> Tuple[List[Path], bool]:
        """Resolve positional + batch inputs into a deduplicated ordered list of books."""
        requested_batch = any(
            bool(getattr(args, attr, None))
            for attr in ("extra_inputs", "batch_inputs", "batch_manifest")
        )
        sources: List[str] = []
        positional: List[str] = []
        primary = getattr(args, "input_file", None)
        if primary:
            positional.append(str(primary))
        positional.extend(getattr(args, "extra_inputs", None) or [])
        sources.extend(positional)

        batch_inputs = getattr(args, "batch_inputs", None) or []
        sources.extend(batch_inputs)
        sources.extend(self._read_batch_manifest(getattr(args, "batch_manifest", None)))

        targets: List[Path] = []
        seen: Set[str] = set()
        for raw in sources:
            for expanded in self._expand_batch_source(raw):
                for file_path in self._flatten_source_to_files(expanded):
                    key = self._canonical_path_key(file_path)
                    if key in seen:
                        continue
                    seen.add(key)
                    targets.append(file_path)
        return targets, requested_batch

    def _expand_batch_source(self, raw: str) -> List[Path]:
        """Expand globs/user paths into concrete Path objects."""
        pattern = os.path.expanduser(raw)
        matches = [Path(match) for match in glob.glob(pattern)]
        if matches:
            return matches
        return [Path(pattern)]

    def _flatten_source_to_files(self, path: Path) -> List[Path]:
        """Return a list of valid input files from a file or directory."""
        resolved = path.expanduser()
        try:
            exists = resolved.exists()
        except OSError:
            exists = False

        if not exists:
            print(self.localization.t("file_not_found", path=resolved))
            return []

        if resolved.is_file():
            if resolved.suffix.lower() in self.SUPPORTED_INPUT_SUFFIXES:
                return [resolved]
            print(f"⚠️ Ignorando arquivo não suportado: {resolved.name}")
            return []

        if resolved.is_dir():
            files = [
                candidate
                for candidate in sorted(resolved.rglob("*"))
                if candidate.is_file() and candidate.suffix.lower() in self.SUPPORTED_INPUT_SUFFIXES
            ]
            if not files:
                print(f"⚠️ Nenhum EPUB/PDF encontrado em {resolved}")
            return files

        print(f"⚠️ Caminho inválido: {resolved}")

        return []

    @staticmethod
    def _canonical_path_key(path: Path) -> str:
        try:
            return str(path.resolve())
        except OSError:
            return str(path)

    def _run_batch(
        self,
        args: argparse.Namespace,
        targets: List[Path],
        *,
        hardware_profile=None,
    ) -> int:
        """Execute sequential conversions for multiple books."""
        total = len(targets)
        stop_on_error = bool(getattr(args, "batch_stop_on_error", False))
        successes = 0
        exit_code = 0

        for index, target in enumerate(targets, start=1):
            self._print_batch_header(target, index, total)
            single_args = copy.deepcopy(args)
            single_args.input_file = str(target)
            single_args.extra_inputs = []
            single_args.batch_inputs = []
            single_args.batch_manifest = None
            result = self._run_single_conversion(single_args, hardware_profile=hardware_profile)
            if result == 0:
                successes += 1
            else:
                exit_code = exit_code or result or 1
                if stop_on_error:
                    print("🛑 Processamento interrompido após falha.")
                    break

        print(f"\n📚 Batch concluído: {successes}/{total} livro(s) com sucesso.")
        return exit_code

    @staticmethod
    def _read_batch_manifest(manifest: Optional[str]) -> List[str]:
        if not manifest:
            return []
        manifest_path = Path(manifest).expanduser()
        if not manifest_path.exists():
            print(f"⚠️ Arquivo de lista não encontrado: {manifest_path}")
            return []
        entries: List[str] = []
        try:
            with manifest_path.open("r", encoding="utf-8") as handle:
                for line in handle:
                    stripped = line.strip()
                    if not stripped or stripped.startswith("#"):
                        continue
                    entries.append(stripped)
        except OSError as exc:
            print(f"⚠️ Falha ao ler lista de batch ({manifest_path}): {exc}")
        return entries

    @staticmethod
    def _print_batch_header(target: Path, index: int, total: int) -> None:
        divider = "=" * 60
        print(f"\n{divider}")
        print(f"📘 Livro {index}/{total}: {target.name}")
        print(f"{divider}")

    def _run_single_conversion(
        self,
        args: argparse.Namespace,
        *,
        hardware_profile=None,
    ) -> int:
        """Main application entry point"""
        conversion_start = time.time()
        try:
            if hardware_profile is None:
                from src.hardware_detector import HardwareDetector

                hardware_profile = HardwareDetector.detect()
                HardwareDetector.apply_optimizations(hardware_profile)
                verbose = self._resolve_verbose(args)
                if verbose:
                    HardwareDetector.print_profile(hardware_profile, verbose=True)
            self._apply_no_parallel_env(args)
            self.converter.hardware_profile = hardware_profile

            # Validate input
            input_path = Path(getattr(args, "input_file", "")).expanduser()
            if not input_path.exists():
                print(self.localization.t("file_not_found", path=input_path))
                return 1
            suffix = input_path.suffix.lower()
            if suffix not in {".epub", ".pdf"}:
                friendly = suffix or "(sem extensão)"
                print(f"❌ Formato não suportado: {friendly}. Envie um arquivo .epub ou .pdf.")
                return 1

            # Load ebook
            reader = EbookReader(str(input_path))

            # Show structure only
            if args.show_structure:
                self._show_structure(reader)
                return 0

            # Prepare structured chapters for conversion
            structure_items = self._generate_structure_items(reader)

            range_start = getattr(args, "from_chapter_to_end", None)
            range_span = getattr(args, "from_chapter_to_chapter", None)
            if range_start and range_span:
                print("❌ Use apenas --from-chapter-to-end ou --from-chapter-to-chapter.")
                return 1
            if range_span:
                parsed = self._parse_range_selector(range_span)
                if not parsed:
                    print(
                        "❌ Intervalo inválido. Use 'A..B' (ex.: 5.1..7.3) no "
                        "--from-chapter-to-chapter."
                    )
                    return 1
                structure_items, filtered = self._filter_structure_range(
                    structure_items, parsed[0], parsed[1]
                )
                if filtered and not structure_items:
                    return 1
            elif range_start:
                structure_items, filtered = self._filter_structure_range(
                    structure_items, range_start, None
                )
                if filtered and not structure_items:
                    return 1

            selectors: List[str] = []
            selectors.extend(self._expand_selector_args(getattr(args, "chapters", []) or []))
            selectors.extend(self._expand_selector_args(getattr(args, "sections", []) or []))

            structure_items, filtered = self._filter_structure_selection(
                structure_items, selectors if selectors else None
            )
            if filtered and not structure_items:
                return 1

            # **NEW**: Use CacheManager for better cache handling
            from src.cache_manager import CacheManager

            cache_manager = CacheManager(cache_dir=self.cache_root)

            if getattr(args, "clear_cache", False):
                input_path = (
                    Path(getattr(args, "input_file", ""))
                    if getattr(args, "input_file", None)
                    else None
                )
                if input_path:
                    display_name = reader.title or input_path.stem
                    cleared = cache_manager.clear_cache(input_path, title=reader.title)
                    if cleared:
                        print(f"🗑️ Cache limpo para: {display_name}")
                    else:
                        print(f"⚠️ Nenhum cache encontrado para: {display_name}")
                    cache_manager.clear_checkpoint(input_path)
                else:
                    cleared = cache_manager.clear_cache()
                    if cleared:
                        print("🗑️ Todo o cache foi limpo")
                    else:
                        print("⚠️ Nenhum cache encontrado para remover")

            cache_dir = self._resolve_cache_dir(reader)
            cache_dir.mkdir(parents=True, exist_ok=True)
            setattr(args, "cache_dir", cache_dir)

            # Corrigir diretório temporário para usar .cache/{nome do livro}
            book_name = Path(args.input_file).stem
            temp_dir = self.cache_root / book_name

            if getattr(args, "no_cache", False):
                # Limpar completamente o diretório .cache
                if self.cache_root.exists():
                    shutil.rmtree(self.cache_root)
                self.cache_root.mkdir(exist_ok=True)
                print("🗑️ Diretório .cache limpo devido ao uso de --no-cache")

            # Garantir que o diretório temporário esteja dentro de .cache
            book_name = Path(args.input_file).stem
            temp_dir = self.cache_root / book_name
            temp_dir.mkdir(parents=True, exist_ok=True)

            # Cache automático: conversão retoma automaticamente se arquivos .txt existirem
            # Não precisa mais perguntar ao usuário - sistema detecta automaticamente

            self._interactive_mode = bool(getattr(args, "menu", False))

            # Prepare language profile AFTER displaying initial metadata
            verbose = self._resolve_verbose(args)
            self.language_profile = self._prepare_language_profile(
                reader, structure_items, verbose=verbose
            )

            # Update display with language detection results
            self._update_metadata_display_language()

            # Configure conversion (only once)
            config = self._get_conversion_config(args, reader)
            if not config:
                return 1
            config.verbose = self._resolve_verbose(args)
            self._announce_footnote_mode(config)

            # Configurar o diretório temporário usando o método existente com `config`
            temp_dir = self.converter._setup_temp_directory(config)

            print(f"📁 Cache: {temp_dir}")
            if temp_dir.exists() and (temp_dir / "text").exists():
                txt_files = list((temp_dir / "text").glob("*_tts_input.txt"))
                if txt_files:
                    print(f"♻️ Cache detectado: {len(txt_files)} capítulos processados")
                    print("   Capítulos já convertidos serão pulados automaticamente")

            structure_items = self._apply_text_transforms(structure_items, config, reader)
            self._apply_structure_to_reader(reader, structure_items)

            # Convert
            result = asyncio.run(self.converter.convert(reader, config))

            elapsed = time.time() - conversion_start
            print(f"⏱️ Tempo total de conversão: {self._format_hms(elapsed)}")

            if isinstance(result, ConversionResult):
                return 0 if result.success else 1
            if isinstance(result, int):
                return result
            if isinstance(result, bool):
                return 0 if result else 1
            return 0

        except Exception as e:
            traceback.print_exc()
            print(self.localization.t("unexpected_error", error=e))
            return 1

    @staticmethod
    def _format_hms(seconds: float) -> str:
        total = max(0, int(seconds or 0))
        hours, rem = divmod(total, 3600)
        minutes, secs = divmod(rem, 60)
        parts: list[str] = []
        if hours:
            parts.append(f"{hours:02d}h")
        if minutes or hours:
            parts.append(f"{minutes:02d}m")
        parts.append(f"{secs:02d}s")
        return " ".join(parts)

    def _generate_structure_items(self, reader: EbookReader) -> List[ChapterStructureItem]:
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

        structure_items: List[ChapterStructureItem] = []
        division_counters: Dict[int, int] = {}
        fallback_division = 0
        fallback_counter = 0
        fallback_label: Optional[str] = None

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
            if self._should_skip_chapter(chapters, i, toc_map):
                continue

            href_key = self._normalize_href(str(getattr(chapter, "source_path", "")))
            toc_entries = self._resolve_toc_entries(href_key, toc_map)

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
                ChapterStructureItem(
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

        return structure_items

    def _count_toc_chapters(self, reader: EbookReader) -> int:
        """Count expected chapters from TOC (top-level divisions)"""
        get_toc = getattr(reader, "get_toc", None)
        if not callable(get_toc):
            return 0

        try:
            toc_entries = list(get_toc() or [])
        except Exception:
            return 0

        # Count only top-level entries (divisions)
        count = 0

        def walk(entries, is_top_level=True):
            nonlocal count
            for entry in entries:
                if is_top_level:
                    count += 1
                # Recursively count children
                if hasattr(entry, "children") and entry.children:
                    walk(entry.children, is_top_level=False)

        walk(toc_entries, is_top_level=True)
        return count

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
            print(f"\nℹ️  TOC: {expected_count} capítulos | Detectados: {actual_count} capítulos")
            if actual_count < expected_count:
                print(f"💡 Diferença: {diff} (provavelmente folha de rosto ou capa ignorada)")
            return chapters, False

        # Significant count mismatch - attempt auto-correction
        print(
            f"\n⚠️  VALIDAÇÃO: TOC indica {expected_count} capítulos, mas foram detectados {actual_count}"
        )

        # If we removed duplicates and that caused the mismatch, restore original
        if duplicates_removed > 0 and (actual_count + duplicates_removed) == expected_count:
            print(
                f"🔄 Auto-correção: restaurando {duplicates_removed} capítulo(s) removido(s) como duplicata"
            )
            print("💡 Motivo: deduplicação causou perda de capítulos válidos")

            # Return the chapters WITHOUT deduplication
            # Note: we need to re-generate or get the original list
            # For now, we'll signal that deduplication should be skipped
            return chapters, True

        # If actual > expected, deduplication might help
        if actual_count > expected_count:
            print(f"💡 Detectados {actual_count - expected_count} capítulos a mais que o esperado")
            print("✓ Mantendo resultado atual (possível subcapítulos no TOC)")
        else:
            print(f"⚠️  Faltam {expected_count - actual_count} capítulos!")
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
                ChapterStructureItem(
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

            normalized = re.sub(r"\s+", " ", title.strip().lower())

            # Headings appear at line start - look for title after newline or at text start
            # Search in full text and find first match >= cursor to avoid ^ matching substring start
            pattern = r"(^|\n)\s*" + re.escape(normalized) + r"\b"
            idx = -1
            for match in re.finditer(pattern, lowered):
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

    def _apply_structure_to_reader(
        self, reader: EbookReader, structure_items: List[ChapterStructureItem]
    ) -> None:
        """Replace reader chapters with structured output for conversion"""

        if not reader.book:
            return

        new_chapters: List[Chapter] = []
        formatter = TextFormattingProcessor()

        for item in structure_items:
            chapter = item.chapter
            formatting_segments = getattr(chapter, "formatting_segments", None)
            if getattr(chapter, "footnotes", None):
                formatting_segments = None

            # Determine text content and ensure headings are spoken
            final_text = item.text_override if item.text_override is not None else chapter.text
            final_text = final_text or ""

            heading_text = self._build_heading_text(item)
            if heading_text:
                normalized_body = final_text.lstrip()
                if not normalized_body.lower().startswith(heading_text.lower()):
                    final_text = f"{heading_text}\n\n{normalized_body}"
                else:
                    final_text = normalized_body
            else:
                final_text = final_text.lstrip()

            speech_text = formatter.to_audible_text(final_text, formatting_segments)

            new_chapters.append(
                Chapter(
                    index=item.index,
                    name=item.display_name,
                    source_path=chapter.source_path,
                    text=final_text,
                    level=getattr(chapter, "level", 1),
                    raw_html=getattr(chapter, "raw_html", None),
                    formatting_segments=formatting_segments,
                    footnotes=getattr(chapter, "footnotes", None),
                    speech_text=speech_text,
                )
            )

        reader.book.chapters = new_chapters

    def _build_heading_text(self, item: ChapterStructureItem) -> Optional[str]:
        """Return a clean heading string that should be spoken before the chapter."""

        if not getattr(item, "speak_heading", True):
            return None

        def normalize(value: Optional[str]) -> str:
            return re.sub(r"\s+", " ", value or "").strip()

        main = normalize(item.main_title)
        sub = normalize(item.sub_title)
        parts: List[str] = []

        if sub:
            if main and sub.lower().startswith(main.lower()):
                parts.append(sub)
            else:
                if main:
                    parts.append(main)
                parts.append(sub)
        elif main:
            parts.append(main)
        else:
            fallback = normalize(item.display_name)
            if fallback:
                parts.append(fallback)

        heading = "\n".join(parts).strip()
        return heading or None

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
            chapter_footnotes = getattr(chapter, "footnotes", None)
            text_source = (
                item.text_override
                if item.text_override is not None
                else getattr(chapter, "text", "")
            )
            if item.text_override is not None:
                raw_html = None

            # Reutiliza o texto já enriquecido com notas quando o modo é inline
            if footnote_mode == "inline" and chapter_footnotes:
                raw_html = None

            chapter_label = str(
                item.display_name
                or getattr(chapter, "name", None)
                or (item.index if isinstance(item.index, str) else None)
                or ""
            )
            # Mostrar número ordinal (1/179) + identificador estrutural (4.23)
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
                markup_with_markers, footnotes = TextProcessor.inject_footnotes(
                    raw_html,
                    mode=footnote_mode,
                    context_words=context_words,
                )
                text_with_formatting, formatting_segments = (
                    TextProcessor.html_to_plain_text_with_formatting(markup_with_markers)
                )
                updated_text = TextProcessor._render_footnotes(
                    text_with_formatting,
                    footnotes,
                    mode=footnote_mode,
                    context_words=context_words,
                    phrases=phrases,
                )
                updated_text = TextProcessor.add_pause_before_dash(updated_text)
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
                            FormattingSegment(
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
                        updated_text = TextProcessor._render_footnotes(
                            text_source,
                            footnotes,
                            mode=footnote_mode,
                            context_words=context_words,
                            phrases=phrases,
                        )
                    else:
                        updated_text = text_source
                formatting_segments = getattr(chapter, "formatting_segments", None)
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
                            FormattingSegment(
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
            processor = TextFormattingProcessor()
            processor.apply_inline_formatting(final_text)
            speech_text = processor.strip_inline_markdown(final_text)

            # **NEW**: Aplicar detecção automática de idioma se habilitado
            if getattr(config, "use_language_detection", True):
                try:
                    from src.language import LanguageMarkup

                    markup = LanguageMarkup()
                    speech_text = markup.annotate(speech_text, primary_language)
                except (ImportError, Exception) as e:
                    # Falha silenciosa - continua sem detecção
                    if config.verbose:
                        print(f"⚠️ Detecção de idioma desativada: {e}")

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
        for data in processed_data:
            index = getattr(data["item"], "index", None)
            if isinstance(index, str):
                index_to_data[index] = data

        children_map: dict[str, list[dict]] = {}
        for data in processed_data:
            index = getattr(data["item"], "index", None)
            if not isinstance(index, str) or "." not in index:
                continue
            parent_index = index.rsplit(".", 1)[0]
            parent_data = index_to_data.get(parent_index)
            if parent_data is None and parent_index:
                parent_data = index_to_data.get(f"{parent_index}.0")
            if parent_data is data:
                continue
            if parent_data is None:
                continue
            children_map.setdefault(parent_index, []).append(data)

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

        for data in processed_data:
            if data.get("skip"):
                continue
            text = data["text"].strip()
            if not text:
                continue

            # **NEW**: Preserve chapters with .0 index (main chapters) even if small
            item = data["item"]
            is_main_chapter = item.index.endswith(".0")

            # **NEW**: Skip length filter for main chapters to preserve all content
            if not is_main_chapter and len(text) < 20:
                continue

            lines = data["lines"]

            text_signature = self._text_signature(text)

            # **NEW**: Less aggressive filtering for main chapters (.0)
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

    def _prepare_language_profile(
        self,
        reader: EbookReader,
        items: List[ChapterStructureItem],
        verbose: bool = False,
    ) -> LanguageProfile:
        print(self.localization.t("language_profile_start"), flush=True)
        sample_texts: List[str] = []

        # **FIXED**: Melhorar detecção de idioma para livros com capítulos vazios/curtos
        # Coletar textos até ter pelo menos 2000 chars ou 20 capítulos
        total_chars = 0
        items_checked = 0
        max_items = min(20, len(items))  # Até 20 capítulos
        min_chars = 2000  # Mínimo 2000 chars para boa detecção

        total_items = len(items)
        if total_items <= max_items:
            sample_positions = list(range(total_items))
        else:
            sample_positions = sorted(
                {round(i * (total_items - 1) / (max_items - 1)) for i in range(max_items)}
            )

        for pos in sample_positions:
            if pos >= len(items):
                continue
            item = items[pos]
            source_text = (
                item.text_override
                if item.text_override is not None
                else getattr(item.chapter, "text", "")
            )
            if not source_text and getattr(item.chapter, "raw_html", None):
                source_text = TextProcessor.html_to_plain_text(item.chapter.raw_html)
            if source_text and len(source_text.strip()) > 10:  # Ignorar textos muito pequenos
                sample_texts.append(source_text)
                total_chars += len(source_text)
                items_checked += 1

                # Parar se já temos caracteres suficientes
                if total_chars >= min_chars and items_checked >= 3:
                    break

        if verbose:
            print(
                f"🔍 [VERBOSE] Idioma: analisados {items_checked} capítulos, {total_chars} caracteres"
            )

        ascii_ratio = self._ascii_ratio(sample_texts)
        language_votes = self._collect_language_votes(sample_texts)
        profile = self.language_detector.detect_profile(sample_texts)
        profile = self._rebalance_language_profile(profile, ascii_ratio, language_votes)

        if not profile.languages or not profile.primary:
            languages = self._prompt_for_languages(reader)
            primary = languages[0] if languages else None
            return LanguageProfile(
                primary=primary,
                languages=languages,
                predictions=[],
                analysed_chars=sum(len(text) for text in sample_texts),
            )

        return profile

    @staticmethod
    def _ascii_ratio(texts: List[str]) -> float:
        joined = " ".join(texts)
        if not joined:
            return 0.0
        ascii_chars = sum(1 for ch in joined if 32 <= ord(ch) <= 126)
        return ascii_chars / max(len(joined), 1)

    def _collect_language_votes(self, sample_texts: List[str]) -> dict[str, float]:
        votes: dict[str, float] = {}
        detector = self.language_detector
        for sample in sample_texts:
            if not sample or len(sample.strip()) < 20:
                continue
            local_profile = detector.detect_profile([sample])
            if not local_profile.predictions:
                continue
            weight = len(sample)
            for prediction in local_profile.predictions:
                code = ConverterApplication._normalise_lang_code(prediction.code)
                if not code:
                    continue
                votes[code] = votes.get(code, 0.0) + (prediction.probability * weight)
        return votes

    @staticmethod
    def _normalise_lang_code(code: Optional[str]) -> str:
        if not code:
            return ""
        return code.split("-", 1)[0].lower()

    def _rebalance_language_profile(
        self,
        profile: LanguageProfile,
        ascii_ratio: float,
        language_votes: dict[str, float],
    ) -> LanguageProfile:
        if not profile.predictions:
            return profile

        top_prediction = profile.predictions[0]
        top_code = self._normalise_lang_code(top_prediction.code)
        en_prediction = next(
            (pred for pred in profile.predictions if self._normalise_lang_code(pred.code) == "en"),
            None,
        )

        if (
            en_prediction
            and top_code != "en"
            and ascii_ratio >= 0.65
            and (top_prediction.probability - en_prediction.probability) <= 0.22
        ):
            languages = ["en"] + [
                lang for lang in profile.languages if self._normalise_lang_code(lang) != "en"
            ]
            return LanguageProfile(
                primary="en",
                languages=languages,
                predictions=profile.predictions,
                analysed_chars=profile.analysed_chars,
            )
        total_votes = sum(language_votes.values())
        if total_votes > 0:
            best_code, best_votes = max(language_votes.items(), key=lambda item: item[1])
            vote_ratio = best_votes / total_votes
            normalized_primary = self._normalise_lang_code(profile.primary)
            if vote_ratio >= 0.55 and best_code and normalized_primary != best_code:
                languages = [best_code] + [
                    lang
                    for lang in profile.languages
                    if self._normalise_lang_code(lang) != best_code
                ]
                return LanguageProfile(
                    primary=best_code,
                    languages=languages,
                    predictions=profile.predictions,
                    analysed_chars=profile.analysed_chars,
                )
        return profile

    def _prompt_for_languages(self, reader: EbookReader) -> List[str]:
        default_language = self._infer_language_from_metadata(reader)
        fallback_language = default_language or (
            "pt" if self.localization.language == "pt" else "en"
        )

        if not self._interactive_mode or not sys.stdin.isatty():
            return [fallback_language]

        try:
            raw = input(self.localization.t("language_prompt", default=fallback_language))
        except EOFError:
            return [fallback_language]

        if not raw.strip():
            return [fallback_language]

        languages = [self._normalise_language_code(part) for part in raw.split(",")]
        languages = [lang for lang in languages if lang]
        if not languages:
            languages = [fallback_language]
        return languages

    def _infer_language_from_metadata(self, reader: EbookReader) -> Optional[str]:
        title = (reader.title or "").lower()
        if any(token in title for token in ("portug", "brasil", "brasile")):
            return "pt"
        if any(token in title for token in ("english", "angl", "ingl")):
            return "en"
        return None

    @staticmethod
    def _normalise_language_code(raw: str) -> str:
        if not raw:
            return ""
        clean = raw.strip().lower()
        if not clean:
            return ""
        return clean.split("-", 1)[0]

    def _apply_language_preferences(self, config: ConversionConfig) -> None:
        profile = self.language_profile
        fallback_lang = self.localization.language or "pt"
        if profile is None:
            profile = LanguageProfile(
                primary=config.primary_language,
                languages=[config.primary_language],
                predictions=[],
                analysed_chars=0,
            )
        elif not profile.is_confident:
            profile = LanguageProfile(
                primary=fallback_lang,
                languages=[fallback_lang],
                predictions=profile.predictions,
                analysed_chars=profile.analysed_chars,
            )

        languages = [lang for lang in profile.languages if lang and lang not in {"unknown", "auto"}]
        if not languages and profile.primary and profile.primary not in {"unknown", "auto"}:
            languages = [profile.primary]
        if not languages:
            languages = (
                [config.primary_language]
                if config.primary_language and config.primary_language != "auto"
                else []
            )

        primary_language = profile.primary if profile.primary not in {None, "", "unknown"} else None
        if not primary_language and languages:
            primary_language = languages[0]
        if not primary_language or primary_language in {"", "unknown"}:
            primary_language = (
                config.primary_language
                if config.primary_language not in {None, "", "auto"}
                else "auto"
            )

        config.primary_language = primary_language or "auto"
        config.languages = languages or (
            [config.primary_language] if config.primary_language not in {None, "auto"} else []
        )

        voice_auto_raw = config.extra.get("voice_auto", False)

        def _to_bool(value) -> bool:
            if isinstance(value, bool):
                return value
            if value is None:
                return False
            text = str(value).strip().lower()
            if text in {"1", "true", "yes", "on"}:
                return True
            if text in {"0", "false", "no", "off"}:
                return False
            return bool(text)

        voice_auto = _to_bool(voice_auto_raw)
        if primary_language and (not config.voice or voice_auto):
            suggested_voice = self.config.voice_configs.get_voice(config.engine, primary_language)
            if suggested_voice:
                config.voice = suggested_voice
        if voice_auto and not config.voice:
            for lang in languages:
                suggested_voice = self.config.voice_configs.get_voice(config.engine, lang)
                if suggested_voice:
                    config.voice = suggested_voice
                    break

        language_voice_map = self.config.voice_configs.build_language_voice_map(
            config.engine,
            config.languages
            or ([config.primary_language] if config.primary_language not in {None, "auto"} else []),
            config.voice,
            primary_language=config.primary_language,
        )

        config.language_voices = language_voice_map

        if not self._voice_supports_multilingual(config.engine, config.voice):
            if primary_language and primary_language not in {"", "unknown", "auto"}:
                config.languages = [primary_language]
            else:
                fallback = fallback_lang if fallback_lang not in {"", "unknown"} else None
                config.primary_language = fallback or "auto"
                config.languages = (
                    [config.primary_language] if config.primary_language not in {"", "auto"} else []
                )
            config.language_voices = {}

    @staticmethod
    def _remove_inline_footnotes(text: str) -> str:
        if not text:
            return ""
        pattern = re.compile(
            r"\s*nota de rodapé\s+\d+:[^\n]*?fim da nota de rodapé\s+\d+\s*",
            re.IGNORECASE,
        )
        cleaned = pattern.sub(" ", text)
        return re.sub(r"\s+", " ", cleaned).strip()

    @staticmethod
    def _strip_book_title_prefix(text: str, book_title: Optional[str]) -> str:
        if not text:
            return ""
        if not book_title:
            return text.lstrip()

        title = str(book_title).strip()
        if not title:
            return text.lstrip()

        cleaned = text.lstrip()
        pattern = re.compile(
            rf"^(?:{re.escape(title)}[\s,.:;\-–—“”\"']*)+",
            re.IGNORECASE,
        )
        cleaned = pattern.sub("", cleaned, count=1)

        def normalise(value: str) -> str:
            value = value or ""
            value = unicodedata.normalize("NFKD", value).casefold()
            return "".join(ch for ch in value if ch.isalnum())

        title_norm = normalise(title)
        lines = cleaned.splitlines()
        while lines and title_norm and normalise(lines[0]) == title_norm:
            lines.pop(0)
        cleaned = "\n".join(lines).lstrip()
        return cleaned

    @staticmethod
    def _voice_supports_multilingual(engine: Optional[str], voice: Optional[str]) -> bool:
        engine_name = (engine or "").lower()
        voice_name = (voice or "").lower()
        if not voice_name:
            return False
        if engine_name == "edge":
            return "multilingual" in voice_name
        if engine_name == "coqui":
            return "xtts" in voice_name or "multi" in voice_name
        if engine_name == "piper":
            return True
        return False

    def _prepare_chapter_text(
        self, raw_text: str, *, display_name: str, book_title: Optional[str]
    ) -> str:
        """Normalise chapter text to ensure parity between cache and audio."""
        text = raw_text or ""
        text = text.replace("\r\n", "\n").replace("\r", "\n")
        text = self._strip_book_title_prefix(text, book_title)
        text = self._deduplicate_heading(text, display_name)
        lines = [line.strip() for line in text.split("\n")]

        display_parts = [part.strip() for part in display_name.split(" - ") if part.strip()]
        ignored_candidates = [display_name] + display_parts[:-1]
        ignored_norms = {self._normalize_lookup(part) for part in ignored_candidates if part}
        if book_title:
            ignored_norms.add(self._normalize_lookup(book_title))

        # Remove redundant consecutive headings and empty lines
        cleaned_lines: list[str] = []
        for line in lines:
            if not line:
                if cleaned_lines and cleaned_lines[-1] != "":
                    cleaned_lines.append("")
                continue

            normalised_line = self._normalize_lookup(line)
            if normalised_line in ignored_norms:
                continue

            if cleaned_lines:
                last = cleaned_lines[-1]
                if last and self._heading_contains(line, last):
                    cleaned_lines[-1] = line
                    continue
                if line and self._heading_contains(last, line):
                    # Skip current line if previous already more descriptive
                    continue

            cleaned_lines.append(line)

        while cleaned_lines and not cleaned_lines[0]:
            cleaned_lines.pop(0)
        while cleaned_lines and not cleaned_lines[-1]:
            cleaned_lines.pop()

        if cleaned_lines and cleaned_lines[-1].lower() in {"notas", "nota"}:
            cleaned_lines.pop()

        text = "\n".join(cleaned_lines)
        text = re.sub(r"\n{3,}", "\n\n", text)
        text = re.sub(r"[\t ]+\n", "\n", text)
        text = re.sub(r"\n[\t ]+", "\n", text)
        text = re.sub(r"\)\s+\.", ").", text)
        text = re.sub(r"\s+\)", ")", text)
        return text.strip()

    @staticmethod
    def _heading_contains(value: str, candidate: str) -> bool:
        value_norm = ConverterApplication._normalize_lookup(value)
        candidate_norm = ConverterApplication._normalize_lookup(candidate)
        if not value_norm or not candidate_norm:
            return False
        return value_norm != candidate_norm and (
            value_norm in candidate_norm or candidate_norm in value_norm
        )

    @staticmethod
    def _text_signature(text: str) -> str:
        if not text:
            return ""
        import re

        return re.sub(r"\s+", " ", text).strip().lower()

    def _footnote_phrases(self, language: Optional[str]) -> Dict[str, str]:
        lang = (language or "").split("-", 1)[0].lower()
        if lang != "en" and lang != "pt":
            lang = "pt"
        if lang == "en":
            return {
                "prefix": "\n",
                "template": "footnote {number}: {text}",
                "suffix_text": " end of footnote",
                "closing": "",
                "chapter_end_template": "footnote {number}: {snippet} - {text} end of footnote",
            }

        return {
            "prefix": "\n",
            "template": "nota de rodapé {number}: {text}",
            "suffix_text": " fim da nota de rodapé",
            "closing": "",
            "chapter_end_template": "nota de rodapé {number}: {snippet} - {text} fim da nota de rodapé",
        }

    @staticmethod
    def _deduplicate_heading(text: str, display_name: str) -> str:
        if not text:
            return text

        lines = text.splitlines()
        if not lines:
            return text

        def normalise(value: str) -> str:
            value = value or ""
            value = unicodedata.normalize("NFKD", value).casefold()
            return "".join(ch for ch in value if ch.isalnum())

        display_norm = normalise(display_name)

        for idx, line in enumerate(lines):
            stripped = line.strip()
            if not stripped:
                continue
            if display_norm and normalise(stripped) == display_norm:
                lines.pop(idx)
            break

        cleaned: list[str] = []
        previous_norm = None
        for line in lines:
            stripped = line.strip()
            if not stripped:
                cleaned.append(line)
                previous_norm = None
                continue
            current_norm = normalise(stripped)
            if previous_norm and current_norm == previous_norm:
                continue
            cleaned.append(line)
            previous_norm = current_norm

        return "\n".join(cleaned).strip()

    @staticmethod
    def _resolve_footnote_mode(args: argparse.Namespace) -> str:
        if getattr(args, "no_footnote", False):
            return "skip"
        if getattr(args, "footnote_chapter_end", False):
            return "chapter_end"
        return "inline"

    def _resolve_cache_dir(self, reader: EbookReader) -> Path:
        """Resolve cache directory path using file name (not book title)

        IMPORTANTE: Usa sempre o nome do arquivo, NÃO o título do livro,
        para evitar criar pastas duplicadas
        """
        file_path = getattr(reader, "file_path", None)
        if file_path:
            base_name = Path(file_path).stem
        else:
            base_name = "livro"
        sanitized = FileManager.sanitize_filename(base_name) or "livro"
        return resolve_cache_root() / sanitized

    def _handle_clear_cache(self) -> int:
        """Handle global cache clearing command"""
        from src.cache_manager import CacheManager

        cache_manager = CacheManager(cache_dir=resolve_cache_root())

        cache_info = cache_manager.get_cache_info()
        if cache_info["total_cached_books"] == 0:
            print("📁 Nenhum cache encontrado.")
            return 0

        print(f"🗑️ Removendo cache de {cache_info['total_cached_books']} livro(s)...")
        print(f"💾 Tamanho total: {cache_info['cache_size_mb']:.1f} MB")

        success = cache_manager.clear_cache()
        if success:
            print("✅ Cache de livros removido com sucesso (modelos preservados).")
        else:
            print("❌ Erro ao remover cache.")
            return 1

        output_dir = Path.cwd() / "output"
        if output_dir.exists():
            shutil.rmtree(output_dir, ignore_errors=True)
            print(f"🧹 Diretório de saída limpo: {output_dir}")

        # Também remover filas/estados persistentes para evitar retomada indevida
        for residual in (Path.cwd() / ".jobs", Path.cwd() / ".uploads", Path.cwd() / ".job_inputs"):
            if residual.exists():
                shutil.rmtree(residual, ignore_errors=True)
                print(f"🧹 Estado de backend removido: {residual}")

        return 0

    @staticmethod
    def _normalize_lookup(value: Optional[str]) -> str:
        if not value:
            return ""
        normalised = unicodedata.normalize("NFKD", value)
        stripped = "".join(ch for ch in normalised if not unicodedata.combining(ch))
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
        parts = re.split(r"\s*(?:\.\.|:|,)\s*", raw, maxsplit=1)
        if len(parts) != 2:
            return None
        start, end = (part.strip() for part in parts)
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

    def _show_structure(self, reader: EbookReader):
        """Display book structure and save cache txt files"""
        print(f"{self.localization.t('book_label')}: {reader.title}")
        print(f"{self.localization.t('author_label')}: {reader.author}")
        structure_items = self._generate_structure_items(reader)

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

        structure_items, duplicates_removed = deduplicate_chapters_by_content(structure_items)
        if duplicates_removed:
            print(f"🧹 {duplicates_removed} capítulo(s) duplicado(s) ocultados")

        # Validate chapter count against TOC
        structure_items, was_corrected = self._validate_chapter_count(
            structure_items, reader, duplicates_removed
        )

        # If correction was needed, restore original without deduplication
        if was_corrected:
            print(
                f"✅ Restaurando {duplicates_removed} capítulo(s) - usando versão sem deduplicação\n"
            )
            structure_items = original_items

        print(f"{self.localization.t('chapters_label')}: {len(structure_items)}")

        # **Salvar cache txt** ao mostrar estrutura
        from src.cache_manager import CacheManager

        cache_manager = CacheManager(cache_dir=self.cache_root)

        chapters_data = {
            "title": reader.title or "Livro",
            "author": reader.author or "Desconhecido",
            "chapters": [],
        }

        for item in structure_items:
            cleaned_text = str(item.text_override or "")
            text_length = len(cleaned_text)
            print(
                self.localization.t(
                    "structure_item_entry", name=item.display_name, chars=text_length
                )
            )

            # Adicionar capítulo ao cache data
            chapters_data["chapters"].append({"title": item.display_name, "text": cleaned_text})

        # Salvar no cache
        if hasattr(reader, "file_path") and reader.file_path:
            success = cache_manager.save_chapters_to_cache(reader.file_path, chapters_data)
            if success:
                # **CORRIGIDO**: Não usar override_name para evitar pastas duplicadas
                cache_txt_path = cache_manager._get_cache_path(Path(reader.file_path)) / "txt"
                print(f"\n💾 Cache txt salvo em: {cache_txt_path}")
            else:
                print("\n⚠️  Erro ao salvar cache txt")

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

        if len(text) < 500:
            return True

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
        lowered = re.sub(r"cap[íi]tulo\s*\d+", "", lowered)
        lowered = re.sub(r"livro\s*[ivx]+", "", lowered)
        lowered = lowered.replace("post-scriptum", "")
        lowered = lowered.replace("post scriptum", "")
        lowered = lowered.replace("pos-scriptum", "")
        lowered = lowered.replace("prefácio", "")
        lowered = lowered.replace("prefacio", "")
        lowered = lowered.replace("posfácio", "")
        lowered = lowered.replace("posfacio", "")
        lowered = lowered.replace("imagem", "")
        lowered = lowered.replace("§", " ")
        lowered = re.sub(r"\s+", " ", lowered)
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
                        alt_key = Path(href).name
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
                        alt_key = Path(href).name
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
    def _normalize_href(href: str) -> str:
        if not href:
            return ""
        base = href.split("#", 1)[0]
        normalized = base.lstrip("./")
        normalized = normalized.strip()
        normalized = unquote(normalized)
        return normalized.lower()

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

        candidates.append(Path(lowered).name)

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

    def _is_main_division(self, name: str) -> bool:
        """Check if this is a main division (like Livro primeiro, Capítulo X)"""
        if not name:
            return False

        import re

        name_lower = name.lower()

        # Look for book divisions
        division_patterns = [
            r"livro\s+(primeiro|segundo|terceiro|quarto|quinto)",
            r"livro\s+[ivx]+",
            r"book\s+(first|second|third|fourth|fifth)",
            r"book\s+[ivx]+",
            r"parte\s+[ivx\d]+",
            r"seção\s+[ivx\d]+",
            r"capítulo\s+\d+",  # Capítulo 1, 2, etc.
            r"chapter\s+\d+",  # Chapter 1, 2, etc.
        ]

        for pattern in division_patterns:
            if re.search(pattern, name_lower):
                return True

        return False

    def _clean_main_division_name(self, name: str) -> str:
        """Clean up main division name to remove redundancy"""
        if not name:
            return name

        import re

        # For "Livro primeiro - livro primeiro DUNA", keep just "Livro primeiro"
        parts = [part.strip() for part in name.split(" - ") if part.strip()]

        # Find the best representative part
        best_part = ""
        for part in parts:
            part_lower = part.lower()
            if re.search(r"livro\s+(primeiro|segundo|terceiro)", part_lower) or re.search(
                r"capítulo\s+\d+", part_lower
            ):
                # Prefer the capitalized version
                if part[0].isupper():
                    best_part = part
                elif not best_part:
                    best_part = part

        return best_part if best_part else parts[0] if parts else name

    def _remove_redundant_main_name(self, chapter_name: str, main_name: str) -> str:
        """Remove redundant main name from chapter name"""
        if not chapter_name or not main_name:
            return chapter_name

        # Remove main name parts from chapter name
        main_lower = main_name.lower()
        parts = [part.strip() for part in chapter_name.split(" - ") if part.strip()]

        # Filter out parts that are redundant with main name
        filtered_parts = []
        for part in parts:
            part_lower = part.lower()
            if part_lower != main_lower and main_lower not in part_lower:
                filtered_parts.append(part)

        return " - ".join(filtered_parts) if filtered_parts else chapter_name

    def _is_division_candidate(self, chapter, chapters, index) -> bool:
        text = str(getattr(chapter, "text", "")).strip()
        if index < 3:
            return False
        if len(text) > 400:
            return False
        if index + 1 >= len(chapters):
            return False
        next_text = str(getattr(chapters[index + 1], "text", "")).strip()
        return len(next_text) > 1500

    def _is_substantial_chapter(self, text: str) -> bool:
        """Check if chapter has substantial content"""
        return len(text.strip()) > 5000  # At least 5000 characters

    def _find_main_chapter_for(self, chapters, current_index):
        """Find the main chapter number this subchapter belongs to"""
        # Look backwards for the last main division
        main_counter = 0
        for i in range(current_index):
            chapter = chapters[i]
            clean_name = self._clean_chapter_name(chapter.name)
            if self._is_main_division(clean_name) and len(chapter.text.strip()) >= 10:
                main_counter += 1

        return main_counter if main_counter > 0 else 1

    def _count_subchapters_before(self, chapters, current_index, main_chapter_num):
        """Count how many subchapters exist before this one for the same main chapter"""
        # Find the start index of this main chapter
        main_counter = 0
        main_start_index = 0

        for i in range(current_index):
            chapter = chapters[i]
            clean_name = self._clean_chapter_name(chapter.name)
            if self._is_main_division(clean_name) and len(chapter.text.strip()) >= 10:
                main_counter += 1
                if main_counter == main_chapter_num:
                    main_start_index = i
                    break

        # Count substantial subchapters between main chapter and current
        subchapter_count = 1
        for i in range(main_start_index + 1, current_index):
            chapter = chapters[i]
            if self._is_substantial_chapter(chapter.text):
                subchapter_count += 1

        return subchapter_count

    def _get_main_chapter_name(self, chapters, main_chapter_num):
        """Get the name of the main chapter by number"""
        main_counter = 0
        for chapter in chapters:
            clean_name = self._clean_chapter_name(chapter.name)
            if self._is_main_division(clean_name) and len(chapter.text.strip()) >= 10:
                main_counter += 1
                if main_counter == main_chapter_num:
                    return clean_name
        return None

    def _extract_first_words(self, text: str, max_words: int = PREVIEW_WORD_LIMIT) -> str:
        """Extract first words from text content"""
        if not text or not text.strip():
            return ""

        import re

        # Remove language tags [[lang:xx]] and [[/lang]] before extracting words
        clean_text = re.sub(r"\[\[lang:[a-zA-Z\-]+\]\]", "", text, flags=re.IGNORECASE)
        clean_text = re.sub(r"\[\[/lang\]\]", "", clean_text, flags=re.IGNORECASE)
        clean_text = re.sub(r"\s+", " ", clean_text.strip())
        words = clean_text.split()[:max_words]
        return " ".join(words)

    def _extract_smart_first_words(
        self, text: str, clean_name: str, main_div_name: str, max_words: int = 15
    ) -> str:
        """Extract first words avoiding repetition of chapter/section titles"""
        if not text or not text.strip():
            return ""

        import re

        # Remove language tags [[lang:xx]] and [[/lang]] before extracting words
        clean_text = re.sub(r"\[\[lang:[a-zA-Z\-]+\]\]", "", text, flags=re.IGNORECASE)
        clean_text = re.sub(r"\[\[/lang\]\]", "", clean_text, flags=re.IGNORECASE)
        clean_text = re.sub(r"\s+", " ", clean_text.strip())

        # Remove common patterns that repeat the title information
        patterns_to_remove = []

        # Add patterns based on clean_name
        if clean_name:
            # Remove exact matches
            patterns_to_remove.append(re.escape(clean_name.lower()))

            # Extract key parts of the clean name for removal
            if "§" in clean_name:
                # For sections like "§1 Introdução", remove both "introdução" and section references
                section_parts = clean_name.split(" ")
                for part in section_parts:
                    if len(part) > 3 and part not in ["§1", "§2", "§3", "§4", "§5"]:
                        patterns_to_remove.append(re.escape(part.lower()))

            if "Capítulo" in clean_name:
                # Remove "capítulo X" references
                patterns_to_remove.append(r"capítulo\s+\d+")

        # Always strip generic "capitulo X" patterns from previews
        patterns_to_remove.append(r"cap[íi]tulo\s+\d+")

        # Add patterns based on main_div_name
        if main_div_name:
            patterns_to_remove.append(re.escape(main_div_name.lower()))

        # Clean the text by removing these patterns
        text_lower = clean_text.lower()
        for pattern in patterns_to_remove:
            if pattern:
                text_lower = re.sub(pattern, "", text_lower, flags=re.IGNORECASE)

        # Clean up extra spaces and get the result
        text_lower = re.sub(r"\s+", " ", text_lower.strip())

        # If we removed too much, fall back to original approach
        if len(text_lower.strip()) < 10:
            return self._extract_first_words(clean_text, max_words)

        # Extract words from cleaned text
        words = text_lower.split()[:max_words]
        result = " ".join(words)

        # Capitalize first letter
        if result:
            result = result[0].upper() + result[1:] if len(result) > 1 else result.upper()

        return result if result else self._extract_first_words(clean_text, max_words)

    def _display_ebook_metadata(self, reader: EbookReader) -> None:
        """Display ebook metadata at application startup."""
        print("=" * 60)
        print("📚 METADADOS DO EBOOK")
        print("=" * 60)

        # Basic metadata
        print(f"📜 Título: {reader.title or 'N/A'}")
        print(f"✍️ Autor: {reader.author or 'N/A'}")

        # Chapter count
        chapters = list(reader.get_chapters())
        print(f"📊 Capítulos: {len(chapters)}")

        # Calculate total text statistics
        total_chars = sum(len(chapter.text or "") for chapter in chapters)
        total_words = sum(len((chapter.text or "").split()) for chapter in chapters)

        print(f"📝 Total de caracteres: {total_chars:,}")
        print(f"💬 Total de palavras: {total_words:,}")

        # File info
        if reader.file_path:
            file_size = reader.file_path.stat().st_size
            file_size_mb = file_size / (1024 * 1024)
            print(f"💾 Tamanho do arquivo: {file_size_mb:.1f} MB")
            print(f"🗺 Formato: {reader.file_path.suffix.upper()[1:]}")

        # TOC info
        try:
            toc_items = list(reader.get_toc())
            if toc_items:
                print(f"🗺 Índice: {len(toc_items)} entradas")
        except Exception:
            pass

        print("=" * 60)
        print()

    def _update_metadata_display_language(self) -> None:
        """Update the terminal with language detection results."""
        if self.language_profile:
            print("🌐 DETECÇÃO DE IDIOMA")
            print("-" * 30)
            if self.language_profile.primary:
                confidence = "Alta" if self.language_profile.is_confident else "Baixa"
                print(
                    f"🌐 Idioma principal: {self.language_profile.primary} (confiança: {confidence})"
                )
                if len(self.language_profile.predictions) > 0:
                    best_prediction = self.language_profile.predictions[0]
                    print(f"   Probabilidade: {best_prediction.probability:.1%}")
                if len(self.language_profile.languages) > 1:
                    other_langs = ", ".join(
                        self.language_profile.languages[1:3]
                    )  # Show up to 2 more
                    print(f"🌍 Idiomas secundários: {other_langs}")
            print(f"🔍 Caracteres analisados: {self.language_profile.analysed_chars:,}")
            print()

    def _announce_footnote_mode(self, config: ConversionConfig) -> None:
        """Display the chosen footnote handling mode once per run."""
        if self._footnote_summary_printed:
            return

        mode = (getattr(config, "footnote_mode", "inline") or "inline").lower()
        raw_context = getattr(config, "footnote_context_words", self.FOOTNOTE_CONTEXT_WORDS)
        try:
            context_words = max(int(raw_context), 0)
        except (TypeError, ValueError):
            context_words = self.FOOTNOTE_CONTEXT_WORDS
        if context_words == 0:
            context_words = self.FOOTNOTE_CONTEXT_WORDS

        label_keys = {
            "inline": "footnote_option_inline",
            "chapter_end": "footnote_option_chapter_end",
            "skip": "footnote_option_skip",
        }
        label_key = label_keys.get(mode, "footnote_option_inline")
        mode_label = self.localization.t(label_key)
        print(self.localization.t("footnote_selected", option=mode_label))

        if mode == "inline":
            print(self.localization.t("footnote_inline_context", value=context_words))
        elif mode == "chapter_end":
            print(self.localization.t("footnote_chapter_end_context", value=context_words))

        self._footnote_summary_printed = True

    def _sanitize_first_words(self, first_words: str, *phrases: str) -> str:
        """Remove redundant leading phrases from extracted first words"""
        if not first_words:
            return ""

        cleaned = first_words.strip()
        if not cleaned:
            return ""

        import re

        for phrase in phrases:
            if not phrase:
                continue
            phrase_clean = phrase.strip()
            if not phrase_clean:
                continue

            pattern = rf"^{re.escape(phrase_clean)}[\s\-–—,:;]*"
            cleaned = re.sub(pattern, "", cleaned, flags=re.IGNORECASE)

        return cleaned.strip(" -—–,:;!?\"'()[]{}")

    def _sanitize_display_values(
        self, main_name, sub_name, first_words, book_title, book_author=None
    ):
        """Clean display values to avoid repeating the book title or duplicates"""

        book_title_clean = (book_title or "").strip()
        book_author_clean = (book_author or "").strip()

        def cleanse(value: Optional[str]) -> str:
            if not value:
                return ""
            cleaned = str(value).strip()
            if not cleaned:
                return ""
            if book_title_clean and cleaned.lower() == book_title_clean.lower():
                return ""
            if book_author_clean and cleaned.lower() == book_author_clean.lower():
                return ""
            if book_title_clean:
                title_pattern = re.escape(book_title_clean)
                # Remove parenthetical fragments that still reference the book title
                cleaned = re.sub(
                    rf"\(\s*[^)]*{title_pattern}[^)]*\)",
                    "",
                    cleaned,
                    flags=re.IGNORECASE,
                )
                pattern = re.compile(title_pattern, re.IGNORECASE)
                cleaned = pattern.sub("", cleaned)
                cleaned = re.sub(r"\s+", " ", cleaned)
                cleaned = cleaned.strip()
                cleaned = re.sub(r"\s+([)\]}])", r"\1", cleaned)
                cleaned = re.sub(r"([\(\[\{])\s+", r"\1", cleaned)
                cleaned = re.sub(r"\(\s*\)", "", cleaned)
                cleaned = re.sub(r"\[\s*\]", "", cleaned)
                cleaned = re.sub(r"\{\s*\}", "", cleaned)
            if book_author_clean:
                author_pattern = re.escape(book_author_clean)
                cleaned = re.sub(author_pattern, "", cleaned, flags=re.IGNORECASE)
                cleaned = re.sub(r"\s+", " ", cleaned)
                cleaned = cleaned.strip()
            cleaned = cleaned.strip(" -–—,:;")
            return cleaned

        main = cleanse(main_name)
        sub = cleanse(sub_name)
        first = cleanse(first_words)

        seen = set()

        def unique(value: str) -> str:
            if not value:
                return ""
            lowered = value.lower()
            if lowered in seen:
                return ""
            seen.add(lowered)
            return value

        main = unique(main)
        sub = unique(sub)
        first = unique(first)

        def normalise_case(value: Optional[str]) -> Optional[str]:
            if not value:
                return value
            stripped = value.strip()
            if not stripped:
                return None
            if stripped.lower() == stripped:
                return stripped[:1].upper() + stripped[1:]
            return stripped

        main = normalise_case(main)
        sub = normalise_case(sub)
        first = normalise_case(first)

        return (main or None, sub or None, first or None)

    def _remove_duplicate_prefix(self, preview: Optional[str], *references: Optional[str]):
        if not preview:
            return None

        import re

        cleaned = preview.strip()
        for ref in references:
            if not ref:
                continue
            ref_clean = str(ref).strip()
            if not ref_clean:
                continue

            # Remove exact matches at start
            if cleaned.lower().startswith(ref_clean.lower()):
                cleaned = cleaned[len(ref_clean) :].strip(" -–—,:;")

            # Remove partial word matches too
            ref_words = ref_clean.lower().split()
            for word in ref_words:
                if len(word) > 3:  # Only for significant words
                    pattern = r"\b" + re.escape(word) + r"\b"
                    cleaned = re.sub(pattern, "", cleaned, flags=re.IGNORECASE).strip()

        # Clean up multiple spaces and separators
        cleaned = re.sub(r"[-–—,:;\s]+", " ", cleaned).strip()

        cleaned = re.sub(r"^(?:\d+\s+){1,3}", "", cleaned).strip()

        return cleaned or None

    def _parse_leading_number(self, raw_index: str) -> Optional[int]:
        try:
            return int(raw_index.split()[0])
        except (ValueError, IndexError):
            return None

    def _format_chapter_display(
        self, chapter, chapters, current_index, book_title, book_author=None
    ):
        """Format chapter display generically without book-specific rules"""

        text = str(getattr(chapter, "text", ""))
        name = str(getattr(chapter, "name", "")).strip()

        if len(text.strip()) < 5 and not name:
            return None

        index = self._format_index_value(chapter, current_index)
        clean_name = self._clean_chapter_name(name)
        preview = self._extract_first_words(text, self.PREVIEW_WORD_LIMIT)

        main_name, sub_name, preview = self._sanitize_display_values(
            clean_name, None, preview, book_title, book_author
        )

        label = self._detect_section_label(clean_name, text, current_index)
        if label:
            main_name = label

        if not any((main_name, sub_name, preview)):
            fallback_preview = self._extract_first_words(text, min(self.PREVIEW_WORD_LIMIT, 20))
            main_name = clean_name or fallback_preview or f"Chapter {current_index + 1}"
            sub_name = None
            preview = None

        preview = self._remove_duplicate_prefix(preview, main_name, sub_name)

        return (index, main_name, sub_name, preview)

    def _detect_section_label(self, clean_name: str, text: str, position: int) -> Optional[str]:
        lower_name = (clean_name or "").lower()
        lower_text = (text or "").lower()

        if position <= 5:
            if any(
                keyword in lower_name or keyword in lower_text for keyword in ("sumário", "sumario")
            ):
                labels = []
                if (
                    "sumário" in lower_name
                    or "sumario" in lower_name
                    or "sumário" in lower_text
                    or "sumario" in lower_text
                ):
                    labels.append("Sumário")
                if "capa" in lower_name or "capa" in lower_text:
                    labels.append("Capa")
                if "folha de rosto" in lower_name or "folha de rosto" in lower_text:
                    labels.append("Folha de rosto")
                return "/".join(labels) if labels else "Sumário"
            if (
                any(keyword in lower_name for keyword in ("introdu", "prefácio"))
                or any(keyword in lower_text for keyword in ("introdu", "prefácio"))
                or (
                    len(lower_text) > 800
                    and "capítulo" not in lower_text
                    and "dedic" not in lower_text
                )
            ):
                return "Introdução"
            if "dedic" in lower_name or "dedic" in lower_text:
                return "Dedicatória"

        return None

    def _format_index_value(self, chapter, position):
        raw_index = getattr(chapter, "index", None)
        if isinstance(raw_index, str) and raw_index.strip():
            return raw_index.strip()
        if isinstance(raw_index, (int, float)):
            return str(raw_index)
        return str(position + 1)

    def _get_conversion_config(self, args: argparse.Namespace, reader: EbookReader):
        """Get conversion configuration"""
        formatting_cues_pref = getattr(args, "formatting_cues", None)
        if getattr(args, "menu", False):
            config = self.menu.get_conversion_config(
                reader,
                language_profile=self.language_profile,
                formatting_cues=formatting_cues_pref,
            )
            if config:
                if getattr(args, "listen", False):
                    config.listen = True
                cache_dir = getattr(args, "cache_dir", None)
                if cache_dir:
                    config.cache_dir = Path(cache_dir)
                config.clear_cache = getattr(args, "clear_cache", False)
                config.footnote_mode = self._resolve_footnote_mode(args)
                config.footnote_context_words = self.FOOTNOTE_CONTEXT_WORDS
                self._apply_language_preferences(config)
                cues_enabled = (
                    formatting_cues_pref
                    if formatting_cues_pref is not None
                    else getattr(config, "speak_formatting_cues", True)
                )
                config.speak_formatting_cues = bool(cues_enabled)
                config.formatting_locale = self.localization.language
                apply_benchmark_profile(config.engine, config=config)
                if getattr(args, "no_parallel", False):
                    config.edge_enable_parallel = False
            return config
        config = self._create_config_from_args(args, reader)
        self._apply_language_preferences(config)
        apply_benchmark_profile(config.engine, config=config)
        if getattr(args, "no_parallel", False):
            config.edge_enable_parallel = False
        return config

    def _create_config_from_args(self, args: argparse.Namespace, reader: EbookReader):
        """Create config from command line arguments"""
        verbose = self._resolve_verbose(args)
        formatting_cues_pref = getattr(args, "formatting_cues", None)
        cues_enabled = True if formatting_cues_pref is None else bool(formatting_cues_pref)
        return self.config.create_conversion_config(
            engine=args.engine or "edge",
            voice=args.voice,
            model=args.model,
            output_dir=args.output_dir or str(Path.cwd() / "output"),
            book_title=reader.title,
            preserve_all_chapters=not getattr(args, "filter_chapters", False),
            use_simple_converter=False,
            listen=getattr(args, "listen", False),
            cache_dir=getattr(args, "cache_dir", None),
            clear_cache=getattr(args, "clear_cache", False),
            footnote_mode=self._resolve_footnote_mode(args),
            footnote_context_words=self.FOOTNOTE_CONTEXT_WORDS,
            verbose=verbose,
            priority_selectors=getattr(args, "priority", []) or [],
            speak_formatting_cues=cues_enabled,
            formatting_locale=self.localization.language,
            max_auto_retries=getattr(args, "retry_failed_rounds", None),
            manual_retry_failed=getattr(args, "retry_failed_manual", False),
        )


def _add_conversion_arguments(
    parser: argparse.ArgumentParser,
    *,
    include_menu_flag: bool = True,
    input_required: bool = True,
) -> None:
    """Attach shared CLI arguments and optional tab completion metadata."""

    input_arg = parser.add_argument(
        "input_file",
        nargs="?",
        help="Input EPUB or PDF file",
    )
    parser.add_argument(
        "extra_inputs",
        nargs="*",
        help="Additional EPUB/PDF files to convert sequentially",
    )
    engine_arg = parser.add_argument(
        "--engine",
        choices=["edge", "coqui", "piper", "kokoro", "spark"],
        default="edge",
        help="TTS engine to use (default: edge). edge=fast cloud, coqui=neural local, kokoro=fast local, spark=LLM-based",
    )
    parser.add_argument("--voice", help="Voice to use (engine-specific)")
    parser.add_argument("--model", help="Model path (for Piper/Coqui/Spark)")
    parser.add_argument("--output-dir", help="Output directory")
    parser.add_argument(
        "--show-structure",
        action="store_true",
        help="Print the detected book structure and exit",
    )
    parser.add_argument(
        "--filter-chapters",
        action="store_true",
        help="Skip very short chapters when converting",
    )
    verbose_group = parser.add_mutually_exclusive_group()
    verbose_group.add_argument(
        "--verbose",
        dest="verbose",
        action="store_true",
        default=None,
        help="Enable verbose logging (default: enabled)",
    )
    verbose_group.add_argument(
        "--no-verbose",
        dest="verbose",
        action="store_false",
        default=None,
        help="Disable verbose logging",
    )
    cues_group = parser.add_mutually_exclusive_group()
    cues_group.add_argument(
        "--formatting-cues",
        dest="formatting_cues",
        action="store_true",
        default=None,
        help="Read formatting cues aloud (quotes, italics, bold)",
    )
    cues_group.add_argument(
        "--no-formatting-cues",
        dest="formatting_cues",
        action="store_false",
        default=None,
        help="Disable spoken formatting cues",
    )
    parser.add_argument(
        "--listen",
        action="store_true",
        help="Play each chapter immediately after conversion",
    )
    parser.add_argument(
        "--no-parallel",
        dest="no_parallel",
        action="store_true",
        help="Disable chapter/segment parallelism (1 chapter at a time)",
    )
    parser.add_argument(
        "--no-footnote",
        action="store_true",
        help="Skip footnotes entirely",
    )
    parser.add_argument(
        "--footnote-chapter-end",
        action="store_true",
        help="Read footnotes at the end of the chapter instead of inline",
    )
    parser.add_argument(
        "--clear-cache",
        action="store_true",
        help="Remove cached chapter text before converting",
    )
    parser.add_argument(
        "--chapter",
        action="append",
        dest="chapters",
        metavar="CHAPTER",
        help="Select chapters by index (supports dotted syntax like 3 or 1.2) or title snippet; repeat the flag or pass comma-separated values (e.g., 5.1,5.2,5.3)",
    )
    parser.add_argument(
        "--from-chapter-to-end",
        dest="from_chapter_to_end",
        metavar="CHAPTER",
        help="Convert starting from a chapter (same syntax as --chapter) to the end",
    )
    parser.add_argument(
        "--from-chapter-to-chapter",
        dest="from_chapter_to_chapter",
        metavar="RANGE",
        help="Convert from chapter A to chapter B (use A..B, e.g., 5.1..7.3)",
    )
    parser.add_argument(
        "--section",
        action="append",
        dest="sections",
        metavar="SECTION",
        help="Additional selectors for subsections or names (accepts dotted indices and text); repeat or use comma-separated values",
    )
    parser.add_argument(
        "--priority",
        action="append",
        dest="priority",
        metavar="PRIORITY",
        help="Prioritize chapters before the rest (same syntax as --chapter)",
    )
    parser.add_argument(
        "--retry-failed",
        dest="retry_failed_rounds",
        metavar="N",
        type=int,
        help="Number of automatic retry rounds for failed chapters (default: auto). Use 0 to disable.",
    )
    parser.add_argument(
        "--retry-failed-manual",
        dest="retry_failed_manual",
        action="store_true",
        help="After auto retries, force one extra pass only for failed chapters.",
    )
    parser.add_argument(
        "--batch",
        action="append",
        dest="batch_inputs",
        metavar="PATH",
        help="Additional EPUB/PDF files or directories to convert sequentially (accepts glob patterns)",
    )
    parser.add_argument(
        "--batch-file",
        dest="batch_manifest",
        metavar="FILE",
        help="Path to a text file containing one EPUB/PDF path per line for batch conversion",
    )
    parser.add_argument(
        "--stop-on-error",
        dest="batch_stop_on_error",
        action="store_true",
        help="Stop batch conversions after the first failed book (default: continue processing)",
    )

    if include_menu_flag:
        parser.add_argument(
            "--menu",
            action="store_true",
            help="Use interactive menu instead of CLI defaults",
        )

    # Configure tab completion (argcomplete adds 'completer' attribute dynamically)
    if FilesCompleter is not None:
        input_arg.completer = FilesCompleter(allowednames=(".epub", ".pdf"))  # type: ignore

    if ChoicesCompleter is not None:
        engine_arg.completer = ChoicesCompleter(engine_arg.choices)  # type: ignore

    def _parse_leading_number(raw_index: str) -> Optional[int]:
        try:
            return int(raw_index.split()[0])
        except (ValueError, IndexError):
            return None

    return parser


def create_argument_parser() -> "argparse.ArgumentParser":
    """Create command line argument parser."""

    parser = argparse.ArgumentParser(
        description="EBook to Audiobook Converter",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.set_defaults(command="convert")

    subparsers = parser.add_subparsers(dest="command", metavar="command")

    convert_parser = subparsers.add_parser(
        "convert",
        help="Convert ebook to audiobook",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    _add_conversion_arguments(convert_parser, include_menu_flag=True)
    convert_parser.set_defaults(command="convert", menu=False)

    menu_parser = subparsers.add_parser(
        "menu",
        help="Launch interactive menu",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    _add_conversion_arguments(menu_parser, include_menu_flag=False)
    menu_parser.set_defaults(command="menu", menu=True)

    # **NEW**: Clear cache subcommand for global cache cleanup
    cache_parser = subparsers.add_parser(
        "clear-cache",
        help="Clear all cached ebook data",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    cache_parser.set_defaults(command="clear_cache")

    return parser


def main() -> int:
    """Application entry point"""
    parser = create_argument_parser()

    if argcomplete is not None:
        argcomplete.autocomplete(parser)  # Enables shell tab completion when available

    argv = sys.argv[1:]
    if not argv:
        parser.print_help()
        return 0

    args = parser.parse_args(argv)
    if not hasattr(args, "chapters"):
        args.chapters = []
    if not hasattr(args, "sections"):
        args.sections = []
    if not hasattr(args, "extra_inputs"):
        args.extra_inputs = []
    if not hasattr(args, "batch_inputs") or args.batch_inputs is None:
        args.batch_inputs = []
    if not hasattr(args, "batch_manifest"):
        args.batch_manifest = None
    if not hasattr(args, "batch_stop_on_error"):
        args.batch_stop_on_error = False

    app = ConverterApplication()
    return app.run(args)


if __name__ == "__main__":
    sys.exit(main())
