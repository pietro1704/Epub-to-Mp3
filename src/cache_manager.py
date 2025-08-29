# -*- coding: utf-8 -*-
"""
Gerenciador de cache para ebooks processados
"""

import json
import hashlib
from pathlib import Path
from typing import Dict, Any, Optional
from datetime import datetime


class CacheManager:
    """Gerenciador de cache inteligente para ebooks"""
    
    def __init__(self, cache_dir: Path = None):
        self.cache_dir = cache_dir or Path(".cache")
        self.cache_dir.mkdir(exist_ok=True)
    
    def _get_ebook_hash(self, ebook_path: Path) -> str:
        """Gera hash único para o ebook"""
        # Usa stat do arquivo + nome para gerar hash único
        stat = ebook_path.stat()
        hash_input = f"{ebook_path.name}_{stat.st_size}_{stat.st_mtime}"
        return hashlib.md5(hash_input.encode()).hexdigest()[:12]
    
    def _get_cache_path(self, ebook_path: Path) -> Path:
        """Retorna caminho do cache para o ebook"""
        ebook_hash = self._get_ebook_hash(ebook_path)
        safe_name = self._sanitize_filename(ebook_path.stem)
        return self.cache_dir / f"{safe_name}_{ebook_hash}"
    
    def get_cached_chapters(self, ebook_path: Path) -> Optional[Dict[str, Any]]:
        """Retorna capítulos cacheados se existirem"""
        cache_path = self._get_cache_path(ebook_path)
        metadata_file = cache_path / "metadata.json"
        
        if not metadata_file.exists():
            return None
        
        try:
            with open(metadata_file, 'r', encoding='utf-8') as f:
                metadata = json.load(f)
            
            # Valida se cache ainda é válido
            if self._is_cache_valid(metadata, ebook_path):
                return metadata
            else:
                # Remove cache inválido
                self._cleanup_cache(cache_path)
                return None
                
        except Exception:
            return None
    
    def save_chapters_to_cache(self, ebook_path: Path, chapters_data: Dict[str, Any]) -> bool:
        """Salva capítulos processados no cache"""
        try:
            cache_path = self._get_cache_path(ebook_path)
            cache_path.mkdir(exist_ok=True)
            
            # Metadados do cache
            cache_metadata = {
                'ebook_path': str(ebook_path),
                'ebook_hash': self._get_ebook_hash(ebook_path),
                'cached_at': datetime.now().isoformat(),
                'chapters_count': len(chapters_data.get('chapters', [])),
                'title': chapters_data.get('title', ''),
                'author': chapters_data.get('author', ''),
                'chapters': chapters_data.get('chapters', [])
            }
            
            # Salva metadata
            metadata_file = cache_path / "metadata.json"
            with open(metadata_file, 'w', encoding='utf-8') as f:
                json.dump(cache_metadata, f, ensure_ascii=False, indent=2)
            
            # Salva capítulos individuais como TXT
            for i, chapter in enumerate(cache_metadata['chapters'], 1):
                chapter_file = cache_path / f"{i:03d}_{self._sanitize_filename(chapter.get('title', 'Chapter'))}.txt"
                with open(chapter_file, 'w', encoding='utf-8') as f:
                    f.write(f"# {chapter.get('title', 'Untitled')}\n\n")
                    f.write(chapter.get('text', ''))
            
            return True
            
        except Exception as e:
            print(f"⚠️  Erro ao salvar cache: {e}")
            return False
    
    def _is_cache_valid(self, metadata: Dict[str, Any], ebook_path: Path) -> bool:
        """Verifica se cache ainda é válido"""
        try:
            # Verifica se hash do arquivo ainda é o mesmo
            current_hash = self._get_ebook_hash(ebook_path)
            cached_hash = metadata.get('ebook_hash', '')
            
            return current_hash == cached_hash
            
        except Exception:
            return False
    
    def _cleanup_cache(self, cache_path: Path) -> None:
        """Remove cache inválido"""
        try:
            import shutil
            if cache_path.exists():
                shutil.rmtree(cache_path)
        except Exception:
            pass
    
    def clear_cache(self, ebook_path: Path = None) -> bool:
        """Limpa cache (específico ou todo)"""
        try:
            if ebook_path:
                # Limpa cache específico
                cache_path = self._get_cache_path(ebook_path)
                self._cleanup_cache(cache_path)
            else:
                # Limpa todo o cache
                import shutil
                if self.cache_dir.exists():
                    shutil.rmtree(self.cache_dir)
                    self.cache_dir.mkdir(exist_ok=True)
            
            return True
            
        except Exception as e:
            print(f"⚠️  Erro ao limpar cache: {e}")
            return False
    
    def get_cache_info(self) -> Dict[str, Any]:
        """Retorna informações sobre o cache"""
        try:
            if not self.cache_dir.exists():
                return {'total_cached_books': 0, 'cache_size_mb': 0}
            
            cached_books = []
            total_size = 0
            
            for cache_folder in self.cache_dir.iterdir():
                if cache_folder.is_dir():
                    metadata_file = cache_folder / "metadata.json"
                    if metadata_file.exists():
                        try:
                            with open(metadata_file, 'r', encoding='utf-8') as f:
                                metadata = json.load(f)
                            
                            folder_size = sum(f.stat().st_size for f in cache_folder.rglob('*') if f.is_file())
                            total_size += folder_size
                            
                            cached_books.append({
                                'title': metadata.get('title', 'Unknown'),
                                'cached_at': metadata.get('cached_at', ''),
                                'chapters_count': metadata.get('chapters_count', 0),
                                'size_mb': folder_size / 1024 / 1024
                            })
                            
                        except Exception:
                            continue
            
            return {
                'total_cached_books': len(cached_books),
                'cache_size_mb': total_size / 1024 / 1024,
                'cached_books': cached_books
            }
            
        except Exception:
            return {'total_cached_books': 0, 'cache_size_mb': 0}
    
    def _sanitize_filename(self, filename: str) -> str:
        """Sanitiza nome de arquivo"""
        import re
        # Remove caracteres inválidos
        safe = re.sub(r'[<>:"/\\|?*]', '', filename)
        safe = re.sub(r'\s+', '_', safe)
        return safe[:50]  # Limita tamanho