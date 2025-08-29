# -*- coding: utf-8 -*-
"""
Conversor principal - orchestrates EPUB to audio conversion
Segue princípios SOLID e padrões de design
"""

import asyncio
import time
from pathlib import Path
from typing import List, Dict, Any, Optional, Callable
from dataclasses import dataclass
from datetime import datetime

from .ebook_reader import EbookReader
from .tts import create_tts_engine, TTSEngine
from .progress_tracker import ProgressTracker
from .cache_manager import CacheManager
from .utils import sanitize_filename, validate_audio_file


@dataclass
class ConversionConfig:
    """Configuração para conversão (Data Transfer Object)"""
    engine: str
    voice: str
    output_dir: Path
    chunk_size: Optional[int] = None
    use_cache: bool = True
    skip_existing: bool = True
    max_retries: int = 3
    engine_config: Dict[str, Any] = None
    
    def __post_init__(self):
        if self.engine_config is None:
            self.engine_config = {}


class ConversionStrategy:
    """Strategy para diferentes tipos de conversão"""
    
    def __init__(self, tts_engine: TTSEngine, config: ConversionConfig):
        self.tts_engine = tts_engine
        self.config = config
    
    async def convert_chapter(self, chapter, progress_callback: Callable = None) -> bool:
        """Converte um único capítulo"""
        if not chapter.text or not chapter.text.strip():
            if progress_callback:
                progress_callback(f"⚠️  Pulando capítulo vazio: {chapter.title}")
            return True
        
        # Sanitiza nome do arquivo
        safe_title = sanitize_filename(chapter.title)
        filename = f"{str(chapter.index).zfill(3)} - {safe_title}.mp3"
        output_path = self.config.output_dir / filename
        
        # Pula se arquivo já existe
        if self.config.skip_existing and output_path.exists():
            if validate_audio_file(output_path):
                if progress_callback:
                    progress_callback(f"✅ Já existe: {filename}")
                return True
        
        # Callback de progresso
        if progress_callback:
            progress_callback(f"🎵 Convertendo: {chapter.title} ({len(chapter.text)} chars)")
        
        # Converte com retries
        for attempt in range(self.config.max_retries):
            try:
                success = await self.tts_engine.synthesize(chapter.text, output_path)
                
                if success and validate_audio_file(output_path):
                    if progress_callback:
                        progress_callback(f"✅ Salvo: {filename}")
                    return True
                elif attempt < self.config.max_retries - 1:
                    if progress_callback:
                        progress_callback(f"🔄 Tentativa {attempt + 2}: {filename}")
                    await asyncio.sleep(2)  # Pausa antes de retry
                    
            except Exception as e:
                if attempt < self.config.max_retries - 1:
                    if progress_callback:
                        progress_callback(f"🔄 Erro (tentativa {attempt + 2}): {e}")
                    await asyncio.sleep(2)
                else:
                    if progress_callback:
                        progress_callback(f"❌ Falhou após {self.config.max_retries} tentativas: {e}")
        
        return False


