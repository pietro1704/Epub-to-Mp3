"""
src/converter.py

Conversor principal com ETA em tempo real e --no-cache funcional.
"""

import time
from pathlib import Path
from typing import List, Tuple

from config import Config
from tts_factory import TTSFactory
from cache_manager import CacheManager
from progress_tracker import ProgressTracker
from utils import (
    sanitize_filename, get_chapter_filename, print_book_info, 
    print_conversion_summary, format_file_size, format_duration,
    estimate_audio_duration, clean_temp_files, validate_audio_file
)


class EbookToAudioConverter:
    """Conversor principal com progresso em tempo real e ETA."""
    
    def __init__(self, config: Config, tts_factory: TTSFactory, cache_manager: CacheManager):
        """
        Inicializa o conversor.
        
        Args:
            config: Configurações da conversão
            tts_factory: Factory para criação de engines TTS
            cache_manager: Gerenciador de cache
        """
        self.config = config
        self.tts_factory = tts_factory
        self.cache_manager = cache_manager
        self.output_dir = None
        self.progress_tracker = None
        self.conversion_start_time = None
        
    def convert(self) -> None:
        """Executa a conversão completa do ebook para audiolivro."""
        try:
            self._setup_conversion()
            self._show_conversion_info()
            self._execute_conversion()
            self._show_final_summary()
        except Exception as e:
            print(f"\n❌ ERRO durante conversão: {e}")
            raise
        finally:
            self._cleanup()
    
    def _setup_conversion(self) -> None:
        """Configura ambiente para conversão."""
        # Cria diretório de saída
        self.output_dir = Path(sanitize_filename(self.config.book_title))
        self.output_dir.mkdir(parents=True, exist_ok=True)
        
        # Inicializa tracker de progresso
        total_chars = self.config.get_total_chars()
        total_chapters = self.config.get_total_chapters()
        self.progress_tracker = ProgressTracker(total_chapters, total_chars)
        
        # Limpa arquivos temporários antigos
        clean_temp_files(self.output_dir)
        clean_temp_files(Path("."))
        
        # Marca início da conversão
        self.conversion_start_time = time.time()
    
    def _show_conversion_info(self) -> None:
        """Mostra informações da conversão."""
        model_info = self.config.get_model_short_name()
        if self.config.engine == "coqui" and self.config.engine_config.get('speaker'):
            speaker = self.config.engine_config['speaker']
            if isinstance(speaker, str) and speaker.endswith('.wav'):
                model_info += " (voz clonada)"
            else:
                model_info += f" - {speaker}"
        
        print_book_info(
            self.config.book_title,
            self.config.author,
            self.config.chapters,
            self.config.engine,
            model_info,
            self.config.output_format
        )
        
        print(f"Pasta de saída: {self.output_dir.resolve()}")
        
        # Estima duração total
        total_chars = self.config.get_total_chars()
        estimated_minutes = estimate_audio_duration(total_chars)
        print(f"Duração estimada: ~{format_duration(estimated_minutes * 60)}")
        
        # Verifica se há cache
        cache_dir = self.cache_manager.check_existing_cache(self.config.book_title.split('_')[0])
        if cache_dir:
            print(f"Cache: {cache_dir}")
        
        print("=" * 60)
    
    def _execute_conversion(self) -> None:
        """Executa a conversão de todos os capítulos com progresso em tempo real."""
        if not self.config.chapters:
            raise ValueError("Nenhum capítulo encontrado para conversão")
        
        # Cria engine TTS
        tts_engine = self.tts_factory.create_engine(
            self.config.engine, 
            self.config.engine_config
        )
        
        total_chapters = self.config.get_total_chapters()
        success_count = 0
        
        print(f"\n🎙️ CONVERTENDO {total_chapters} CAPÍTULOS")
        print("=" * 60)
        
        for idx, (title, text) in enumerate(self.config.chapters, start=1):
            success = self._convert_chapter_with_progress(
                idx, title, text, total_chapters, tts_engine
            )
            if success:
                success_count += 1
        
        self.success_count = success_count
        self.total_chapters = total_chapters
    
    def _convert_chapter_with_progress(self, idx: int, title: str, text: str, 
                                     total: int, tts_engine) -> bool:
        """
        Converte um capítulo com progresso em tempo real.
        
        Args:
            idx: Índice do capítulo
            title: Título do capítulo
            text: Texto do capítulo
            total: Total de capítulos
            tts_engine: Engine TTS para usar
            
        Returns:
            True se conversão foi bem-sucedida
        """
        # Gera nome do arquivo
        mp3_name = get_chapter_filename(idx, total, title)
        mp3_path = self.output_dir / mp3_name
        
        # Verifica se já existe (e --no-cache)
        if mp3_path.exists() and validate_audio_file(mp3_path) and not self.config.force_reprocess:
            print(f"⏭️ [{idx:03d}/{total}] '{title}' - arquivo já existe")
            self.progress_tracker.complete_item(len(text))
            self._show_overall_progress(idx, total)  # Mostra progresso mesmo para arquivos existentes
            return True
        
        # Remove arquivo existente se --no-cache
        if mp3_path.exists() and self.config.force_reprocess:
            try:
                mp3_path.unlink()
                print(f"🔄 Removendo arquivo existente (--no-cache)")
            except:
                pass
        
        # Mostra informações do capítulo
        self._show_chapter_start(idx, total, title, text)
        
        # Mostra progresso ANTES de começar a conversão
        self._show_processing_progress(idx, total)
        
        try:
            # Inicia contagem de tempo
            self.progress_tracker.start_item()
            chapter_start_time = time.time()
            
            # Executa síntese com callback de progresso
            print(f"    🎙️ Convertendo... ", end="", flush=True)
            tts_engine.synthesize(text, mp3_path)
            print("✓")  # Marca conversão completa
            
            # Calcula tempo do capítulo
            chapter_elapsed = time.time() - chapter_start_time
            
            # Marca como completo
            self.progress_tracker.complete_item(len(text))
            
            # Verifica se arquivo foi criado corretamente
            if validate_audio_file(mp3_path):
                self._show_chapter_success(mp3_path, len(text), chapter_elapsed)
                self._show_overall_progress(idx, total)  # Progresso atualizado
                return True
            else:
                print(f"    ❌ ERRO: Arquivo criado é inválido")
                return False
                
        except Exception as e:
            print(f"    ❌ ERRO: {e}")
            self.progress_tracker.complete_item(0)
            return False
    
    def _show_chapter_start(self, idx: int, total: int, title: str, text: str) -> None:
        """Mostra informações do capítulo sendo processado."""
        # Título truncado se muito longo
        display_title = title[:50] + ('...' if len(title) > 50 else '')
        print(f"\n🎙️ [{idx:03d}/{total}] '{display_title}'")
        print(f"    📝 {len(text):,} caracteres | ~{estimate_audio_duration(len(text)):.1f}min estimado")
        
        # Mostra chunks se texto for grande
        max_chunk = 8000 if self.config.engine == "edge" else 1500
        if len(text) > max_chunk:
            import re
            chunks = re.split(r'(\.\.\. \.\.\.)', text)
            chunk_count = len([c for c in chunks if c.strip() and c != "... ..."])
            print(f"    📦 Será dividido em ~{chunk_count} partes")
    
    def _show_chapter_success(self, mp3_path: Path, char_count: int, chapter_time: float) -> None:
        """Mostra informações de sucesso da conversão."""
        file_size = mp3_path.stat().st_size
        file_size_str = format_file_size(file_size)
        
        # Estima duração
        duration_minutes = estimate_audio_duration(char_count)
        duration_str = format_duration(duration_minutes * 60)
        
        # Velocidade do capítulo
        chars_per_sec = char_count / chapter_time if chapter_time > 0 else 0
        
        print(f"    ✅ Criado: {mp3_path.name}")
        print(f"    📊 {file_size_str} | ~{duration_str} | {chars_per_sec:.0f} chars/s")
    
    def _show_processing_progress(self, current: int, total: int) -> None:
        """Mostra progresso ANTES de começar a processar o capítulo."""
        progress_pct = ((current - 1) / total) * 100  # current-1 porque ainda não processou
        
        # Barra de progresso simples
        bar_width = 30
        filled = int(bar_width * (current - 1) / total)
        bar = "█" * filled + "▓" + "░" * (bar_width - filled - 1)  # ▓ = processando atual
        
        print(f"    📊 [{bar}] {progress_pct:.1f}% - Processando capítulo {current}/{total}")
    
    def _show_overall_progress(self, current: int, total: int) -> None:
        """Mostra progresso geral da conversão APÓS completar um capítulo."""
        progress_pct = (current / total) * 100
        
        # Calcula ETA baseado no progresso
        elapsed = time.time() - self.conversion_start_time
        if current > 0:
            avg_time_per_chapter = elapsed / current
            remaining_chapters = total - current
            eta_seconds = remaining_chapters * avg_time_per_chapter
            eta_str = format_duration(eta_seconds)
        else:
            eta_str = "Calculando..."
        
        # Barra de progresso atualizada
        bar_width = 30
        filled = int(bar_width * current / total)
        bar = "█" * filled + "░" * (bar_width - filled)
        
        print(f"    ✅ Concluído: [{bar}] {progress_pct:.1f}%")
        print(f"    ⏱️ Decorrido: {format_duration(elapsed)} | ETA: {eta_str}")
        
        # Velocidade média se disponível
        if self.progress_tracker.speeds:
            avg_speed = sum(self.progress_tracker.speeds) / len(self.progress_tracker.speeds)
            print(f"    ⚡ Velocidade: {avg_speed:.0f} chars/s")
        
        print()  # Linha em branco para separar capítulos
    
    def _show_final_summary(self) -> None:
        """Mostra resumo final da conversão."""
        # Calcula estatísticas
        total_size = sum(
            f.stat().st_size for f in self.output_dir.glob("*.mp3")
        ) / (1024 * 1024)  # MB
        
        total_chars = self.config.get_total_chars()
        estimated_duration_minutes = estimate_audio_duration(total_chars)
        estimated_duration_str = format_duration(estimated_duration_minutes * 60)
        
        total_elapsed = time.time() - self.conversion_start_time
        elapsed_time = format_duration(total_elapsed)
        
        print_conversion_summary(
            self.success_count,
            self.total_chapters,
            self.output_dir,
            elapsed_time,
            total_size,
            estimated_duration_str
        )
        
        # Mostra velocidade média final
        if self.progress_tracker.speeds:
            avg_speed = sum(self.progress_tracker.speeds) / len(self.progress_tracker.speeds)
            print(f"⚡ Velocidade média final: {avg_speed:.0f} chars/s")
            
            # Calcula eficiência
            total_chars = self.config.get_total_chars()
            theoretical_time = total_chars / avg_speed if avg_speed > 0 else 0
            efficiency = (theoretical_time / total_elapsed * 100) if total_elapsed > 0 else 0
            print(f"📈 Eficiência: {efficiency:.1f}% (tempo puro TTS vs total)")
        
        # Estatísticas do arquivo
        mp3_files = list(self.output_dir.glob("*.mp3"))
        if mp3_files:
            avg_file_size = sum(f.stat().st_size for f in mp3_files) / len(mp3_files) / 1024 / 1024
            print(f"📁 {len(mp3_files)} arquivos | Tamanho médio: {avg_file_size:.1f}MB")
        
        # Info sobre cache
        original_title = self.config.book_title.split('_')[0]  # Remove engine suffix
        cache_dir = self.cache_manager.check_existing_cache(original_title)
        if cache_dir:
            print(f"📁 Cache mantido: {cache_dir}")
            print("💡 Para reprocessar: use --no-cache")
        
        print("=" * 60)
    
    def _cleanup(self) -> None:
        """Limpa arquivos temporários."""
        if self.output_dir:
            clean_temp_files(self.output_dir)
        
        # Remove arquivos de preview
        for preview_file in Path(".").glob(".preview-*"):
            try:
                preview_file.unlink()
            except:
                pass