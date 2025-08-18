"""
src/converter.py

Conversor principal que orquestra todo o processo de conversão.
"""

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
    """Conversor principal que orquestra todo o processo de conversão."""
    
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
        
        # Verifica se há cache
        cache_dir = self.cache_manager.check_existing_cache(self.config.book_title)
        if cache_dir:
            print(f"Cache: {cache_dir}")
        
        print("=" * 60)
    
    def _execute_conversion(self) -> None:
        """Executa a conversão de todos os capítulos."""
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
        print("-" * 60)
        
        for idx, (title, text) in enumerate(self.config.chapters, start=1):
            success = self._convert_chapter(
                idx, title, text, total_chapters, tts_engine
            )
            if success:
                success_count += 1
        
        self.success_count = success_count
        self.total_chapters = total_chapters
    
    def _convert_chapter(self, idx: int, title: str, text: str, 
                        total: int, tts_engine) -> bool:
        """
        Converte um capítulo individual.
        
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
        
        # Verifica se já existe
        if mp3_path.exists() and validate_audio_file(mp3_path):
            print(f"⏭️ [{idx:03d}/{total}] '{title}' - arquivo já existe")
            self.progress_tracker.complete_item(len(text))
            return True
        
        # Mostra informações do capítulo
        self._show_chapter_info(idx, total, title, text)
        
        try:
            # Inicia contagem de tempo
            self.progress_tracker.start_item()
            
            # Executa síntese
            tts_engine.synthesize(text, mp3_path)
            
            # Marca como completo
            self.progress_tracker.complete_item(len(text))
            
            # Verifica se arquivo foi criado corretamente
            if validate_audio_file(mp3_path):
                self._show_chapter_success(mp3_path, len(text))
                return True
            else:
                print(f"    ❌ ERRO: Arquivo criado é inválido")
                return False
                
        except Exception as e:
            print(f"    ❌ ERRO: {e}")
            self.progress_tracker.complete_item(0)  # Marca como completo mas sem chars processados
            return False
    
    def _show_chapter_info(self, idx: int, total: int, title: str, text: str) -> None:
        """Mostra informações do capítulo sendo processado."""
        # Título truncado se muito longo
        display_title = title[:50] + ('...' if len(title) > 50 else '')
        print(f"🎙️ [{idx:03d}/{total}] '{display_title}'")
        print(f"    📝 {len(text):,} caracteres", end="")
        
        # Mostra chunks se texto for grande
        max_chunk = 8000 if self.config.engine == "edge" else 1500
        if len(text) > max_chunk:
            # Função simples para calcular chunks
            import re
            chunks = re.split(r'(\.\.\. \.\.\.)', text)
            chunk_count = len([c for c in chunks if c.strip() and c != "... ..."])
            print(f" | ~{chunk_count} partes")
        else:
            print()
        
        # Mostra ETA e velocidade se disponível
        if self.progress_tracker.speeds:
            remaining_chars = sum(
                len(ch[1]) for ch in self.config.chapters[idx:]
            )
            eta = self.progress_tracker.get_eta(remaining_chars)
            speed = self.progress_tracker.get_speed()
            elapsed = self.progress_tracker.get_elapsed()
            print(f"    ⏱️ Tempo decorrido: {elapsed} | Velocidade: {speed}")
            print(f"    🎯 ETA: {eta}")
    
    def _show_chapter_success(self, mp3_path: Path, char_count: int) -> None:
        """Mostra informações de sucesso da conversão."""
        file_size = mp3_path.stat().st_size
        file_size_str = format_file_size(file_size)
        
        # Estima duração
        duration_minutes = estimate_audio_duration(char_count)
        duration_str = format_duration(duration_minutes * 60)
        
        print(f"    ✅ Criado: {mp3_path.name} ({file_size_str}, ~{duration_str})")
        print()
    
    def _show_final_summary(self) -> None:
        """Mostra resumo final da conversão."""
        # Calcula estatísticas
        total_size = sum(
            f.stat().st_size for f in self.output_dir.glob("*.mp3")
        ) / (1024 * 1024)  # MB
        
        total_chars = self.config.get_total_chars()
        estimated_duration_minutes = estimate_audio_duration(total_chars)
        estimated_duration_str = format_duration(estimated_duration_minutes * 60)
        
        elapsed_time = self.progress_tracker.get_elapsed()
        
        print_conversion_summary(
            self.success_count,
            self.total_chapters,
            self.output_dir,
            elapsed_time,
            total_size,
            estimated_duration_str
        )
        
        # Mostra velocidade média se disponível
        if self.progress_tracker.speeds:
            avg_speed = sum(self.progress_tracker.speeds) / len(self.progress_tracker.speeds)
            print(f"⚡ Velocidade média: {avg_speed:.0f} chars/s")
        
        # Info sobre cache
        cache_dir = self.cache_manager.check_existing_cache(self.config.book_title)
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