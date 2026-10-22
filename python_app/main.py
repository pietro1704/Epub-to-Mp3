#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Legacy CLI composition and public compatibility entrypoints."""

import sys

from src.cli_arguments import add_conversion_arguments

from src.cli_runtime_dependencies import (
    Any as Any,
    AppConfig as AppConfig,
    AudioConverter as AudioConverter,
    Chapter as Chapter,
    ChapterStructureItem as ChapterStructureItem,
    ChoicesCompleter as ChoicesCompleter,
    ConversionConfig as ConversionConfig,
    ConversionResult as ConversionResult,
    Dict as Dict,
    EbookReader as EbookReader,
    FileManager as FileManager,
    FilesCompleter as FilesCompleter,
    FormattingSegment as FormattingSegment,
    JOBS_DIR as JOBS_DIR,
    JOB_INPUTS_DIR as JOB_INPUTS_DIR,
    LanguageDetector as LanguageDetector,
    LanguageMarkup as LanguageMarkup,
    LanguageProfile as LanguageProfile,
    List as List,
    MenuInterface as MenuInterface,
    OUTPUT_DIR as OUTPUT_DIR,
    Optional as Optional,
    PRESERVE_TTS_LAYOUT as PRESERVE_TTS_LAYOUT,
    Path as Path,
    Set as Set,
    TextFormattingProcessor as TextFormattingProcessor,
    TextProcessor as TextProcessor,
    Tuple as Tuple,
    UPLOADS_DIR as UPLOADS_DIR,
    _FALLBACK_ENGINE_CHOICES as _FALLBACK_ENGINE_CHOICES,
    _dc_replace as _dc_replace,
    apply_benchmark_profile as apply_benchmark_profile,
    argcomplete as argcomplete,
    argparse as argparse,
    asyncio as asyncio,
    contextlib as contextlib,
    copy as copy,
    dataclass as dataclass,
    deduplicate_chapters_by_content as deduplicate_chapters_by_content,
    get_language_detector as get_language_detector,
    get_localization as get_localization,
    glob as glob,
    hashlib as hashlib,
    json as json,
    os as os,
    re as re,
    resolve_cache_root as resolve_cache_root,
    shutil as shutil,
    subprocess as subprocess,
    time as time,
    traceback as traceback,
    unicodedata as unicodedata,
    unquote as unquote,
    zipfile as zipfile,
)
from src.cli_options_policy import CLIOptionsPolicy
from src.cli_batch_inputs import CLIBatchInputs
from src.cli_conversion_flow import CLIConversionFlow
from src.cli_book_cache_cleanup import CLIBookCacheCleanup
from src.cli_conversion_completion import CLIConversionCompletion
from src.cli_verification import CLIVerification
from src.cli_metrics_presentation import CLIMetricsPresentation
from src.cli_structure_assembly import CLIStructureAssembly
from src.cli_toc_projection import CLITocProjection
from src.cli_speech_transforms import CLISpeechTransforms
from src.cli_chapter_speech import CLIChapterSpeech
from src.cli_cache_policy import CLICachePolicy
from src.cli_language_detection import CLILanguageDetection
from src.cli_language_presentation import CLILanguagePresentation
from src.cli_chapter_selection import CLIChapterSelection
from src.cli_structure_presentation import CLIStructurePresentation
from src.cli_division_titles import CLIDivisionTitles
from src.cli_display_labels import CLIDisplayLabels
from src.cli_configuration import CLIConfiguration


def _resolve_cli_fallback_engine(
    flag_value: Optional[str], env_value: Optional[str]
) -> Optional[str]:
    """Resolve the CLI fallback-engine preference.

    The ``--fallback-engine`` flag wins when set to anything other than
    ``auto``. Otherwise ``FALLBACK_ENGINE_OVERRIDE`` is consulted so a single
    env var can configure both the CLI and the server's engine chain.
    Returns ``None`` when no override applies (engine-selection mixin then
    chooses based on language).
    """
    flag = (flag_value or "auto").strip().lower()
    if flag and flag != "auto":
        return flag
    env = (env_value or "").strip().lower()
    if env and env != "auto" and env in _FALLBACK_ENGINE_CHOICES:
        return env
    return None


