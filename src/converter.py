"""
src/converter.py

Conversor principal com nomes de arquivos baseados na estrutura original e progresso avançado.
"""

import time
from pathlib import Path
from typing import List, Tuple

from config import Config
from tts_factory import TTSFactory
from cache_manager import CacheManager
from progress_tracker import ProgressTracker
from utils import (
    sanitize_filename, format_file_size, format_duration,
    estimate_audio_duration, clean_temp_files, validate_audio_file
)


class EbookToAudioConverter:
    """Conversor principal com progresso em tempo real e nomes estruturados."""
    
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
        self.chapter_structure = []  # NOVA: estrutura detalhada dos capítulos
        
    def set_chapter_structure(self, chapter_structure):
        """NOVA: Define estrutura detalhada dos capítulos."""
        self.chapter_structure = chapter_structure
        
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
        
        print(f"\n📖 INFORMAÇÕES DO LIVRO")
        print("=" * 60)
        print(f"Engine: {self.config.engine.upper()}")
        if self.config.author:
            print(f"Autor: {self.config.author}")
        print(f"Título: {self.config.book_title}")
        print(f"Capítulos: {len(self.config.chapters)}")
        print(f"Total de caracteres: {self.config.get_total_chars():,}")
        print(f"Modelo/Voz: {model_info}")
        print(f"Formato original: {self.config.output_format}")
        print(f"Pasta de saída: {self.output_dir.resolve()}")
        
        # Estima duração total
        total_chars = self.config.get_total_chars()
        estimated_minutes = estimate_audio_duration(total_chars)
        print(f"Duração estimada: ~{format_duration(estimated_minutes * 60)}")
        
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
            # NOVA: Usa estrutura detalhada se disponível
            chapter_info = None
            if self.chapter_structure and idx <= len(self.chapter_structure):
                chapter_info = self.chapter_structure[idx - 1]
            
            success = self._convert_chapter_with_progress(
                idx, title, text, total_chapters, tts_engine, chapter_info
            )
            if success:
                success_count += 1
        
        self.success_count = success_count
        self.total_chapters = total_chapters
    
    def _convert_chapter_with_progress(self, idx: int, title: str, text: str, 
                                     total: int, tts_engine, chapter_info=None) -> bool:
        """
        Converte um capítulo com progresso em tempo real e nomes estruturados.
        """
        # NOVA: Gera nome de arquivo baseado na estrutura original
        mp3_name = self._generate_structured_filename(idx, title, total, chapter_info)
        mp3_path = self.output_dir / mp3_name
        
        # Verifica se já existe (e --no-cache)
        if mp3_path.exists() and validate_audio_file(mp3_path) and not self.config.force_reprocess:
            print(f"⏭️ [{idx:03d}/{total}] '{title}' - arquivo já existe")
            self.progress_tracker.complete_item(len(text))
            return True
        
        # Remove arquivo existente se --no-cache
        if mp3_path.exists() and self.config.force_reprocess:
            try:
                mp3_path.unlink()
            except:
                pass
        
        # Inicia progresso do item
        display_title = title[:60] + ('...' if len(title) > 60 else '')
        self.progress_tracker.start_item(display_title)
        
        # Mostra informações detalhadas do capítulo
        self._show_chapter_details(idx, total, title, text, chapter_info)
        
        try:
            chapter_start_time = time.time()
            
            # NOVA: Mostra progresso de chunks se necessário
            max_chunk = 8000 if self.config.engine == "edge" else 1500
            if len(text) > max_chunk:
                estimated_chunks = len(text) // max_chunk + 1
                print(f"    📦 Processando em ~{estimated_chunks} partes")
                
                # Hook para mostrar progresso de chunks (implementar no engine se necessário)
                if hasattr(tts_engine, 'set_progress_callback'):
                    tts_engine.set_progress_callback(self.progress_tracker.show_item_progress)
            
            # Executa síntese
            print(f"    🎙️ Convertendo...", end=" ", flush=True)
            tts_engine.synthesize(text, mp3_path)
            print("✓")
            
            # Calcula tempo do capítulo
            chapter_elapsed = time.time() - chapter_start_time
            
            # Marca como completo
            self.progress_tracker.complete_item(len(text))
            
            # Verifica se arquivo foi criado corretamente
            if validate_audio_file(mp3_path):
                self._show_chapter_success(mp3_path, len(text), chapter_elapsed, title)
                return True
            else:
                print(f"    ❌ ERRO: Arquivo criado é inválido")
                return False
                
        except Exception as e:
            print(f"    ❌ ERRO: {e}")
            self.progress_tracker.complete_item(0)
            return False
    
    def _generate_structured_filename(self, idx: int, title: str, total: int, chapter_info=None) -> str:
        """
        NOVA: Gera nome de arquivo baseado na estrutura original do EPUB.
        
        Formatos:
        - Capítulo principal: "001 - Título do Capítulo.mp3"
        - Subcapítulo: "001.1 - Subtítulo.mp3"  
        - Com numeração original: "Cap01 - Título.mp3"
        """
        # Padding baseado no total
        width = max(2, len(str(total)))
        
        if chapter_info:
            # Usa estrutura detalhada
            if chapter_info.level > 1:
                # Subcapítulo - encontra capítulo pai
                parent_idx = self._find_parent_chapter_index(idx, chapter_info.level)
                if parent_idx:
                    index_str = f"{parent_idx:0{width}d}.{chapter_info.level - 1}"
                else:
                    index_str = f"{idx:0{width}d}.{chapter_info.level - 1}"
            else:
                # Capítulo principal
                index_str = f"{idx:0{width}d}"
            
            # Usa título limpo da estrutura
            clean_title = sanitize_filename(chapter_info.title)
        else:
            # Fallback para método original
            index_str = f"{idx:0{width}d}"
            clean_title = sanitize_filename(title)
        
        return f"{index_str} - {clean_title}.mp3"
    
    def _find_parent_chapter_index(self, current_idx: int, current_level: int) -> int:
        """Encontra índice do capítulo pai para subcapítulos."""
        if not self.chapter_structure:
            return current_idx
        
        # Procura para trás o último capítulo de nível inferior
        for i in range(current_idx - 2, -1, -1):  # current_idx - 2 porque é 1-indexed
            if i < len(self.chapter_structure):
                chapter = self.chapter_structure[i]
                if chapter.level < current_level:
                    return i + 1  # Converte para 1-indexed
        
        return current_idx
    
    def _show_chapter_details(self, idx: int, total: int, title: str, text: str, chapter_info=None):
        """Mostra detalhes do capítulo sendo processado."""
        char_count = len(text)
        estimated_duration = estimate_audio_duration(char_count)
        
        # Informações básicas
        print(f"    📝 {char_count:,} caracteres | ~{estimated_duration:.1f}min estimado")
        
        # Informações da estrutura se disponível
        if chapter_info:
            level_indicator = "  " * (chapter_info.level - 1) + ("📖" if chapter_info.level == 1 else "📄")
            print(f"    {level_indicator} Nível {chapter_info.level}")
            if chapter_info.original_id:
                print(f"    🔗 ID original: {chapter_info.original_id}")
    
    def _show_chapter_success(self, mp3_path: Path, char_count: int, chapter_time: float, title: str):
        """Mostra informações de sucesso da conversão."""
        file_size = mp3_path.stat().st_size
        file_size_str = format_file_size(file_size)
        file_size_mb = file_size / (1024 * 1024)
        
        # Estima duração
        duration_minutes = estimate_audio_duration(char_count)
        duration_str = format_duration(duration_minutes * 60)
        
        # Usa método do progress_tracker para resumo consistente
        self.progress_tracker.show_chapter_summary(
            mp3_path.name, 
            file_size_mb, 
            duration_str, 
            chapter_time
        )
    
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
        
        # Usa resumo do progress_tracker
        self.progress_tracker.show_final_summary()
        
        # Informações adicionais específicas do conversor
        print(f"📁 Pasta de saída: {self.output_dir.resolve()}")
        print(f"💾 Tamanho total: {total_size:.1f}MB")
        print(f"⏰ Duração estimada: {estimated_duration_str}")
        
        if self.success_count < self.total_chapters:
            print(f"⚠️ {self.total_chapters - self.success_count} capítulos falharam")
            print("💡 Dica: Execute novamente para tentar os que falharam")
        
        # Info sobre cache
        original_title = self.config.book_title.split('_')[0]
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