class AudioBookConverter:
    """Conversor principal de EPUB para audiobook"""
    
    def __init__(self, config: ConversionConfig):
        self.config = config
        self.cache_manager = CacheManager() if config.use_cache else None
        self.progress_tracker = None
        self.tts_engine = None
    
    def _setup_tts_engine(self) -> None:
        """Configura engine TTS"""
        try:
            self.tts_engine = create_tts_engine(
                self.config.engine,
                self.config.voice,
                **self.config.engine_config
            )
            
            # Ajusta chunk size se não especificado
            if self.config.chunk_size is None:
                self.config.chunk_size = self.tts_engine.get_max_chunk_size()
                
        except Exception as e:
            raise RuntimeError(f"Erro ao inicializar engine {self.config.engine}: {e}")
    
    def _prepare_output_directory(self) -> None:
        """Prepara diretório de saída"""
        self.config.output_dir.mkdir(parents=True, exist_ok=True)
        
        # Cria arquivo de informações do livro
        info_file = self.config.output_dir / "book_info.txt"
        if not info_file.exists():
            with open(info_file, 'w', encoding='utf-8') as f:
                f.write(f"Audiobook convertido em: {datetime.now()}\n")
                f.write(f"Engine TTS: {self.config.engine}\n")
                f.write(f"Voz: {self.config.voice}\n")
    
    async def convert_ebook(self, ebook_path: Path, progress_callback: Callable = None) -> Dict[str, Any]:
        """
        Converte EPUB completo para audiobook
        
        Returns:
            Dict com resultados da conversão
        """
        start_time = time.time()
        conversion_results = {
            'success': False,
            'total_chapters': 0,
            'converted_chapters': 0,
            'failed_chapters': 0,
            'duration': 0,
            'output_dir': str(self.config.output_dir),
            'errors': []
        }
        
        try:
            # Setup inicial
            self._setup_tts_engine()
            self._prepare_output_directory()
            
            # Lê ebook
            if progress_callback:
                progress_callback("📖 Carregando ebook...")
            
            reader = EbookReader(ebook_path)
            self._reader = reader  # Mantém referência para _get_chapter_text
            
            # Usa estrutura hierárquica se disponível
            chapters = reader.get_chapter_structure()
            if not chapters:
                if progress_callback:
                    progress_callback("❌ Nenhum capítulo encontrado")
                return conversion_results
            
            # Flatten hierarquia se necessário
            flat_chapters = self._flatten_chapter_hierarchy(chapters)
            
            conversion_results['total_chapters'] = len(flat_chapters)
            
            # Setup progress tracker
            self.progress_tracker = ProgressTracker(
                total_items=len(flat_chapters),
                description="Convertendo capítulos"
            )
            
            if progress_callback:
                progress_callback(f"📚 {len(flat_chapters)} capítulos encontrados")
                progress_callback(f"🎵 Engine: {self.config.engine} - Voz: {self.config.voice}")
            
            # Converte capítulos
            conversion_strategy = ConversionStrategy(self.tts_engine, self.config)
            
            for i, chapter in enumerate(flat_chapters, 1):
                try:
                    # Progress callback customizado
                    def chapter_progress(msg):
                        if progress_callback:
                            progress_callback(f"[{i}/{len(flat_chapters)}] {msg}")
                        if self.progress_tracker:
                            self.progress_tracker.update(i, msg)
                    
                    success = await conversion_strategy.convert_chapter(
                        chapter, chapter_progress
                    )
                    
                    if success:
                        conversion_results['converted_chapters'] += 1
                    else:
                        conversion_results['failed_chapters'] += 1
                        conversion_results['errors'].append(f"Falha ao converter: {chapter.title}")
                        
                except Exception as e:
                    conversion_results['failed_chapters'] += 1
                    error_msg = f"Erro no capítulo {chapter.title}: {e}"
                    conversion_results['errors'].append(error_msg)
                    if progress_callback:
                        progress_callback(f"❌ {error_msg}")
            
            # Finalização
            conversion_results['duration'] = time.time() - start_time
            conversion_results['success'] = conversion_results['converted_chapters'] > 0
            
            # Cleanup
            if self.tts_engine:
                self.tts_engine.cleanup()
            
            # Log final
            if progress_callback:
                progress_callback(f"\n✅ Conversão concluída!")
                progress_callback(f"📊 Sucessos: {conversion_results['converted_chapters']}")
                progress_callback(f"📊 Falhas: {conversion_results['failed_chapters']}")
                progress_callback(f"⏱️  Tempo: {conversion_results['duration']:.1f}s")
                progress_callback(f"📁 Arquivos: {self.config.output_dir}")
                
        except Exception as e:
            conversion_results['errors'].append(str(e))
            if progress_callback:
                progress_callback(f"❌ Erro crítico: {e}")
        
        return conversion_results
    
    def _flatten_chapter_hierarchy(self, chapters) -> List:
        """Achata hierarquia de capítulos em lista linear"""
        flat_chapters = []
        
        def flatten_recursive(chapter_list):
            for chapter in chapter_list:
                # Adiciona capítulo se tem conteúdo
                if hasattr(chapter, 'text') and chapter.text and len(chapter.text.strip()) > 0:
                    from .ebook_reader import Chapter
                    
                    chapter_wrapper = Chapter(
                        index=chapter.index,
                        name=chapter.title,
                        source_path=getattr(chapter, 'src', ''),
                        text=chapter.text
                    )
                    flat_chapters.append(chapter_wrapper)
                elif hasattr(chapter, 'char_count') and chapter.char_count > 0 and not hasattr(chapter, 'text'):
                    # Fallback para capítulos antigos sem campo text
                    from .ebook_reader import Chapter
                    
                    placeholder_text = f"Capítulo: {chapter.title}\n\n[Conteúdo será carregado durante conversão]"
                    chapter_wrapper = Chapter(
                        index=chapter.index,
                        name=chapter.title,
                        source_path=getattr(chapter, 'src', ''),
                        text=placeholder_text
                    )
                    flat_chapters.append(chapter_wrapper)
                
                # Processa filhos se existirem
                if hasattr(chapter, 'children') and chapter.children:
                    flatten_recursive(chapter.children)
        
        flatten_recursive(chapters)
        return flat_chapters


# Função de conveniência
async def convert_ebook_to_audio(
    ebook_path: Path, 
    engine: str, 
    voice: str, 
    output_dir: Path,
    progress_callback: Callable = None,
    **kwargs
) -> Dict[str, Any]:
    """Função de conveniência para conversão"""
    
    config = ConversionConfig(
        engine=engine,
        voice=voice,
        output_dir=output_dir,
        **kwargs
    )
    
    converter = AudioBookConverter(config)
    return await converter.convert_ebook(ebook_path, progress_callback)