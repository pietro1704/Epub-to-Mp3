# -*- coding: utf-8 -*-
"""Audio conversion pipeline wired to the TTS engines."""

from __future__ import annotations

import asyncio
import contextlib
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
        self._completed_chapters: List[int] = []
        self.show_tts_output = False  # Only show TTS output in verbose mode

    async def convert(self, reader: EbookReader, config: ConversionConfig) -> ConversionResult:
        """Convert all chapters in ``reader`` according to ``config``."""

        # Enable verbose mode if requested
        self.verbose = getattr(config, 'verbose', False)
        # Show TTS output only in verbose mode
        self.show_tts_output = self.verbose

        if self.verbose:
            print("🔍 [VERBOSE] AudioConverter.convert() iniciado")
            print(f"🔍 [VERBOSE] Configuração: engine={getattr(config, 'engine', 'unknown')}, parallel={getattr(config, 'parallel', 'auto')}")

        # **NEW**: Setup checkpoint system
        self._current_book_path = Path(reader.file_path)
        self.cache_manager.mark_conversion_start()

        output_dir = self._setup_output_directory(config)
        # **NEW**: Setup temporary directory for conversion
        temp_dir = self._setup_temp_directory(config)
        chapters = list(reader.get_chapter_structure() or [])
        total_chapters = len(chapters)

        # **NEW**: Check for existing checkpoint
        checkpoint = self.cache_manager.load_checkpoint(self._current_book_path)
        if checkpoint and not getattr(config, 'force_reprocess', False):
            resume_result = await self._handle_checkpoint_resume(checkpoint, temp_dir, config, total_chapters)
            if resume_result:
                chapters_to_process, checkpoint_temp_dir = resume_result
                # Restore completed chapters list
                self._completed_chapters = checkpoint.completed_chapters.copy()
                # Use checkpoint temp directory
                temp_dir = checkpoint_temp_dir

        if self.verbose:
            print(f"🔍 [VERBOSE] Total de capítulos: {total_chapters}")
            print(f"🔍 [VERBOSE] Diretório de saída: {output_dir}")
            print(f"🔍 [VERBOSE] Diretório temporário: {temp_dir}")

        print(self.loc.t("conversion_start", title=reader.title, chapters=total_chapters))
        print(self.loc.t("conversion_output", path=output_dir))
        if config.parallel is not None:
            print(self.loc.t("conversion_parallel", workers=config.parallel))
        else:
            print("🔄 Modo sequencial: processando capítulos um por vez")

        self.progress.start(total_chapters, description=self.loc.t("progress_description"))

        if total_chapters == 0:
            self.progress.finish()
            empty_result = ConversionResult(True, 0, 0, [], [])
            self._report_results(empty_result)
            return empty_result

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

        # Determine parallelism configuration first
        engine_name = (getattr(config, "engine", "") or "").lower()
        concurrency, batch_size, allow_dynamic_parallel = self._calculate_parallelism_config(engine_name, config, total_chapters)

        # Show parallelism configuration
        print(f"🚀 Configuração de paralelismo: {concurrency} workers simultâneos, batch de {batch_size} capítulos")
        if engine_name == "edge":
            print("⚡ Edge TTS: Rate limiting ativo (máx 3 conexões simultâneas)")
        elif engine_name in ["coqui", "piper"]:
            print(f"🔥 Engine local ({engine_name}): Paralelismo agressivo ativado")

        if self.verbose:
            print(f"🔍 [VERBOSE] Engine configurado: {type(tts_engine).__name__}")
            print(f"🔍 [VERBOSE] Parallelismo final: concurrency={concurrency}, batch_size={batch_size}")
            print(f"🔍 [VERBOSE] Dynamic parallel permitido: {allow_dynamic_parallel}")

        # **CHANGED**: Modo sequencial por padrão, paralelo como opt-in
        if config.parallel is None or getattr(config, 'no_parallel', False):
            result = await self._convert_chapters_sequential(chapters, tts_engine, temp_dir, config)
        else:
            result = await self._convert_chapters(chapters, tts_engine, temp_dir, config)

        # **NEW**: Move files from temp to final output directory only if conversion was successful
        if result.success and result.converted_chapters > 0:
            if self.verbose:
                print(f"🔍 [VERBOSE] Movendo {len(result.output_files)} arquivos para diretório final...")

            moved_files = self.file_manager.move_files_to_final_output(temp_dir, output_dir)
            result.output_files = moved_files

            if moved_files:
                print(f"📁 {len(moved_files)} arquivos movidos para: {output_dir}")

            # **NEW**: Clear checkpoint on successful completion
            if self._current_book_path:
                self.cache_manager.clear_checkpoint(self._current_book_path)
                if self.verbose:
                    print("🔍 [VERBOSE] Checkpoint removido - conversão completa")

            self._cleanup_temp_audio(temp_dir)
        else:
            print("❌ Conversão falhou - arquivos temporários mantidos para debug")
            # Keep checkpoint for potential retry

        self.progress.finish()
        self._report_results(result)
        return result

    def _setup_output_directory(self, config: ConversionConfig) -> Path:
        base_dir = Path(config.output_dir)
        if config.book_title:
            base_dir = base_dir / self.file_manager.sanitize_filename(config.book_title)
        return self.file_manager.ensure_directory(base_dir)

    def _setup_temp_directory(self, config: ConversionConfig) -> Path:
        """Setup temporary directory for conversion files"""
        if config.book_title:
            safe_title = self.file_manager.sanitize_filename(config.book_title)
            temp_dir = Path(".cache") / safe_title
        else:
            temp_dir = Path(".cache") / "conversion"

        return self.file_manager.ensure_directory(temp_dir)

    async def _handle_checkpoint_resume(self, checkpoint: ConversionCheckpoint,
                                      current_temp_dir: Path,
                                      config: ConversionConfig,
                                      total_chapters: int) -> Optional[tuple[List[Chapter], Path]]:
        """Handle checkpoint resume logic"""
        # Validate checkpoint
        conversion_config = config.as_dict()
        if not self.cache_manager.validate_checkpoint(checkpoint, current_temp_dir, conversion_config):
            print("⚠️ Checkpoint inválido - iniciando conversão do zero")
            return None

        resume_info = self.cache_manager.get_resume_info(checkpoint)

        print("\n🔄 CONVERSÃO INTERROMPIDA DETECTADA")
        print("=" * 50)
        print(f"📖 Livro: {checkpoint.book_title}")
        print(f"📊 Progresso: {resume_info['completed_chapters']}/{checkpoint.total_chapters} capítulos ({resume_info['progress_percentage']:.1f}%)")
        print(f"⏱️ Tempo decorrido: {resume_info['elapsed_time']}")
        print(f"📅 Última atualização: {checkpoint.last_updated}")
        print(f"📁 Diretório temporário: {checkpoint.temp_dir}")

        if getattr(config, 'force_reprocess', False):
            print("🔄 --force-reprocess detectado - ignorando checkpoint")
            return None

        # Auto-resume if non-interactive or ask user
        should_resume = True
        try:
            import sys
            if sys.stdout.isatty():  # Interactive terminal
                response = input("\n❓ Retomar conversão de onde parou? [S/n]: ").strip().lower()
                should_resume = response in ('', 's', 'sim', 'y', 'yes')
        except (EOFError, KeyboardInterrupt):
            should_resume = False

        if not should_resume:
            print("🆕 Iniciando conversão do zero")
            # Clear checkpoint to prevent re-detection
            self.cache_manager.clear_checkpoint(self._current_book_path)
        # Clear temp files but preserve cached text
        if current_temp_dir.exists():
            self._cleanup_temp_audio(current_temp_dir)
            print(f"🗑️ Arquivos temporários removidos: {current_temp_dir}")
        return None

        print("▶️ Retomando conversão...")

        # Use checkpoint temp directory
        checkpoint_temp_dir = Path(checkpoint.temp_dir)

        # Get chapters that still need processing
        completed_set = set(checkpoint.completed_chapters)

        # Return None to indicate we should use original chapters list
        # The checkpoint logic will be handled in the individual chapter processing
        return None, checkpoint_temp_dir

    def _save_checkpoint(self, config: ConversionConfig, output_dir: Path, temp_dir: Path,
                        total_chapters: int, current_chapter: Optional[int] = None) -> None:
        """Save current conversion progress to checkpoint"""
        if not self._current_book_path:
            return

        try:
            book_title = getattr(config, 'book_title', '') or self._current_book_path.stem
            conversion_config = config.as_dict()

            self.cache_manager.save_checkpoint(
                book_path=self._current_book_path,
                book_title=book_title,
                output_dir=output_dir,
                temp_dir=temp_dir,
                total_chapters=total_chapters,
                completed_chapters=self._completed_chapters,
                current_chapter=current_chapter,
                conversion_config=conversion_config
            )

            if self.verbose:
                completed_count = len(self._completed_chapters)
                percentage = (completed_count / total_chapters) * 100 if total_chapters > 0 else 0
                print(f"🔍 [VERBOSE] Checkpoint salvo: {completed_count}/{total_chapters} ({percentage:.1f}%)")

        except Exception as e:
            if self.verbose:
                print(f"⚠️ Erro ao salvar checkpoint: {e}")

    def _calculate_parallelism_config(self, engine_name: str, config: ConversionConfig, total_chapters: int) -> tuple[int, int, bool]:
        """Calculate optimal parallelism settings based on engine type."""
        import os
        cpu_count = os.cpu_count() or 4

        # **CHANGED**: Se parallel é None, retornar config sequencial
        if config.parallel is None:
            return 1, 1, False

        # **CHANGED**: user_parallel nunca é None aqui (já filtrado acima)
        if engine_name == "edge":
            # Edge TTS: Otimizar para velocidade máxima mantendo estabilidade
            user_parallel = config.parallel
            concurrency = min(user_parallel, 10)  # **OPTIMIZED**: Máximo 10
            batch_size = min(concurrency * 3, total_chapters)  # **OPTIMIZED**: Batch maior
            allow_dynamic_parallel = True  # **OPTIMIZED**: Habilitar dinâmico
        elif engine_name == "coqui":
            # Coqui TTS: Otimizar paralelismo para performance local
            user_parallel = config.parallel
            concurrency = min(user_parallel, 8)  # **OPTIMIZED**: Máximo 8
            batch_size = min(concurrency * 3, total_chapters)  # **OPTIMIZED**: Batch maior
            allow_dynamic_parallel = True
        elif engine_name == "piper":
            # Piper TTS: Máximo paralelismo para processos subprocess
            user_parallel = config.parallel
            concurrency = user_parallel  # **OPTIMIZED**: Sem limite
            batch_size = min(concurrency * 3, total_chapters)  # **OPTIMIZED**: Batch maior
            allow_dynamic_parallel = True
        else:
            # Default/unknown engines: Paralelismo moderado
            concurrency = max(1, config.parallel)  # **CHANGED**: Usar valor fornecido
            batch_size = min(concurrency * 2, total_chapters)
            allow_dynamic_parallel = True

        # **FIXED**: Garantir valores mínimos
        concurrency = max(1, concurrency)
        batch_size = max(1, batch_size)

        return concurrency, batch_size, allow_dynamic_parallel

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

        converted_files: List[Path] = []
        errors: List[str] = []

        for idx, chapter in enumerate(chapters_list):
            chapter_num = idx + 1
            start_time = time.time()

            # **RESTORED**: Usar progress tracker
            self.progress.start_chapter(chapter.name, chapter_num)

            try:
                # **SIMPLE**: Conversão para diretório temporário
                output_path = self.file_manager.get_temp_output_path(chapter.name, output_dir, idx + 1)

                # **NEW**: Check if chapter already completed in checkpoint
                if idx + 1 in self._completed_chapters:
                    if output_path.exists():
                        converted_files.append(output_path)
                        self.progress.tick("✅ Capítulo já convertido (checkpoint)")
                        self.progress.complete_chapter("✅ Completo (checkpoint)")
                        continue

                # Verificar se já existe
                if output_path.exists() and not config.force_reprocess:
                    converted_files.append(output_path)
                    # **NEW**: Mark as completed in checkpoint
                    if idx + 1 not in self._completed_chapters:
                        self._completed_chapters.append(idx + 1)
                        self._save_checkpoint(config, Path(output_path.parent), output_dir, len(chapters_list), idx + 1)
                    self.progress.tick("✅ Arquivo já existe")
                    self.progress.complete_chapter("✅ Completo (cache)")
                    continue

                # Sintetizar com heartbeat e timeout
                char_count = len(chapter.text)
                timeout_seconds = min(max(char_count // 200, 30), 180)  # 30s-3min baseado no tamanho

                if self.verbose:
                    print(f"🎤 [{chapter_num}/{len(chapters_list)}] {chapter.name}: Iniciando síntese TTS")
                    print(f"   📝 Texto: {char_count} caracteres (timeout: {timeout_seconds}s)")

                # Cache text before synthesis
                try:
                    cache_dir = Path(output_dir)
                    target_dir = cache_dir / "text"
                    target_dir.mkdir(parents=True, exist_ok=True)
                    chapter_name = getattr(chapter, "name", None) or f"Chapter {idx + 1}"
                    from .utils import FileManager
                    safe_name = FileManager.sanitize_filename(chapter_name)
                    safe_name = safe_name.replace(" ", "_")
                    target_path = target_dir / f"{idx + 1:03d}_{safe_name}.txt"
                    target_path.write_text(chapter.text, encoding="utf-8")
                    if self.verbose:
                        print(f"💾 Texto salvo: {target_path}")
                except OSError as e:
                    if self.verbose:
                        print(f"⚠️ Erro ao salvar cache de texto: {e}")
                    pass

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
                            chapter.text,
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
                        clean_text = LanguageMarkup.strip(chapter.text) if LanguageMarkup else chapter.text
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
                            emergency_text = (chapter.text or "")[:1000].strip()
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
                    converted_files.append(output_path)
                    file_size = output_path.stat().st_size

                    # **NEW**: Mark chapter as completed and save checkpoint
                    if idx + 1 not in self._completed_chapters:
                        self._completed_chapters.append(idx + 1)
                        self._save_checkpoint(config, Path(output_path.parent), output_dir, len(chapters_list), idx + 1)

                    if self.verbose:
                        print(f"   📊 Arquivo gerado: {file_size} bytes")
                    self.progress.complete_chapter(f"✅ Sucesso ({file_size} bytes)")
                else:
                    # **RETRY**: Tentar com idioma padrão em caso de falha
                    if self.verbose:
                        print(f"   ⚠️ RETRY: Síntese falhou, tentando com idioma padrão")

                    try:
                        # Use only the first part of text with default language
                        simple_text = (chapter.text or "")[:2000].strip()
                        if simple_text:
                            self.progress.tick(f"🔄 Retry: texto simples (idioma padrão)...")
                            retry_timeout = 45

                            synthesis_result = await asyncio.wait_for(
                                tts_engine.synthesize_async(simple_text, output_path, formatting_segments=None),
                                timeout=retry_timeout
                            )

                            if synthesis_result and output_path.exists():
                                converted_files.append(output_path)
                                file_size = output_path.stat().st_size

                                # **NEW**: Mark chapter as completed and save checkpoint
                                if idx + 1 not in self._completed_chapters:
                                    self._completed_chapters.append(idx + 1)
                                    self._save_checkpoint(config, Path(output_path.parent), output_dir, len(chapters_list), idx + 1)

                                if self.verbose:
                                    print(f"   ✅ RETRY: Sucesso com texto simplificado ({file_size} bytes)")
                                self.progress.complete_chapter(f"✅ Sucesso (retry)")
                                continue  # Success! Continue to next chapter
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

    async def _convert_chapters(
        self,
        chapters: Iterable[Chapter],
        tts_engine,
        output_dir: Path,
        config: ConversionConfig,
    ) -> ConversionResult:
        chapters_list = list(chapters)
        if not chapters_list:
            return ConversionResult(True, 0, 0, [], [])

        engine_name = (getattr(config, "engine", "") or "").lower()

        # Get parallelism configuration
        concurrency, batch_size, allow_dynamic_parallel = self._calculate_parallelism_config(engine_name, config, len(chapters_list))

        dynamic_parallel = concurrency
        dynamic_batch_size = batch_size

        results = []
        offset = 0

        batch_number = 0
        while offset < len(chapters_list):
            batch_number += 1
            batch_end = min(offset + dynamic_batch_size, len(chapters_list))
            batch_indices = list(range(offset, batch_end))
            batch_size_actual = len(batch_indices)
            offset = batch_end

            print(f"📦 Batch {batch_number}: processando {batch_size_actual} capítulos (workers: {dynamic_parallel})")

            if self.verbose:
                print(f"🔍 [VERBOSE] Batch {batch_number}: capítulos {batch_indices[0]+1}-{batch_indices[-1]+1}")
                for idx in batch_indices:
                    chapter = chapters_list[idx]
                    text_len = len(chapter.text or "")
                    print(f"🔍 [VERBOSE]   - [{idx+1}] {chapter.name}: {text_len} chars")

            order = sorted(
                batch_indices,
                key=lambda idx: len(chapters_list[idx].text or ""),
                reverse=True,
            )

            if self.verbose:
                print(f"🔍 [VERBOSE] Ordem de processamento (por tamanho): {[idx+1 for idx in order]}")
            semaphore = asyncio.Semaphore(dynamic_parallel)
            tasks = [
                asyncio.create_task(
                    self._convert_single_chapter(
                        semaphore,
                        chapters_list[idx],
                        tts_engine,
                        output_dir,
                        idx + 1,
                        config,
                        self.progress,
                    )
                )
                for idx in order
            ]

            # Monitor batch execution with heartbeat
            batch_start_time = asyncio.get_event_loop().time()
            heartbeat_active = True

            async def batch_heartbeat():
                last_active_count = 0
                stall_count = 0
                while heartbeat_active:
                    await asyncio.sleep(5)  # Check every 5 seconds
                    if not heartbeat_active:
                        break

                    # Check task status (all are now proper Tasks)
                    active_count = sum(1 for task in tasks if not task.done())

                    elapsed = int(asyncio.get_event_loop().time() - batch_start_time)

                    if active_count == last_active_count and active_count > 0:
                        stall_count += 1
                        if stall_count >= 3:  # 15 seconds without change
                            print(f"⚠️  Possível travamento detectado: {active_count} tasks ativos há {elapsed}s")
                            # **OPTIMIZED**: Detecção mais rápida de deadlock
                            if stall_count >= 6:  # 30 seconds
                                print(f"🚨 DEADLOCK DETECTADO: Cancelando {active_count} tasks travadas após {elapsed}s")
                                for task in tasks:
                                    if not task.done():
                                        task.cancel()
                                break
                    else:
                        stall_count = 0

                    if active_count > 0:
                        completed_in_batch = batch_size_actual - active_count
                        throughput = completed_in_batch / max(elapsed, 1) * 60  # chapters per minute
                        print(f"💭 Batch {batch_number}: {active_count} workers ativos, {completed_in_batch}/{batch_size_actual} completos, {throughput:.1f} cap/min, {elapsed}s")

                    last_active_count = active_count

            heartbeat_task = asyncio.create_task(batch_heartbeat())

            try:
                batch_results = await asyncio.gather(*tasks, return_exceptions=True)
            except asyncio.CancelledError:
                # Gracefully handle cancellation by cancelling remaining tasks
                for task in tasks:
                    if not task.done():
                        task.cancel()
                # Wait for tasks to complete cancellation
                await asyncio.gather(*tasks, return_exceptions=True)
                raise
            finally:
                heartbeat_active = False
                heartbeat_task.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await heartbeat_task

            batch_time = int(asyncio.get_event_loop().time() - batch_start_time)
            print(f"✅ Batch {batch_number} completo em {batch_time}s")
            slowdown_detected = False
            for idx, outcome in zip(order, batch_results):
                results.append((idx, outcome))
                if allow_dynamic_parallel:
                    slowdown_detected = slowdown_detected or self._should_reduce_parallel(outcome)

            if allow_dynamic_parallel and slowdown_detected and dynamic_parallel > 1:
                dynamic_parallel -= 1
                dynamic_batch_size = max(dynamic_parallel * 2, dynamic_parallel + 1)
                try:
                    print(self.loc.t("conversion_parallel_downshift", workers=dynamic_parallel))
                except KeyError:
                    print(f"⚠️ Reduzindo paralelismo para {dynamic_parallel}")

        # Sort results back to original order
        results.sort(key=lambda item: item[0])
        ordered_outcomes = [outcome for _, outcome in results]

        converted_files: List[Path] = []
        errors: List[str] = []
        for chapter, outcome in zip(chapters_list, ordered_outcomes):
            # **FIXED**: Tratar CancelledError especificamente
            if isinstance(outcome, asyncio.CancelledError):
                errors.append(f"{chapter.name}: Cancelado por deadlock")
                continue
            if isinstance(outcome, Exception):
                errors.append(f"{chapter.name}: {outcome}")
                continue
            if isinstance(outcome, ChapterConversionOutcome):
                if outcome.path:
                    converted_files.append(Path(outcome.path))
                else:
                    detail = outcome.error or self.loc.t("error_conversion_failed", chapter=outcome.name)
                    if detail.startswith(f"{outcome.name}:"):
                        errors.append(detail)
                    else:
                        errors.append(f"{outcome.name}: {detail}")
                continue
            if outcome is None:
                errors.append(self.loc.t("error_conversion_failed", chapter=chapter.name))
                continue
            # Backwards compatibility when old path values are returned
            converted_files.append(Path(outcome))

        success = not errors
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

        requirements_path = Path("requirements.txt")
        if not requirements_path.exists():
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
        config: ConversionConfig,
        progress: ProgressTracker,
    ) -> ChapterConversionOutcome:
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
            return ChapterConversionOutcome(index=index, name=chapter_label, path=output_path)

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

                if not TextValidator.is_valid_text(chapter.text or " "):
                    status_holder["text"] = self.loc.t("status_insufficient_text")
                    self._announce_stage(index, chapter_label, status_holder["text"])
                    return ChapterConversionOutcome(
                        index=index,
                        name=chapter_label,
                        path=None,
                        error=status_holder["text"],
                    )

                try:
                    chunks = ChapterProcessor.chunk_text(chapter.text or "")
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
                        chapter_formatting = (
                            getattr(chapter, 'formatting_segments', None)
                            if attempt == 1 and chapter_payload == chapter.text
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
                    return ChapterConversionOutcome(
                        index=index,
                        name=chapter_label,
                        path=None,
                        error=detail,
                        slowdown=self._should_flag_slowdown(last_error),
                    )

                status_holder["text"] = self.loc.t("status_convert_mp3")
                self._announce_stage(index, chapter_label, status_holder["text"])
                converted = await self.audio_processor.convert_to_mp3(
                    temp_wav, output_path, bitrate=config.bitrate
                )
                if converted is None:
                    status_holder["text"] = self.loc.t("status_mp3_failed")
                    self._announce_stage(index, chapter_label, status_holder["text"])
                    return ChapterConversionOutcome(
                        index=index,
                        name=chapter_label,
                        path=None,
                        error=status_holder["text"],
                    )

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
                return ChapterConversionOutcome(index=index, name=chapter_label, path=converted)
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
            if self.verbose:
                print(f"💾 Texto salvo: {target_path}")
        except OSError as e:
            if self.verbose:
                print(f"⚠️ Erro ao salvar cache de texto: {e}")
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
        error_lower = error_msg.lower()
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
