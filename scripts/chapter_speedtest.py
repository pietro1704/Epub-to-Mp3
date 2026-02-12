#!/usr/bin/env python3
# ruff: noqa: E402
"""Benchmark script for comparing single-chapter TTS throughput."""

from __future__ import annotations

import argparse
import asyncio
import copy
import os
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from python_app.src.config import AppConfig
from python_app.src.converter import AudioConverter
from python_app.src.ebook_reader import Book, Chapter, EbookReader
from python_app.src.hardware_detector import HardwareDetector, HardwareProfile
from python_app.src.i18n import get_localization
from python_app.src.language import ensure_bcp47, get_language_detector

SUPPORTED_SUFFIXES = {".epub", ".pdf"}


@dataclass(frozen=True)
class Scenario:
    key: str
    label: str
    engine: str
    mode: str
    description: str


SCENARIOS: Dict[str, Scenario] = {
    "edge_multi": Scenario(
        key="edge_multi",
        label="Edge multi-idioma",
        engine="edge",
        mode="edge-multilingual",
        description="Voz padrão multilíngue com detecção automática [[lang:xx]].",
    ),
    "edge_pt": Scenario(
        key="edge_pt",
        label="Edge pt-BR monolíngue",
        engine="edge",
        mode="edge-monolingual",
        description="Força voz pt-BR monolíngue para evitar rate limit multilíngue.",
    ),
    "piper": Scenario(
        key="piper",
        label="Piper local pt-BR",
        engine="piper",
        mode="piper",
        description="Síntese offline usando modelo Piper pt-BR recomendado.",
    ),
}

# Valores públicos conhecidos na comunidade sobre limites do Edge.
EDGE_RATE_LIMIT_HINTS = {
    "edge-multilingual": 10,  # ~10 req/s para vozes MultilingualNeural
    "edge-monolingual": 16,  # ~16 req/s para vozes pt-BR Neural tradicionais
}


@dataclass
class ScenarioResult:
    scenario: Scenario
    elapsed: float
    chars_per_sec: float
    chapter_chars: int
    success: bool
    output_files: List[Path]
    errors: List[str]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Compara Edge multi-idioma, Edge pt-BR monolíngue e Piper "
            "convertendo somente 1 capítulo curto de qualquer EPUB/PDF."
        )
    )
    parser.add_argument(
        "--book",
        type=str,
        help="Arquivo/pasta do livro. Quando omitido usa o sample incluído no repositório.",
    )
    parser.add_argument(
        "--chapter",
        type=str,
        default="auto",
        help="Índice (1-based) do capítulo. Use 'auto' para deixar o script escolher um capítulo curto.",
    )
    parser.add_argument(
        "--scenarios",
        type=str,
        default="edge_multi,edge_pt,piper",
        help=f"Lista de cenários (opções: {','.join(SCENARIOS)}).",
    )
    parser.add_argument(
        "--output-dir",
        type=str,
        default="output/chapter_speedtest",
        help="Diretório base para salvar os áudios gerados.",
    )
    parser.add_argument(
        "--keep-cache",
        action="store_true",
        help="Não limpa cache antes de rodar cada cenário (mais rápido, porém menos justo).",
    )
    parser.add_argument(
        "--prefer-short",
        dest="prefer_short",
        action="store_true",
        default=True,
        help="Prioriza capítulos curtos automaticamente (default).",
    )
    parser.add_argument(
        "--no-prefer-short",
        dest="prefer_short",
        action="store_false",
        help="Desativa a escolha automática de capítulo curto.",
    )
    parser.add_argument(
        "--short-min-chars",
        type=int,
        default=200,
        help="Tamanho mínimo (caracteres) para um capítulo ser considerado 'curto'.",
    )
    parser.add_argument(
        "--short-max-chars",
        type=int,
        default=1800,
        help="Tamanho máximo (caracteres) para o capítulo curto.",
    )
    return parser.parse_args()