def _prewarm_piper_pipeline(language: Optional[str] = None) -> bool:
    """Best-effort Piper warm-up: locate binary + resolve model. Never raises."""
    try:
        from src.tts.piper_engine import prewarm_piper
    except Exception:
        return False
    try:
        ok = prewarm_piper(language)
    except Exception:
        ok = False
    if ok:
        print("✅ Piper binary + model located")
    else:
        print("⏭️  Piper pre-warm skipped (binary or model unavailable)")
    return bool(ok)


def _prewarm_edge_pipeline(voice: Optional[str] = None) -> bool:
    """Eagerly open an Edge-TTS connection so the first chapter doesn't pay
    the TLS handshake. Best-effort — never raises.
    """
    try:
        import asyncio as _asyncio

        from src.tts.edge_engine import prewarm_edge
    except Exception:
        return False
    pick = (voice or "en-US-AriaNeural").strip() or "en-US-AriaNeural"
    try:
        ok = _asyncio.run(prewarm_edge(pick))
    except RuntimeError:
        # Already inside a running loop (rare in CLI). Skip silently.
        return False
    except Exception:
        ok = False
    if ok:
        print("✅ Edge-TTS connection pre-warmed")
    else:
        print("⏭️  Edge-TTS pre-warm skipped (offline or unavailable)")
    return bool(ok)


class ConverterApplication(
    CLIOptionsPolicy,
    CLIBatchInputs,
    CLIConversionFlow,
    CLIBookCacheCleanup,
    CLIConversionCompletion,
    CLIVerification,
    CLIMetricsPresentation,
    CLIStructureAssembly,
    CLITocProjection,
    CLISpeechTransforms,
    CLIChapterSpeech,
    CLICachePolicy,
    CLILanguageDetection,
    CLILanguagePresentation,
    CLIChapterSelection,
    CLIStructurePresentation,
    CLIDivisionTitles,
    CLIDisplayLabels,
    CLIConfiguration,
):
    """Main application class following SRP"""

    SUPPORTED_INPUT_SUFFIXES = (".epub", ".pdf")

    _cli_runtime = sys.modules[__name__]

    def __init__(self, ui_language: Optional[str] = None):
        self.localization = get_localization(ui_language)
        self.config = AppConfig()
        self.menu = MenuInterface(localization=self.localization)
        self.converter = AudioConverter(localization=self.localization)
        self.cache_root = resolve_cache_root()
        self.language_detector: LanguageDetector = get_language_detector()
        self.language_markup = LanguageMarkup(self.language_detector)
        self.language_profile: Optional[LanguageProfile] = None
        self._interactive_mode = True
        self._footnote_summary_printed = False

    def run(self, args: argparse.Namespace) -> int:
        """Entry point that orchestrates optional batch conversion."""
        if getattr(args, "command", None) == "clear_cache":
            return self._handle_clear_cache(args)

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
            print("⚠️ No EPUB/PDF files found to convert.")
            return 1

        if len(targets) == 1 and not batch_requested:
            args.input_file = str(targets[0])
            return self._run_single_conversion(args, hardware_profile=hardware_profile)

        return self._run_batch(args, targets, hardware_profile=hardware_profile)

    @staticmethod
    def _read_batch_manifest(manifest: Optional[str]) -> List[str]:
        return CLIBatchInputs._read_batch_manifest(manifest, namespace=sys.modules[__name__])

    @staticmethod
    def _normalize_lookup(value: Optional[str]) -> str:
        return CLIChapterSelection._normalize_lookup(value, namespace=sys.modules[__name__])

    @staticmethod
    def _remove_inline_footnotes(text: str) -> str:
        return CLIChapterSpeech._remove_inline_footnotes(text, namespace=sys.modules[__name__])

    @staticmethod
    def _strip_book_title_prefix(text: str, book_title: Optional[str]) -> str:
        return CLIChapterSpeech._strip_book_title_prefix(text, book_title, namespace=sys.modules[__name__])

    @staticmethod
    def _deduplicate_heading(text: str, display_name: str) -> str:
        return CLIChapterSpeech._deduplicate_heading(text, display_name, namespace=sys.modules[__name__])

    @staticmethod
    def _print_metrics_summary(temp_dir: Optional[Path]) -> None:
        return CLIMetricsPresentation._print_metrics_summary(temp_dir, namespace=sys.modules[__name__])

    @staticmethod
    def _print_metrics_dashboard_path(temp_dir: Optional[Path]) -> None:
        return CLIMetricsPresentation._print_metrics_dashboard_path(temp_dir, namespace=sys.modules[__name__])

    @staticmethod
    def _open_metrics_dashboard(temp_dir: Optional[Path]) -> None:
        return CLIMetricsPresentation._open_metrics_dashboard(temp_dir, namespace=sys.modules[__name__])

    @staticmethod
    def _export_metrics_bundle(temp_dir: Optional[Path]) -> None:
        return CLIMetricsPresentation._export_metrics_bundle(temp_dir, namespace=sys.modules[__name__])

    @staticmethod
    def _apply_no_parallel_env(args: argparse.Namespace) -> None:
        return CLIOptionsPolicy._apply_no_parallel_env(args, namespace=sys.modules[__name__])

    @staticmethod
    def _normalize_href(href: str) -> str:
        return CLIStructurePresentation._normalize_href(href, namespace=sys.modules[__name__])

    @staticmethod
    def _split_group_key(href_key: str) -> Optional[str]:
        return CLIStructurePresentation._split_group_key(href_key, namespace=sys.modules[__name__])

    @staticmethod
    def _heading_contains(value: str, candidate: str) -> bool:
        value_norm = ConverterApplication._normalize_lookup(value)
        candidate_norm = ConverterApplication._normalize_lookup(candidate)
        if not value_norm or not candidate_norm:
            return False
        return value_norm != candidate_norm and (
            value_norm in candidate_norm or candidate_norm in value_norm
        )


