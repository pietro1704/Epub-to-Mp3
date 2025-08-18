"""
src/cache_manager.py

Gerenciador de cache para otimizar reprocessamento de arquivos.
"""

import json
from pathlib import Path
from typing import List, Tuple, Dict, Optional, Union
from utils import sanitize_filename, zero_pad


class CacheManager:
    """Gerencia cache de livros processados para otimizar conversões."""
    
    def __init__(self, cache_dir: str = ".cache"):
        """
        Inicializa o gerenciador de cache.
        
        Args:
            cache_dir: Diretório base para armazenar cache
        """
        self.cache_base_dir = Path(cache_dir)
        self.cache_base_dir.mkdir(parents=True, exist_ok=True)
    
    def create_cache_structure(self, book_title: str, chapters: List[Tuple[str, str]]) -> Path:
        """
        Cria/atualiza estrutura de cache com textos separados.
        
        Args:
            book_title: Título do livro
            chapters: Lista de tuplas (título_capítulo, texto)
            
        Returns:
            Caminho do diretório de cache criado
        """
        cache_dir = self.cache_base_dir / sanitize_filename(book_title)
        cache_dir.mkdir(parents=True, exist_ok=True)
        
        # Cria metadados
        metadata = {
            "title": book_title,
            "total_chapters": len(chapters),
            "chapters": [],
            "created_at": str(Path.cwd()),
            "processed": True
        }
        
        # Remove arquivos de texto antigos
        for old_file in cache_dir.glob("*.txt"):
            try:
                old_file.unlink()
            except:
                pass
        
        # Cria arquivos de texto para cada capítulo
        for idx, (title, text) in enumerate(chapters, start=1):
            index_str = zero_pad(idx, len(chapters))
            safe_title = sanitize_filename(title)
            txt_name = f"{index_str} - {safe_title}.txt"
            txt_path = cache_dir / txt_name
            
            # Salva texto do capítulo
            with open(txt_path, 'w', encoding='utf-8') as f:
                f.write(text)
            
            # Adiciona metadados do capítulo
            metadata["chapters"].append({
                "index": idx,
                "title": title,
                "txt_file": txt_name,
                "char_count": len(text)
            })
        
        # Salva metadados
        metadata_path = cache_dir / "metadata.json"
        with open(metadata_path, 'w', encoding='utf-8') as f:
            json.dump(metadata, f, indent=2, ensure_ascii=False)
        
        print(f"📁 Cache atualizado: {cache_dir} ({len(chapters)} capítulos)")
        return cache_dir
    
    def load_from_cache(self, cache_dir: Path) -> Tuple[Dict, List[Tuple[str, str]]]:
        """
        Carrega capítulos do cache.
        
        Args:
            cache_dir: Diretório do cache
            
        Returns:
            Tupla com (metadados, lista_de_capítulos)
            
        Raises:
            FileNotFoundError: Se cache não encontrado ou corrompido
        """
        metadata_file = cache_dir / "metadata.json"
        if not metadata_file.exists():
            raise FileNotFoundError("Cache metadata não encontrado")
        
        # Carrega metadados
        with open(metadata_file, 'r', encoding='utf-8') as f:
            metadata = json.load(f)
        
        chapters = []
        missing_files = []
        
        # Carrega textos dos capítulos
        for ch_meta in metadata["chapters"]:
            txt_path = cache_dir / ch_meta["txt_file"]
            if txt_path.exists():
                with open(txt_path, 'r', encoding='utf-8') as f:
                    text = f.read()
                chapters.append((ch_meta["title"], text))
            else:
                missing_files.append(ch_meta["txt_file"])
        
        if missing_files:
            raise FileNotFoundError(f"Arquivos de cache em falta: {missing_files}")
        
        return metadata, chapters
    
    def check_existing_cache(self, book_title: str) -> Optional[Path]:
        """
        Verifica se já existe cache para o livro.
        
        Args:
            book_title: Título do livro
            
        Returns:
            Caminho do cache se existir, None caso contrário
        """
        cache_dir = self.cache_base_dir / sanitize_filename(book_title)
        metadata_file = cache_dir / "metadata.json"
        
        if cache_dir.exists() and metadata_file.exists():
            return cache_dir
        return None
    
    def delete_cache(self, book_title: str) -> bool:
        """
        Remove cache de um livro específico.
        
        Args:
            book_title: Título do livro
            
        Returns:
            True se removido com sucesso
        """
        cache_dir = self.cache_base_dir / sanitize_filename(book_title)
        
        if cache_dir.exists():
            try:
                import shutil
                shutil.rmtree(cache_dir)
                return True
            except Exception as e:
                print(f"❌ Erro ao remover cache: {e}")
                return False
        
        return False
    
    def list_cached_books(self) -> List[Dict]:
        """
        Lista todos os livros em cache.
        
        Returns:
            Lista de dicionários com informações dos livros em cache
        """
        cached_books = []
        
        for cache_dir in self.cache_base_dir.iterdir():
            if cache_dir.is_dir():
                metadata_file = cache_dir / "metadata.json"
                if metadata_file.exists():
                    try:
                        with open(metadata_file, 'r', encoding='utf-8') as f:
                            metadata = json.load(f)
                        
                        cached_books.append({
                            "title": metadata.get("title", cache_dir.name),
                            "chapters": metadata.get("total_chapters", 0),
                            "cache_dir": str(cache_dir),
                            "size_mb": self._get_directory_size(cache_dir)
                        })
                    except Exception:
                        continue
        
        return cached_books
    
    def _get_directory_size(self, directory: Path) -> float:
        """
        Calcula tamanho de um diretório em MB.
        
        Args:
            directory: Caminho do diretório
            
        Returns:
            Tamanho em MB
        """
        total_size = 0
        try:
            for file_path in directory.rglob('*'):
                if file_path.is_file():
                    total_size += file_path.stat().st_size
        except Exception:
            pass
        
        return total_size / (1024 * 1024)  # Converte para MB
    
    def cleanup_old_caches(self, max_age_days: int = 30) -> int:
        """
        Remove caches antigos baseado na idade.
        
        Args:
            max_age_days: Idade máxima em dias
            
        Returns:
            Número de caches removidos
        """
        import time
        from datetime import datetime, timedelta
        
        cutoff_time = time.time() - (max_age_days * 24 * 60 * 60)
        removed_count = 0
        
        for cache_dir in self.cache_base_dir.iterdir():
            if cache_dir.is_dir():
                try:
                    # Verifica idade do diretório
                    dir_mtime = cache_dir.stat().st_mtime
                    if dir_mtime < cutoff_time:
                        import shutil
                        shutil.rmtree(cache_dir)
                        removed_count += 1
                        print(f"🗑️ Cache antigo removido: {cache_dir.name}")
                except Exception:
                    continue
        
        return removed_count