def resolve_book_path(book_arg: Optional[str]) -> Path:
    candidates: List[Path] = []
    if book_arg:
        candidates.append(Path(book_arg).expanduser())
    # Exemplos embutidos (não dependem de material protegido)
    repo_root = PROJECT_ROOT
    candidates.extend(
        [
            repo_root / "web" / "public" / "sample.epub",
            repo_root / "python_app" / "tests" / "fixtures" / "epubs" / "sample_multilang.epub",
            repo_root / "python_app" / "tests" / "fixtures" / "epubs" / "test_multifeature.epub",
        ]
    )
    for candidate in dict.fromkeys(candidates):
        resolved = _first_supported_input(candidate)
        if resolved:
            return resolved
    home = Path.home()
    generic_download = next(
        (
            path
            for path in [
                home / "Downloads" / "book.epub",
                home / "Downloads" / "book.pdf",
            ]
            if path.exists()
        ),
        None,
    )
    if generic_download:
        return generic_download
    raise FileNotFoundError("Livro não encontrado. Informe --book apontando para um EPUB/PDF.")


def _first_supported_input(target: Path) -> Optional[Path]:
    if target.is_file() and target.suffix.lower() in SUPPORTED_SUFFIXES:
        return target
    if target.is_dir():
        matches: List[Path] = []
        for suffix in SUPPORTED_SUFFIXES:
            matches.extend(sorted(target.glob(f"**/*{suffix}")))
        if not matches:
            return None
        matches.sort(key=lambda p: len(p.parts))
        return matches[0]
    return None


def parse_scenarios(raw: str) -> List[Scenario]:
    selected: List[Scenario] = []
    for key in [part.strip() for part in raw.split(",") if part.strip()]:
        if key not in SCENARIOS:
            raise ValueError(f"Cenário desconhecido: {key}. Válidos: {', '.join(SCENARIOS)}")
        selected.append(SCENARIOS[key])
    if not selected:
        raise ValueError("Informe pelo menos um cenário.")
    return selected


def pick_chapter(
    chapters: Sequence[Chapter],
    *,
    explicit_index: Optional[int],
    prefer_short: bool,
    short_range: Tuple[int, int],
) -> tuple[Chapter, int]:
    if not chapters:
        raise ValueError("Nenhum capítulo encontrado no livro.")

    def _valid_text(chapter: Chapter) -> bool:
        return bool(chapter.text and chapter.text.strip())

    if explicit_index is not None:
        requested = max(1, explicit_index)
        chosen_idx = min(requested, len(chapters)) - 1
        candidate = chapters[chosen_idx]
        if _valid_text(candidate):
            return candidate, chosen_idx

    if prefer_short:
        min_chars, max_chars = short_range
        for idx, chapter in enumerate(chapters):
            if not _valid_text(chapter):
                continue
            length = len(chapter.text or "")
            if min_chars <= length <= max_chars:
                return chapter, idx

    for idx, chapter in enumerate(chapters):
        if _valid_text(chapter):
            return chapter, idx

    raise ValueError("Não foi possível encontrar capítulo com texto.")


def detect_languages(chapter: Chapter) -> tuple[str, List[str]]:
    detector = get_language_detector()
    sample = chapter.text or chapter.speech_text or ""
    profile = detector.detect_profile([sample]) if sample else None
    if profile and profile.languages:
        languages = [ensure_bcp47(code) or "pt-BR" for code in profile.languages]
        primary = ensure_bcp47(profile.primary) or languages[0]
        return primary or "pt-BR", [lang for lang in languages if lang]
    return "pt-BR", ["pt-BR"]


def ensure_output_dirs(base: Path, scenarios: Iterable[Scenario]) -> None:
    base.mkdir(parents=True, exist_ok=True)
    cache_root = base / "_cache"
    cache_root.mkdir(parents=True, exist_ok=True)
    for scenario in scenarios:
        (base / scenario.key).mkdir(parents=True, exist_ok=True)
        (cache_root / scenario.key).mkdir(parents=True, exist_ok=True)


def apply_edge_overrides(config, profile: Optional[HardwareProfile], mode: str) -> None:
    recommended = profile.recommended_concurrency if profile else (os.cpu_count() or 8)
    rate_limit = EDGE_RATE_LIMIT_HINTS.get(mode, 12)
    config.edge_max_concurrency = min(
        max(recommended, config.edge_max_concurrency or 0), rate_limit
    )
    config.edge_chunk_chars = max(
        config.edge_chunk_chars, 15000 if mode == "edge-multilingual" else 14000
    )
    config.edge_max_segment_seconds = max(config.edge_max_segment_seconds, 210)
    config.edge_enable_parallel = True
    config.edge_aggressive_mode = True