def _apply_overnight_preset(args: argparse.Namespace) -> None:
    """Apply a stable high-throughput offline preset for long overnight runs."""
    if not bool(getattr(args, "overnight", False)):
        return
    args.engine = "piper"
    args.max_performance = True
    args.profile = "speed"
    args.speed_scenario = "offline-heavy"
    args.stage_pipeline = True
    args.stage_pipeline_depth = 3
    args.chapter_prefetch = True
    args.auto_ab = False
    args.adaptive_checkpoint = True
    args.verify_transcription = False
    args.deep_validate = False
    args.validate_text = False
    args.validate_audio = False
    args.auto_validate_output = False
    args.auto_fix_output = False
    args.fix_mode = False
    if getattr(args, "piper_chunk_chars", None) is None:
        args.piper_chunk_chars = 2200


def _add_conversion_arguments(
    parser: argparse.ArgumentParser,
    *,
    include_menu_flag: bool = True,
    input_required: bool = True,
) -> None:
    """Attach the shared ordered schema using this facade's completion dependencies."""
    return add_conversion_arguments(
        parser, include_menu_flag=include_menu_flag, input_required=input_required,
        namespace=sys.modules[__name__],
    )


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
        help="Clear cached ebook data. With a book file: removes only that book. Without: removes all (with confirmation).",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    cache_parser.add_argument(
        "book",
        nargs="?",
        default=None,
        help="EPUB/PDF file whose cache and output should be removed (optional; omit to clear all)",
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
    _apply_overnight_preset(args)

    # Handle --no-validate flag to disable all validations
    if getattr(args, "no_validate", False):
        args.validate_text = False
        args.validate_audio = False

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

    app = ConverterApplication(ui_language=getattr(args, "ui_language", None))
    return app.run(args)


if __name__ == "__main__":
    sys.exit(main())
