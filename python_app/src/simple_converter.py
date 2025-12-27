# -*- coding: utf-8 -*-
"""
Conversor simplificado sem a complexidade async que causa travamentos.
"""

import asyncio
import time
from pathlib import Path
from typing import List, Optional

from .config import ConversionConfig
from .ebook_reader import Chapter
from .i18n import Localization
from .progress_tracker import ProgressTracker
from .utils import FileManager


class SimpleConverter:
    """Conversor simplificado que evita os problemas da arquitetura complexa."""

    def __init__(self, localization: Localization):
        self.loc = localization
        self.progress: Optional[ProgressTracker] = None

    async def convert_chapters(
        self,
        chapters: List[Chapter],
        tts_engine,
        output_dir: Path,
        config: ConversionConfig,
    ) -> dict:
        """Converte capítulos usando uma arquitetura simplificada."""

        if not chapters:
            return {"success": True, "converted": 0, "total": 0, "files": [], "errors": []}

        total_chapters = len(chapters)

        print(f"🚀 Iniciando conversão simplificada: {total_chapters} capítulos")
        print(f"💾 Saída: {output_dir}")
        print(f"🎙️ Motor: {config.engine}")

        # Decidir se usar modo paralelo ou sequencial
        if getattr(config, "no_parallel", False) or config.parallel == 1:
            print("🔄 Modo: Sequencial (um por vez)")
            result = await self._convert_sequential(chapters, tts_engine, output_dir, config)
        else:
            print(f"⚡ Modo: Paralelo simples ({config.parallel} workers)")
            result = await self._convert_parallel_simple(chapters, tts_engine, output_dir, config)

        return result

    async def _convert_sequential(
        self,
        chapters: List[Chapter],
        tts_engine,
        output_dir: Path,
        config: ConversionConfig,
    ) -> dict:
        """Conversão sequencial - um capítulo por vez."""

        converted_files = []
        errors = []

        for idx, chapter in enumerate(chapters):
            chapter_num = idx + 1
            start_time = time.time()

            print(f"\n📖 [{chapter_num}/{len(chapters)}] {chapter.name}")

            try:
                # Caminho de saída
                output_path = FileManager.get_output_path(chapter.name, output_dir, chapter_num)

                # Verificar se já existe
                if output_path.exists() and not config.force_reprocess:
                    converted_files.append(output_path)
                    elapsed = time.time() - start_time
                    file_size = output_path.stat().st_size
                    print(f"  ✅ Já existe ({elapsed:.1f}s, {file_size:,} bytes)")
                    continue

                # Sintetizar
                print(f"  🎵 Sintetizando {len(chapter.text):,} caracteres...")

                synthesis_start = time.time()
                result = await tts_engine.synthesize_async(chapter.text, output_path)
                synthesis_time = time.time() - synthesis_start

                if result and output_path.exists():
                    converted_files.append(output_path)
                    file_size = output_path.stat().st_size
                    elapsed = time.time() - start_time
                    chars_per_sec = len(chapter.text) / synthesis_time if synthesis_time > 0 else 0
                    print(
                        f"  ✅ Sucesso ({elapsed:.1f}s, {file_size:,} bytes, {chars_per_sec:.0f} chars/s)"
                    )
                else:
                    error_msg = f"Falha na síntese após {synthesis_time:.1f}s"
                    if hasattr(tts_engine, "last_error") and tts_engine.last_error:
                        error_msg += f": {tts_engine.last_error}"
                    errors.append(f"{chapter.name}: {error_msg}")
                    elapsed = time.time() - start_time
                    print(f"  ❌ Falha ({elapsed:.1f}s): {error_msg}")

            except Exception as e:
                elapsed = time.time() - start_time
                error_msg = f"Exceção após {elapsed:.1f}s: {str(e)}"
                errors.append(f"{chapter.name}: {error_msg}")
                print(f"  💥 Erro ({elapsed:.1f}s): {str(e)}")

        return {
            "success": len(errors) == 0,
            "converted": len(converted_files),
            "total": len(chapters),
            "files": converted_files,
            "errors": errors,
        }

    async def _convert_parallel_simple(
        self,
        chapters: List[Chapter],
        tts_engine,
        output_dir: Path,
        config: ConversionConfig,
    ) -> dict:
        """Conversão paralela simplificada - sem batches complexos."""

        # Limitar paralelismo para evitar problemas
        max_parallel = min(config.parallel, 4)  # Máximo 4 simultâneos
        semaphore = asyncio.Semaphore(max_parallel)

        print(f"📊 Processando {len(chapters)} capítulos com {max_parallel} workers")

        # Criar tasks para todos os capítulos
        tasks = []
        for idx, chapter in enumerate(chapters):
            task = self._process_chapter_with_semaphore(
                semaphore, chapter, idx + 1, len(chapters), tts_engine, output_dir, config
            )
            tasks.append(task)

        # Executar todos os tasks
        print("⚡ Iniciando processamento paralelo...")
        start_time = time.time()

        try:
            # Timeout total de 10 minutos
            results = await asyncio.wait_for(
                asyncio.gather(*tasks, return_exceptions=True), timeout=600.0
            )

            elapsed = time.time() - start_time
            print(f"⏱️ Processamento concluído em {elapsed:.1f}s")

        except asyncio.TimeoutError:
            elapsed = time.time() - start_time
            print(f"⏰ Timeout após {elapsed:.1f}s")
            # Cancelar tasks pendentes
            for task in tasks:
                if not task.done():
                    task.cancel()
            # Aguardar um pouco para cancelamento
            try:
                await asyncio.wait_for(asyncio.gather(*tasks, return_exceptions=True), timeout=5.0)
            except Exception:
                pass
            results = [Exception("Timeout") for _ in chapters]

        # Processar resultados
        converted_files: List[Path] = []
        errors: List[str] = []

        for idx, result in enumerate(results):
            chapter = chapters[idx]
            if isinstance(result, Exception):
                errors.append(f"{chapter.name}: {str(result)}")
            elif isinstance(result, dict):
                if result.get("success"):
                    converted_files.append(Path(result["path"]))
                else:
                    errors.append(f"{chapter.name}: {result.get('error', 'Falha desconhecida')}")
            else:
                errors.append(f"{chapter.name}: Resultado inválido")

        return {
            "success": len(errors) == 0,
            "converted": len(converted_files),
            "total": len(chapters),
            "files": converted_files,
            "errors": errors,
        }

    async def _process_chapter_with_semaphore(
        self,
        semaphore: asyncio.Semaphore,
        chapter: Chapter,
        chapter_num: int,
        total_chapters: int,
        tts_engine,
        output_dir: Path,
        config: ConversionConfig,
    ) -> dict:
        """Processa um capítulo com controle de semáforo."""

        async with semaphore:
            start_time = time.time()

            try:
                print(f"🎵 [{chapter_num}/{total_chapters}] Iniciando: {chapter.name}")

                # Caminho de saída
                output_path = FileManager.get_output_path(chapter.name, output_dir, chapter_num)

                # Verificar se já existe
                if output_path.exists() and not config.force_reprocess:
                    elapsed = time.time() - start_time
                    file_size = output_path.stat().st_size
                    print(
                        f"✅ [{chapter_num}/{total_chapters}] Já existe ({elapsed:.1f}s, {file_size:,} bytes)"
                    )
                    return {"success": True, "path": str(output_path)}

                # Sintetizar com timeout por capítulo
                synthesis_start = time.time()
                result = await asyncio.wait_for(
                    tts_engine.synthesize_async(chapter.text, output_path),
                    timeout=120.0,  # 2 minutos por capítulo
                )
                synthesis_time = time.time() - synthesis_start

                if result and output_path.exists():
                    elapsed = time.time() - start_time
                    file_size = output_path.stat().st_size
                    chars_per_sec = len(chapter.text) / synthesis_time if synthesis_time > 0 else 0
                    print(
                        f"✅ [{chapter_num}/{total_chapters}] Sucesso ({elapsed:.1f}s, {file_size:,} bytes, {chars_per_sec:.0f} chars/s)"
                    )
                    return {"success": True, "path": str(output_path)}
                else:
                    error_msg = f"Falha na síntese após {synthesis_time:.1f}s"
                    if hasattr(tts_engine, "last_error") and tts_engine.last_error:
                        error_msg += f": {tts_engine.last_error}"
                    elapsed = time.time() - start_time
                    print(
                        f"❌ [{chapter_num}/{total_chapters}] Falha ({elapsed:.1f}s): {error_msg}"
                    )
                    return {"success": False, "error": error_msg}

            except asyncio.TimeoutError:
                elapsed = time.time() - start_time
                error_msg = f"Timeout após {elapsed:.1f}s"
                print(f"⏰ [{chapter_num}/{total_chapters}] {error_msg}")
                return {"success": False, "error": error_msg}
            except Exception as e:
                elapsed = time.time() - start_time
                error_msg = f"Exceção após {elapsed:.1f}s: {str(e)}"
                print(f"💥 [{chapter_num}/{total_chapters}] Erro ({elapsed:.1f}s): {str(e)}")
                return {"success": False, "error": error_msg}