def apply_piper_overrides(config, profile: Optional[HardwareProfile]) -> None:
    cpu_physical = profile.cpu_physical if profile else max(1, (os.cpu_count() or 4) // 2)
    config.piper_max_procs = max(1, min(4, cpu_physical))


def build_config(
    app_config: AppConfig,
    scenario: Scenario,
    *,
    output_base: Path,
    chapter_language: str,
    languages: List[str],
    book_title: str,
    keep_cache: bool,
) -> tuple:
    voice_provider = app_config.voice_configs
    cache_dir = output_base / "_cache" / scenario.key
    output_dir = output_base / scenario.key
    cache_dir.mkdir(parents=True, exist_ok=True)
    output_dir.mkdir(parents=True, exist_ok=True)

    kwargs = dict(
        primary_language=chapter_language,
        languages=languages,
        voice=None,
        model_path=None,
        output_dir=output_dir,
        cache_dir=cache_dir,
        book_title=book_title,
        verbose=True,
        auto_validate_output=False,
        auto_fix_output=False,
        validate_text=False,
        validate_audio=False,
        verify_transcription=False,
        strict_validate=False,
        preserve_all_chapters=False,
        force_reprocess=not keep_cache,
        clear_cache=not keep_cache,
    )

    if scenario.mode == "piper":
        kwargs["model_path"] = voice_provider.get_voice("piper", chapter_language)
    else:
        kwargs["voice"] = voice_provider.get_voice("edge", chapter_language)

    config = app_config.create_conversion_config(scenario.engine, **kwargs)
    config.formatting_locale = "pt"
    config.priority_selectors = [chapter_language]
    config.use_language_detection = scenario.mode == "edge-multilingual"
    config.prioritize_primary_language = True

    if scenario.mode == "edge-multilingual":
        fallback_voice = voice_provider.get_voice("edge", chapter_language)
        config.language_voices = voice_provider.build_language_voice_map(
            "edge", languages, fallback_voice, primary_language=chapter_language
        )
    elif scenario.mode == "edge-monolingual":
        mono_voice = voice_provider.get_monolingual_voice(chapter_language)
        if mono_voice:
            config.voice = mono_voice
        config.use_language_detection = False
        config.language_voices.clear()
    elif scenario.mode == "piper":
        config.language_voices.clear()

    return config, output_dir


async def run_scenario(
    scenario: Scenario,
    config,
    *,
    book_path: Path,
    chapter: Chapter,
    base_book: Optional[Book],
    profile: Optional[HardwareProfile],
    localization,
) -> ScenarioResult:
    print(f"\n{'='*70}")
    print(f"▶️  {scenario.label}")
    print(f"   {scenario.description}")
    if scenario.mode.startswith("edge"):
        hint = EDGE_RATE_LIMIT_HINTS.get(scenario.mode, 0)
        if hint:
            print(f"   Rate limit estimado: até {hint} requisições/s (Microsoft Edge TTS).")
    if scenario.mode == "edge-multilingual":
        apply_edge_overrides(config, profile, "edge-multilingual")
    elif scenario.mode == "edge-monolingual":
        apply_edge_overrides(config, profile, "edge-monolingual")
    elif scenario.mode == "piper":
        apply_piper_overrides(config, profile)

    chapter_copy = copy.deepcopy(chapter)
    template = base_book

    attempt = 0
    result = None
    elapsed = 0.0
    errors: List[str] = []
    while True:
        attempt += 1
        scenario_reader = EbookReader()
        scenario_reader.file_path = book_path
        scenario_reader.book = Book(
            title=(template.title if template else book_path.stem),
            author=(template.author if template else ""),
            chapters=[copy.deepcopy(chapter_copy)],
            toc=list(template.toc) if template else [],
            language=template.language if template else None,
        )
        converter = AudioConverter(localization=localization)
        converter.hardware_profile = profile

        try:
            start = time.perf_counter()
            current_result = await converter.convert(scenario_reader, config)
            elapsed = time.perf_counter() - start
            result = current_result
            break
        except Exception as exc:  # noqa: BLE001 - intentional catch to degrade concurrency
            errors.append(str(exc))
            message = str(exc)
            is_edge_mode = scenario.mode.startswith("edge")
            if (
                is_edge_mode
                and "edge_unavailable_threshold" in message
                and config.edge_max_concurrency > 1
            ):
                new_limit = max(1, config.edge_max_concurrency // 2)
                if new_limit == config.edge_max_concurrency:
                    new_limit -= 1
                if new_limit < 1:
                    raise
                config.edge_max_concurrency = new_limit
                print(
                    f"   ⚠️  Edge indisponível, reduzindo EDGE_MAX_CONCURRENCY para {new_limit} "
                    "e tentando novamente..."
                )
                continue
            raise

    chars = len(chapter_copy.text or "")
    throughput = chars / elapsed if elapsed > 0 else 0.0

    print(f"   Tempo: {elapsed:.1f}s | Throughput: {throughput:.0f} chars/s")
    print(f"   Sucesso: {result.success} (Capítulos convertidos: {result.converted_chapters})")
    for path in result.output_files:
        print(f"   ↳ {path}")
    if result.errors:
        for err in result.errors:
            print(f"   ⚠️  {err}")

    return ScenarioResult(
        scenario=scenario,
        elapsed=elapsed,
        chars_per_sec=throughput,
        chapter_chars=chars,
        success=result.success,
        output_files=result.output_files,
        errors=result.errors,
    )


async def async_main() -> None:
    args = parse_args()
    book_path = resolve_book_path(args.book)
    scenarios = parse_scenarios(args.scenarios)
    ensure_output_dirs(Path(args.output_dir).expanduser(), scenarios)

    reader = EbookReader(str(book_path))
    chapters = reader.get_chapters()
    short_range = (max(50, args.short_min_chars), max(args.short_min_chars, args.short_max_chars))
    explicit_index = None
    if str(args.chapter).strip().lower() not in {"", "auto"}:
        try:
            explicit_index = int(float(args.chapter))
        except ValueError as exc:  # noqa: B904
            raise ValueError("--chapter deve ser um número ou 'auto'") from exc
    target_chapter, idx = pick_chapter(
        chapters,
        explicit_index=explicit_index,
        prefer_short=args.prefer_short,
        short_range=short_range,
    )

    chapter_language, languages = detect_languages(target_chapter)
    print(f"Livro: {book_path}")
    print(f"Capítulo escolhido: #{idx + 1} – {target_chapter.name}")
    print(f"Idioma detectado: {chapter_language} (alternativos: {', '.join(languages)})")

    hardware_profile = None
    try:
        hardware_profile = HardwareDetector.detect()
        HardwareDetector.apply_optimizations(hardware_profile)
        HardwareDetector.print_profile(hardware_profile, verbose=False)
    except Exception as exc:
        print(f"⚠️  Falha ao detectar hardware: {exc}")

    localization = get_localization("pt")
    converter = AudioConverter(localization=localization)
    converter.hardware_profile = hardware_profile
    app_config = AppConfig()

    results: List[ScenarioResult] = []
    localization = get_localization("pt")
    base_book = reader.book
    for scenario in scenarios:
        config, _ = build_config(
            app_config,
            scenario,
            output_base=Path(args.output_dir).expanduser(),
            chapter_language=chapter_language,
            languages=languages,
            book_title=reader.title or book_path.stem,
            keep_cache=args.keep_cache,
        )
        scenario_result = await run_scenario(
            scenario,
            config,
            book_path=book_path,
            chapter=target_chapter,
            base_book=base_book,
            profile=hardware_profile,
            localization=localization,
        )
        results.append(scenario_result)

    print(f"\n{'='*70}")
    print("RESUMO")
    print(f"{'Cenário':<28} {'Tempo':>8} {'Chars/s':>10} {'Sucesso':>9}")
    for result in sorted(results, key=lambda r: r.elapsed):
        label = result.scenario.label
        print(
            f"{label:<28} {result.elapsed:>7.1f}s {result.chars_per_sec:>9.0f} "
            f"{'✅' if result.success else '⚠️'}"
        )
    fastest = min(results, key=lambda r: r.elapsed)
    print(
        f"\n🥇 Mais rápido: {fastest.scenario.label} "
        f"({fastest.elapsed:.1f}s para {fastest.chapter_chars:,} chars)"
    )


def main() -> None:
    try:
        asyncio.run(async_main())
    except KeyboardInterrupt:
        print("\nInterrompido pelo usuário.")


if __name__ == "__main__":
    main()
