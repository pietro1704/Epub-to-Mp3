# -*- coding: utf-8 -*-
"""Audio conversion pipeline wired to the TTS engines."""

from __future__ import annotations

import asyncio
import contextlib
import inspect
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, List, Optional

from .ebook_reader import EbookReader, Chapter
from .config import ConversionConfig
from .tts.factory import TTSFactory
from .utils import AudioProcessor, FileManager, TextValidator
from .progress import ProgressTracker
from .i18n import Localization, get_localization
from .cache_manager import CacheManager


@dataclass
class ConversionResult:
    """Result of audio conversion"""
    success: bool
    total_chapters: int
    converted_chapters: int
    output_files: List[Path]
    errors: List[str]


@dataclass
class ChapterConversionOutcome:
    """Outcome of a single chapter conversion."""

    index: int
    name: str
    path: Optional[Path]
    error: Optional[str] = None
    slowdown: bool = False


class AudioConverter:
    """Coordinate ebook parsing, TTS synthesis and post-processing."""

    def __init__(self, localization: Optional[Localization] = None) -> None:
        self.tts_factory = TTSFactory()
        self.audio_processor = AudioProcessor()
        self.file_manager = FileManager()
        self.progress = ProgressTracker()
        self.cache_manager = CacheManager()
        self._requirements_attempted = False
        self.loc = localization or get_localization()
        self.verbose = False
        self._current_book_path: Optional[Path] = None
        self.show_tts_output = False  # Only show TTS output in verbose mode

    @staticmethod
    def _speech_text(chapter: Chapter) -> str:
        text = getattr(chapter, "speech_text", None)
        if text is None:
            text = chapter.text or ""
        return text

    def _validate_and_clean_cache(self, chapters: List[Chapter], output_dir: Path, config: ConversionConfig) -> None:
        """Validate cache: if MP3 exists but pre-tts.txt doesn't, delete MP3"""
        text_dir = Path(output_dir) / "text"
        deleted_count = 0

        for idx, chapter in enumerate(chapters):
            chapter_num = idx + 1
            chapter_name = getattr(chapter, "name", None) or f"Chapter {chapter_num}"
            safe_name = self.file_manager.sanitize_filename(chapter_name)

            # Check for pre-tts.txt
            pre_tts_file = text_dir / f"{chapter_num} - {safe_name}-pre-tts.txt"

            # Check for MP3
            mp3_path = self.file_manager.get_temp_output_path(chapter.name, output_dir, chapter_num)

            # If MP3 exists but pre-tts.txt doesn't → cache invalidated, delete MP3
            if mp3_path.exists() and not pre_tts_file.exists():
                if self.verbose:
                    print(f"   🗑️ Cache inválido para capítulo {chapter_num}: {mp3_path.name}")
                mp3_path.unlink()
                deleted_count += 1

        if deleted_count > 0:
            print(f"🗑️ {deleted_count} arquivo(s) MP3 removido(s) (cache inválido)")

    def _generate_all_text_files(self, chapters: List[Chapter], output_dir: Path, config: ConversionConfig) -> None:
        """Generate all text files BEFORE starting TTS conversion"""
        text_dir = Path(output_dir) / "text"
        text_dir.mkdir(parents=True, exist_ok=True)

        files_generated = 0
        for idx, chapter in enumerate(chapters):
            chapter_num = idx + 1
            chapter_name = getattr(chapter, "name", None) or f"Chapter {chapter_num}"

            # Sanitize filename
            safe_name = self.file_manager.sanitize_filename(chapter_name)

            # NEW FORMAT: "N - ChapterName-parsed.txt" and "N - ChapterName-pre-tts.txt"
            parsed_path = text_dir / f"{chapter_num} - {safe_name}-parsed.txt"
            pre_tts_path = text_dir / f"{chapter_num} - {safe_name}-pre-tts.txt"

            # Only generate if files don't exist
            if not pre_tts_path.exists() or not parsed_path.exists():
                # Get texts
                parsed_text = chapter.text or ""
                pre_tts_text = self._speech_text(chapter)

                # Write files
                parsed_path.write_text(parsed_text, encoding="utf-8")
                pre_tts_path.write_text(pre_tts_text, encoding="utf-8")
                files_generated += 2

                if self.verbose:
                    print(f"   📄 {chapter_num}. {chapter_name}")
                    print(f"      → {parsed_path.name}")
                    print(f"      → {pre_tts_path.name}")

        if files_generated == 0 and self.verbose:
            print("   ♻️ Todos os arquivos .txt já existem (usando cache)")

    async def convert(self, reader: EbookReader, config: ConversionConfig) -> ConversionResult:
        """Convert all chapters in ``reader`` according to ``config``."""

        # Enable verbose mode if requested
        self.verbose = getattr(config, 'verbose', False)
        # Show TTS output only in verbose mode
        self.show_tts_output = self.verbose

        if self.verbose:
            print("🔍 [VERBOSE] AudioConverter.convert() iniciado")
            print(f"🔍 [VERBOSE] Configuração: engine={getattr(config, 'engine', 'unknown')}, mode=sequential")

        # Setup paths
        reader_path = getattr(reader, "file_path", None)
        try:
            self._current_book_path = Path(reader_path) if reader_path else None
        except TypeError:
            self._current_book_path = None

        output_dir = self._setup_output_directory(config)
        # Setup temporary directory for conversion (uses .cache)
        temp_dir = self._setup_temp_directory(config)
        chapters = list(reader.get_chapter_structure(preserve_all=config.preserve_all_chapters) or [])
        total_chapters = len(chapters)

        if self.verbose:
            print(f"🔍 [VERBOSE] Total de capítulos: {total_chapters}")
            print(f"🔍 [VERBOSE] Diretório de saída: {output_dir}")
            print(f"🔍 [VERBOSE] Diretório temporário: {temp_dir}")

        print(self.loc.t("conversion_start", title=reader.title, chapters=total_chapters))
        print(self.loc.t("conversion_output", path=output_dir))
        print("🔄 Modo sequencial: processando capítulos um por vez")

        if total_chapters == 0:
            empty_result = ConversionResult(True, 0, 0, [], [])
            self._report_results(empty_result)
            return empty_result

        # **NEW**: Generate ALL .txt files BEFORE starting TTS conversion
        print("\n📝 Gerando arquivos de texto...")
        self._generate_all_text_files(chapters, temp_dir, config)
        print(f"✅ {total_chapters} arquivos de texto gerados\n")

        self.progress.start(total_chapters, description=self.loc.t("progress_description"))

        try:
            tts_engine = self.tts_factory.create_engine(config)
        except ImportError as exc:
            if self._install_requirements():
                tts_engine = self.tts_factory.create_engine(config)
            else:
                raise
        voice_label = getattr(tts_engine, "voice", None) or config.voice or "(auto)"
        print(self.loc.t("conversion_engine_voice", engine=config.engine, voice=voice_label))
        if getattr(config, "languages", None):
            print(self.loc.t("conversion_languages", languages=", ".join(config.languages)))

        if self.verbose:
            print(f"🔍 [VERBOSE] Engine configurado: {type(tts_engine).__name__}")

        # Always use sequential processing
        result = await self._convert_chapters_sequential(chapters, tts_engine, temp_dir, config)

        # Move files from temp to final output directory only if conversion was successful
        if result.success and result.converted_chapters > 0:
            if self.verbose:
                print(f"🔍 [VERBOSE] Movendo {len(result.output_files)} arquivos para diretório final...")

            moved_files = self.file_manager.move_files_to_final_output(temp_dir, output_dir)
            result.output_files = moved_files

            if moved_files:
                print(f"📁 {len(moved_files)} arquivos movidos para: {output_dir}")

            self._cleanup_temp_audio(temp_dir)
        else:
            print("❌ Conversão falhou - arquivos temporários mantidos para debug")

        self.progress.finish()
        self._report_results(result)
        return result

    def _setup_output_directory(self, config: ConversionConfig) -> Path:
        base_dir = Path(config.output_dir)
        if config.book_title:
            base_dir = base_dir / self.file_manager.sanitize_filename(config.book_title)
        engine_suffix = self._build_engine_signature(config)
        base_dir = base_dir / engine_suffix
        return self.file_manager.ensure_directory(base_dir)

    def _setup_temp_directory(self, config: ConversionConfig) -> Path:
        """Setup temporary directory for conversion files"""
        custom_cache = getattr(config, "cache_dir", None)
        if custom_cache:
            base_cache = Path(custom_cache)
        else:
            base_cache = Path(".cache")
            if config.book_title:
                safe_title = self.file_manager.sanitize_filename(config.book_title)
                base_cache = base_cache / safe_title
            else:
                base_cache = base_cache / "conversion"

        engine_suffix = self._build_engine_signature(config)
        temp_dir = self.file_manager.ensure_directory(base_cache / engine_suffix)
        config.cache_dir = temp_dir
        return temp_dir

    def _build_engine_signature(self, config: ConversionConfig) -> str:
        voice = getattr(config, "voice", None)
        model_path = getattr(config, "model_path", None)
        fallback_voice = None
        if not voice and config.language_voices:
            fallback_voice = next(iter(config.language_voices.values()), None)
        return self.file_manager.build_engine_voice_suffix(
            engine=getattr(config, "engine", None),
            voice=voice,
            model_path=model_path,
            fallback_voice=fallback_voice,
        )


    async def _convert_chapters_sequential(
        self,
        chapters: Iterable[Chapter],
        tts_engine,
        output_dir: Path,
        config: ConversionConfig,
    ) -> ConversionResult:
        """Converte capítulos sequencialmente, SEM sistema de paralelismo."""
        chapters_list = list(chapters)
        if not chapters_list:
            return ConversionResult(True, 0, 0, [], [])

        print(f"🔄 Modo sequencial: processando {len(chapters_list)} capítulos")

        # **NEW**: Check for cache invalidation BEFORE generating text files
        # If MP3 exists but pre-tts.txt doesn't, delete MP3 (cache invalidated)
        self._validate_and_clean_cache(chapters_list, output_dir, config)

        # **NEW**: Generate ALL text files BEFORE starting conversion
        self._generate_all_text_files(chapters_list, output_dir, config)

        converted_files: List[Path] = []
        errors: List[str] = []

        for idx, chapter in enumerate(chapters_list):
            chapter_num = idx + 1
            start_time = time.time()

            # **RESTORED**: Usar progress tracker
            self.progress.start_chapter(chapter.name, chapter_num)

            try:
                # Conversão para diretório temporário
                output_path = self.file_manager.get_temp_output_path(chapter.name, output_dir, idx + 1)

                # Check if MP3 already exists and is valid (size > 1KB)
                # Note: Cache validation already done by _validate_and_clean_cache()
                if output_path.exists() and not config.force_reprocess:
                    file_size = output_path.stat().st_size
                    if file_size > 1000:  # Mínimo 1KB para áudio válido
                        converted_files.append(output_path)
                        self.progress.tick(f"✅ Arquivo já existe ({file_size} bytes)")
                        self.progress.complete_chapter("✅ Completo (cache)")
                        continue
                    else:
                        # Arquivo vazio ou corrompido - remover e reconverter
                        if self.verbose:
                            print(f"   🗑️ Removendo arquivo inválido ({file_size} bytes): {output_path}")
                        output_path.unlink(missing_ok=True)

                # Sintetizar com heartbeat e timeout
                speech_text = self._speech_text(chapter)
                char_count = len(speech_text)
                timeout_seconds = min(max(char_count // 200, 30), 180)  # 30s-3min baseado no tamanho

                if self.verbose:
                    print(f"🎤 [{chapter_num}/{len(chapters_list)}] {chapter.name}: Iniciando síntese TTS")
                    print(f"   📝 Texto: {char_count} caracteres (timeout: {timeout_seconds}s)")

                self.progress.tick(f"🎤 Sintetizando {char_count} chars (timeout: {timeout_seconds}s)...")

                # **NEW**: Heartbeat para mostrar progresso visual
                heartbeat_active = True
                start_synthesis = time.time()

                async def synthesis_heartbeat():
                    spinner_frames = ["🔄", "⚙️", "🔧", "⚡"]
                    frame_idx = 0
                    while heartbeat_active:
                        await asyncio.sleep(1)  # Atualizar a cada segundo
                        if not heartbeat_active:
                            break
                        elapsed = int(time.time() - start_synthesis)
                        frame = spinner_frames[frame_idx % len(spinner_frames)]
                        self.progress.tick(f"{frame} Sintetizando... {elapsed}s/{timeout_seconds}s ({char_count} chars)")
                        frame_idx += 1

                heartbeat_task = asyncio.create_task(synthesis_heartbeat())

                try:
                    if self.verbose:
                        print(f"   🔄 Executando comando TTS: {type(tts_engine).__name__}")

                    synthesis_result = await asyncio.wait_for(
                        tts_engine.synthesize_async(
                            speech_text,
                            output_path,
                            formatting_segments=getattr(chapter, 'formatting_segments', None)
                        ),
                        timeout=timeout_seconds
                    )

                    if self.verbose and synthesis_result:
                        print(f"   ✅ TTS concluído: {output_path.name}")
                except asyncio.TimeoutError:
                    elapsed = int(time.time() - start_synthesis)
                    if self.verbose:
                        print(f"   ⚠️ TIMEOUT: Capítulo travado após {elapsed}s")
                    self.progress.tick(f"⚠️ TIMEOUT após {elapsed}s - tentando fallback sem idioma...")

                    # **FALLBACK**: Remover marcação de idioma e tentar novamente
                    try:
                        from ..language import LanguageMarkup
                        base_text = self._speech_text(chapter)
                        clean_text = LanguageMarkup.strip(base_text) if LanguageMarkup else base_text
                        clean_chars = len(clean_text)
                        fallback_timeout = timeout_seconds // 2

                        if self.verbose:
                            print(f"   🔄 RETRY: Tentando novamente sem marcas de idioma")
                            print(f"   📝 RETRY: {clean_chars} chars (timeout: {fallback_timeout}s)")

                        self.progress.tick(f"🔄 Fallback: {clean_chars} chars (timeout: {fallback_timeout}s)")

                        # Heartbeat para fallback
                        heartbeat_active = True
                        start_fallback = time.time()

                        async def fallback_heartbeat():
                            spinner_frames = ["🚑", "🚨", "🔥", "⚡"]
                            frame_idx = 0
                            while heartbeat_active:
                                await asyncio.sleep(1)
                                if not heartbeat_active:
                                    break
                                elapsed_fb = int(time.time() - start_fallback)
                                frame = spinner_frames[frame_idx % len(spinner_frames)]
                                self.progress.tick(f"{frame} FALLBACK {elapsed_fb}s/{fallback_timeout}s (sem idioma)")
                                frame_idx += 1

                        fallback_task = asyncio.create_task(fallback_heartbeat())

                        try:
                            synthesis_result = await asyncio.wait_for(
                                tts_engine.synthesize_async(clean_text, output_path, formatting_segments=None),
                                timeout=fallback_timeout
                            )
                            if self.verbose and synthesis_result:
                                print(f"   ✅ RETRY: Sucesso no fallback!")
                        finally:
                            heartbeat_active = False
                            fallback_task.cancel()
                            with contextlib.suppress(asyncio.CancelledError):
                                await fallback_task

                    except (ImportError, asyncio.TimeoutError):
                        total_elapsed = int(time.time() - start_synthesis)
                        if self.verbose:
                            print(f"   ⚠️ FALLBACK: Tentativa dupla falhou, tentando síntese simples")
                        self.progress.tick(f"🔄 Última tentativa: síntese simples...")

                        # **THIRD ATTEMPT**: Synthesis with minimal text processing
                        try:
                            # Get first 1000 chars as emergency fallback
                            emergency_text = (speech_text or "")[:1000].strip()
                            if emergency_text:
                                emergency_timeout = 30  # Short timeout for emergency
                                if self.verbose:
                                    print(f"   🚑 EMERGÊNCIA: {len(emergency_text)} chars (timeout: {emergency_timeout}s)")

                                synthesis_result = await asyncio.wait_for(
                                    tts_engine.synthesize_async(emergency_text, output_path, formatting_segments=None),
                                    timeout=emergency_timeout
                                )
                                if synthesis_result and self.verbose:
                                    print(f"   ✅ EMERGÊNCIA: Sucesso com texto reduzido!")
                            else:
                                synthesis_result = None
                        except Exception as final_e:
                            synthesis_result = None
                            if self.verbose:
                                print(f"   ❌ EMERGÊNCIA: Falhou - {final_e}")

                        if not synthesis_result:
                            total_elapsed = int(time.time() - start_synthesis)
                            error_msg = f"TIMEOUT TRIPLO após {total_elapsed}s - todas as tentativas falharam"
                            if self.verbose:
                                print(f"   ❌ ERRO FINAL: {error_msg}")
                            errors.append(f"{chapter.name}: {error_msg}")
                            self.progress.complete_chapter(f"❌ {error_msg}")
                            continue  # **STILL CONTINUE** - never give up completely
                finally:
                    heartbeat_active = False
                    heartbeat_task.cancel()
                    with contextlib.suppress(asyncio.CancelledError):
                        await heartbeat_task

                if synthesis_result and output_path.exists():
                    file_size = output_path.stat().st_size

                    # Validar que o arquivo tem tamanho mínimo (não está vazio/corrompido)
                    if file_size > 1000:  # Mínimo 1KB para áudio válido
                        converted_files.append(output_path)

                        if self.verbose:
                            print(f"   📊 Arquivo gerado: {file_size} bytes")
                        self.progress.complete_chapter(f"✅ Sucesso ({file_size} bytes)")
                    else:
                        # Arquivo muito pequeno - provavelmente corrompido
                        if self.verbose:
                            print(f"   ⚠️ Arquivo muito pequeno ({file_size} bytes) - considerando falha")
                        output_path.unlink(missing_ok=True)
                        synthesis_result = None  # Forçar retry
                else:
                    # **RETRY**: Tentar com idioma padrão em caso de falha
                    if self.verbose:
                        print(f"   ⚠️ RETRY: Síntese falhou, tentando com idioma padrão")

                    try:
                        # Use only the first part of text with default language
                        simple_text = (speech_text or "")[:2000].strip()
                        if simple_text:
                            self.progress.tick(f"🔄 Retry: texto simples (idioma padrão)...")
                            retry_timeout = 45

                            synthesis_result = await asyncio.wait_for(
                                tts_engine.synthesize_async(simple_text, output_path, formatting_segments=None),
                                timeout=retry_timeout
                            )

                            if synthesis_result and output_path.exists():
                                file_size = output_path.stat().st_size

                                # Validar tamanho mínimo
                                if file_size > 1000:
                                    converted_files.append(output_path)

                                    if self.verbose:
                                        print(f"   ✅ RETRY: Sucesso com texto simplificado ({file_size} bytes)")
                                    self.progress.complete_chapter(f"✅ Sucesso (retry)")
                                    continue  # Success! Continue to next chapter
                                else:
                                    if self.verbose:
                                        print(f"   ⚠️ RETRY: Arquivo inválido ({file_size} bytes)")
                                    output_path.unlink(missing_ok=True)
                    except Exception as retry_e:
                        if self.verbose:
                            print(f"   ❌ RETRY falhou: {retry_e}")

                    # If all retries failed
                    error_msg = f"Falha na síntese"
                    if hasattr(tts_engine, 'last_error') and tts_engine.last_error:
                        error_msg += f": {tts_engine.last_error}"
                    if self.verbose:
                        print(f"   ❌ ERRO FINAL: {error_msg}")
                    errors.append(f"{chapter.name}: {error_msg}")
                    self.progress.complete_chapter(f"❌ {error_msg}")
                    # **CONTINUE** - never skip chapter, just mark as error

            except Exception as e:
                error_msg = f"Exceção: {str(e)}"
                if self.verbose:
                    print(f"   ❌ ERRO DE EXCEÇÃO: {error_msg}")
                errors.append(f"{chapter.name}: {error_msg}")
                self.progress.complete_chapter(f"❌ {error_msg}")
                # **CONTINUE** - log error but continue processing other chapters

        success = len(errors) == 0
        return ConversionResult(
            success=success,
            total_chapters=len(chapters_list),
            converted_chapters=len(converted_files),
            output_files=converted_files,
            errors=errors,
        )


    def _install_requirements(self) -> bool:
        if self._requirements_attempted:
            return False
        self._requirements_attempted = True

        python_root = Path(__file__).resolve().parents[1]
        candidate_paths = [
            Path("requirements.txt"),
            Path.cwd() / "requirements.txt",
            python_root / "requirements.txt",
        ]
        requirements_path = next((path for path in candidate_paths if path.exists()), None)

        if requirements_path is None:
            print(self.loc.t("requirements_not_found"))
            return False

        print(self.loc.t("installing_requirements"))
        result = subprocess.run(
            [sys.executable, "-m", "pip", "install", "-r", str(requirements_path)],
            check=False,
        )

        if result.returncode == 0:
            print(self.loc.t("requirements_success"))
            return True

        print(self.loc.t("requirements_failure"))
        return False

    async def _convert_single_chapter(
        self,
        semaphore: asyncio.Semaphore,
        chapter: Chapter,
        tts_engine,
        output_dir: Path,
        index: int,
        config: Optional[ConversionConfig] = None,
        progress: Optional[ProgressTracker] = None,
    ) -> ChapterConversionOutcome | Optional[Path]:
        legacy_mode = config is None and progress is None
        if config is None:
            config = ConversionConfig(engine="edge", output_dir=str(output_dir))
        if progress is None:
            progress = self.progress
        chapter_label = chapter.name or f"Chapter {index}"
        output_path = self.file_manager.get_temp_output_path(chapter_label, output_dir, index)
        cache_dir = getattr(config, "cache_dir", None)

        if output_path.exists() and not config.force_reprocess:
            progress.start_chapter(chapter_label, index)
            self._cache_audio(cache_dir, output_path, chapter, index, config)
            status = self.loc.t("status_cached")
            self._announce_stage(index, chapter_label, status)
            if getattr(config, "listen", False):
                progress.tick(self.loc.t("status_playing"))
                played = await self.audio_processor.play_audio(output_path)
                status = self.loc.t("status_complete") if played else self.loc.t("status_play_unavailable")
                self._announce_stage(index, chapter_label, status)
            progress.complete_chapter(status)
            outcome = ChapterConversionOutcome(index=index, name=chapter_label, path=output_path)
            return output_path if legacy_mode else outcome

        progress.start_chapter(chapter_label, index)
        status_holder = {"text": self.loc.t("status_waiting_slot")}
        self._announce_stage(index, chapter_label, status_holder["text"])
        heartbeat_stop = asyncio.Event()

        async def heartbeat():
            try:
                while not heartbeat_stop.is_set():
                    progress.tick(status_holder["text"])
                    await asyncio.sleep(1)
            except asyncio.CancelledError:
                pass

        heartbeat_task = asyncio.create_task(heartbeat())

        try:
            await semaphore.acquire()
            progress.mark_phase_start()
            status_holder["text"] = self.loc.t("status_preparing")
            self._announce_stage(index, chapter_label, status_holder["text"])
            try:
                if self.verbose:
                    chapter_text = chapter.text
                    text_info = f"None" if chapter_text is None else f"{len(chapter_text)} chars"
                    print(f"🔍 [VERBOSE] Chapter {index} text: {text_info}")
                    if chapter_text:
                        print(f"🔍 [VERBOSE] Chapter {index} preview: {str(chapter_text)[:100]}")

                if not TextValidator.is_valid_text(self._speech_text(chapter) or " "):
                    status_holder["text"] = self.loc.t("status_insufficient_text")
                    self._announce_stage(index, chapter_label, status_holder["text"])
                    outcome = ChapterConversionOutcome(
                        index=index,
                        name=chapter_label,
                        path=None,
                        error=status_holder["text"],
                    )
                    return None if legacy_mode else outcome

                try:
                    chunks = ChapterProcessor.chunk_text(self._speech_text(chapter) or "")
                    chapter_payload = "\n".join(chunks)
                    if self.verbose:
                        print(f"🔍 [VERBOSE] Chapter {index} chunks: {len(chunks)}, payload: {len(chapter_payload)} chars")


                except Exception as e:
                    if self.verbose:
                        print(f"🔍 [VERBOSE] Chapter {index} chunk_text error: {e}")
                    raise
                self._cache_text(cache_dir, chapter, index, chapter_payload)
                status_holder["text"] = self.loc.t("status_synthesizing")
                self._announce_stage(index, chapter_label, status_holder["text"])

                # **OPTIMIZED**: Estratégia de fallback mais rápida
                char_count = len(chapter_payload) if chapter_payload else 100
                lang_tag_count = chapter_payload.lower().count("[[lang:")

                # Usar fallback imediato para capítulos complexos (limites mais baixos)
                use_immediate_fallback = lang_tag_count > 50 or (lang_tag_count > 20 and char_count > 15000)

                if use_immediate_fallback:
                    if self.verbose:
                        print(f"🔍 [VERBOSE] Chapter {index} muito complexo ({lang_tag_count} tags, {char_count} chars) - usando fallback imediato")
                    # Apply fallback immediately
                    try:
                        from ..language import LanguageMarkup
                        chapter_payload = LanguageMarkup.strip(chapter_payload) if LanguageMarkup else chapter_payload
                        if self.verbose:
                            print(f"🔍 [VERBOSE] Chapter {index} FALLBACK IMEDIATO: {char_count} → {len(chapter_payload)} chars")
                        # Update status to show immediate fallback
                        status_holder["text"] = f"🔄 Fallback: removendo {lang_tag_count} tags de idioma"
                        self._announce_stage(index, chapter_label, status_holder["text"])
                    except ImportError:
                        if self.verbose:
                            print(f"🔍 [VERBOSE] Chapter {index} FALLBACK: LanguageMarkup não disponível")

                # **OPTIMIZED**: Timeouts mais agressivos para velocidade
                if use_immediate_fallback or lang_tag_count > 10:
                    chapter_timeout = 20  # **OPTIMIZED**: 20 segundos para complexos
                else:
                    chapter_timeout = min(max(char_count // 300, 30), 120)  # **OPTIMIZED**: Máximo 2 minutos

                if self.verbose:
                    print(f"🔍 [VERBOSE] Chapter {index} timeout: {chapter_timeout}s para {char_count} chars")

                # Try synthesis (already with fallback applied for complex chapters)
                synthesis_task = None
                temp_wav = None
                max_attempts = 1 if use_immediate_fallback else 2
                attempt = 1

                while attempt <= max_attempts and temp_wav is None:
                    # On second attempt for non-complex chapters, apply fallback
                    if attempt == 2 and not use_immediate_fallback:
                        try:
                            from ..language import LanguageMarkup
                            simplified_payload = LanguageMarkup.strip(chapter_payload) if LanguageMarkup else chapter_payload
                            original_count = chapter_payload.lower().count("[[lang:")
                            if self.verbose:
                                print(f"🔍 [VERBOSE] Chapter {index} FALLBACK: removendo {original_count} tags [[lang:]]")
                                print(f"🔍 [VERBOSE] Chapter {index} FALLBACK: {len(chapter_payload)} → {len(simplified_payload)} chars")
                            status_holder["text"] = f"🔄 Tentativa 2: removendo {original_count} tags de idioma"
                            self._announce_stage(index, chapter_label, status_holder["text"])
                            chapter_payload = simplified_payload
                        except ImportError:
                            if self.verbose:
                                print(f"🔍 [VERBOSE] Chapter {index} FALLBACK: LanguageMarkup não disponível")

                    try:
                        if self.verbose:
                            print(f"🔍 [VERBOSE] Chapter {index} tentativa {attempt}/{max_attempts}")

                        # Pass formatting segments only on first attempt with original payload
                        speech_text = self._speech_text(chapter)
                        chapter_formatting = (
                            getattr(chapter, 'formatting_segments', None)
                            if attempt == 1 and chapter_payload == speech_text
                            else None
                        )
                        synthesis_task = asyncio.create_task(
                            tts_engine.synthesize_async(
                                chapter_payload,
                                output_path.with_suffix(".wav"),
                                formatting_segments=chapter_formatting
                            )
                        )
                        temp_wav = await asyncio.wait_for(synthesis_task, timeout=chapter_timeout)

                        if temp_wav and (attempt == 2 or use_immediate_fallback):
                            if self.verbose:
                                print(f"🔍 [VERBOSE] Chapter {index} SUCESSO no fallback!")

                    except asyncio.TimeoutError:
                        if self.verbose:
                            print(f"🔍 [VERBOSE] Chapter {index} tentativa {attempt} timeout após {chapter_timeout}s")
                        if synthesis_task and not synthesis_task.done():
                            synthesis_task.cancel()
                            try:
                                await synthesis_task
                            except asyncio.CancelledError:
                                pass

                        if attempt == max_attempts:
                            temp_wav = None
                            if hasattr(tts_engine, 'last_error'):
                                tts_engine.last_error = "timeout_final"

                    except Exception as e:
                        if legacy_mode:
                            raise
                        if self.verbose:
                            print(f"🔍 [VERBOSE] Chapter {index} tentativa {attempt} erro: {e}")
                        if synthesis_task and not synthesis_task.done():
                            synthesis_task.cancel()

                        if attempt == max_attempts:
                            temp_wav = None
                            if hasattr(tts_engine, 'last_error'):
                                tts_engine.last_error = f"error: {e}"

                    attempt += 1

                if not temp_wav:
                    status_holder["text"] = self.loc.t("status_synthesis_failed")
                    last_error = getattr(tts_engine, "last_error", None)
                    detail = (
                        self.loc.t("status_synthesis_failed_detail", error=last_error)
                        if last_error
                        else status_holder["text"]
                    )
                    status_holder["text"] = detail
                    self._announce_stage(index, chapter_label, detail)
                    outcome = ChapterConversionOutcome(
                        index=index,
                        name=chapter_label,
                        path=None,
                        error=detail,
                        slowdown=self._should_flag_slowdown(last_error),
                    )
                    return None if legacy_mode else outcome

                status_holder["text"] = self.loc.t("status_convert_mp3")
                self._announce_stage(index, chapter_label, status_holder["text"])
                converted = await self.audio_processor.convert_to_mp3(
                    temp_wav, output_path, bitrate=config.bitrate
                )
                if converted is None:
                    status_holder["text"] = self.loc.t("status_mp3_failed")
                    self._announce_stage(index, chapter_label, status_holder["text"])
                    outcome = ChapterConversionOutcome(
                        index=index,
                        name=chapter_label,
                        path=None,
                        error=status_holder["text"],
                    )
                    return None if legacy_mode else outcome

                try:
                    if temp_wav.exists():
                        temp_wav.unlink()
                except OSError:
                    pass

                status_holder["text"] = self.loc.t("status_complete")
                self._announce_stage(index, chapter_label, status_holder["text"])
                if getattr(config, "listen", False):
                    status_holder["text"] = self.loc.t("status_playing")
                    self._announce_stage(index, chapter_label, status_holder["text"])
                    played = await self.audio_processor.play_audio(converted)
                    status_holder["text"] = self.loc.t("status_complete") if played else self.loc.t("status_play_unavailable")
                    self._announce_stage(index, chapter_label, status_holder["text"])
                self._cache_audio(cache_dir, converted, chapter, index, config)
                outcome = ChapterConversionOutcome(index=index, name=chapter_label, path=converted)
                return converted if legacy_mode else outcome
            finally:
                semaphore.release()
        except Exception as exc:
            if self.verbose:
                print(f"🔍 [VERBOSE] Chapter {index} exception: {type(exc).__name__}: {exc}")
                import traceback
                traceback.print_exc()
            if not status_holder["text"].startswith("❌"):
                status_holder["text"] = self.loc.t("status_internal_error")
                self._announce_stage(index, chapter_label, status_holder["text"])
            if legacy_mode:
                raise
            raise RuntimeError(f"chapter conversion failed: {type(exc).__name__}: {exc}") from exc
        finally:
            heartbeat_stop.set()
            heartbeat_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await heartbeat_task
            progress.complete_chapter(status_holder["text"])

    def _report_results(self, result: ConversionResult) -> None:
        print(self.loc.t("conversion_results_title"))
        print(self.loc.t("conversion_results_success", converted=result.converted_chapters, total=result.total_chapters))
        print(self.loc.t("conversion_results_files", files=len(result.output_files)))
        if result.errors:
            print(self.loc.t("conversion_results_errors", errors=len(result.errors)))
            for error in result.errors[:3]:
                print(f"    • {error}")

    def _cleanup_temp_audio(self, temp_dir: Path) -> None:
        temp_dir = Path(temp_dir)
        if not temp_dir.exists():
            return

        patterns = ("*.mp3", "*.wav", "*.ogg")
        for pattern in patterns:
            for candidate in temp_dir.glob(pattern):
                try:
                    candidate.unlink()
                except FileNotFoundError:
                    continue
                except OSError:
                    if self.verbose:
                        print(f"⚠️ Não foi possível remover arquivo temporário: {candidate}")

        audio_cache = temp_dir / "audio"
        if audio_cache.exists():
            try:
                shutil.rmtree(audio_cache, ignore_errors=True)
            except OSError:
                if self.verbose:
                    print(f"⚠️ Não foi possível limpar cache de áudio: {audio_cache}")

    @staticmethod
    def _cache_audio(
        cache_dir: Optional[Path],
        audio_path: Path,
        chapter: Chapter,
        index: int,
        config: ConversionConfig,
    ) -> None:
        if not cache_dir:
            return
        try:
            cache_dir = Path(cache_dir)
            model_bucket = AudioConverter._cache_model_bucket(config)
            target_dir = cache_dir / "audio"
            if model_bucket:
                target_dir /= model_bucket
            target_dir.mkdir(parents=True, exist_ok=True)
            chapter_name = getattr(chapter, "name", None) or f"Chapter {index}"
            safe_name = FileManager.sanitize_filename(chapter_name)
            target_path = target_dir / f"{index:03d}_{safe_name}.mp3"
            if not target_path.exists() or target_path.stat().st_mtime < audio_path.stat().st_mtime:
                shutil.copy2(audio_path, target_path)
        except OSError:
            pass

    @staticmethod
    def _cache_model_bucket(config: ConversionConfig) -> Optional[str]:
        engine = (getattr(config, "engine", "") or "unknown").lower()
        parts = [engine]

        voice = getattr(config, "voice", None)
        model_path = getattr(config, "model_path", None)

        if engine == "piper" and model_path:
            parts.append(Path(model_path).stem)
        elif engine == "coqui":
            if voice:
                parts.append(str(voice))
            elif model_path:
                parts.append(Path(model_path).stem)
        else:
            if voice:
                parts.append(str(voice))

        bucket_name = "__".join(part for part in parts if part)
        if not bucket_name:
            return None
        safe_bucket = FileManager.sanitize_filename(bucket_name, max_length=96)
        safe_bucket = safe_bucket.replace(" ", "_")
        return safe_bucket or None

    @staticmethod
    def _cache_text(
        cache_dir: Optional[Path],
        chapter: Chapter,
        index: int,
        text: str,
    ) -> None:
        if not cache_dir or not text:
            return
        try:
            cache_dir = Path(cache_dir)
            target_dir = cache_dir / "text"
            target_dir.mkdir(parents=True, exist_ok=True)
            chapter_name = getattr(chapter, "name", None) or f"Chapter {index}"
            safe_name = FileManager.sanitize_filename(chapter_name)
            safe_name = safe_name.replace(" ", "_")
            target_path = target_dir / f"{index:03d}_{safe_name}.txt"
            target_path.write_text(text, encoding="utf-8")
        except OSError:
            pass

    def _announce_stage(self, index: int, chapter_name: str, status: str) -> None:
        clean_status = status.strip()
        if not clean_status:
            return
        print(f"   → [{index}] {chapter_name}: {clean_status}", flush=True)

    @staticmethod
    def _should_reduce_parallel(outcome) -> bool:
        return isinstance(outcome, ChapterConversionOutcome) and bool(outcome.slowdown)

    @staticmethod
    def _should_flag_slowdown(error_msg: Optional[str]) -> bool:
        """Check if error indicates slowdown condition."""
        if not error_msg:
            return False
        try:
            error_lower = str(error_msg).lower()
        except Exception:
            return False
        return any(keyword in error_lower for keyword in ["timeout", "rate", "limit", "throttle", "quota"])


class ChapterProcessor:
    """Handles chapter-specific processing following SRP"""
    
    @staticmethod
    def chunk_text(text: str, max_size: int = 5000) -> List[str]:
        """Split text into manageable chunks for TTS engines."""
        if text is None:
            return [""]
        if len(text) <= max_size:
            return [text]

        import re

        sentence_splitter = re.compile(r"(?<=[.!?])\s+")
        sentences = sentence_splitter.split(text)
        chunks: List[str] = []
        current: List[str] = []
        current_len = 0

        for sentence in sentences:
            cleaned = sentence.strip()
            if not cleaned:
                continue
            if current_len + len(cleaned) + 1 > max_size and current:
                chunks.append(" ".join(current).strip())
                current = [cleaned]
                current_len = len(cleaned)
            else:
                current.append(cleaned)
                current_len += len(cleaned) + 1

        if current:
            chunks.append(" ".join(current).strip())

        return chunks or [text[:max_size]]
