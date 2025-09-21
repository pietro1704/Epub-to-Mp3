# -*- coding: utf-8 -*-
"""
Gerenciador de checkpoint para conversões interrompidas
"""

import json
import time
from pathlib import Path
from typing import Dict, Any, Optional, List
from datetime import datetime
from dataclasses import dataclass


@dataclass
class ConversionCheckpoint:
    """Estado de checkpoint de uma conversão"""
    book_path: str
    book_title: str
    output_dir: str
    temp_dir: str
    total_chapters: int
    completed_chapters: List[int]
    current_chapter: Optional[int]
    conversion_config: Dict[str, Any]
    started_at: str
    last_updated: str


class CheckpointManager:
    """Gerenciador de checkpoints para conversões"""

    def __init__(self, checkpoint_dir: Optional[Path] = None):
        self.checkpoint_dir = checkpoint_dir or Path(".cache")
        self.checkpoint_dir.mkdir(parents=True, exist_ok=True)

    def _get_checkpoint_path(self, book_path: Path) -> Path:
        """Gera caminho do checkpoint para o livro"""
        import hashlib
        book_hash = hashlib.md5(str(book_path.absolute()).encode()).hexdigest()[:12]
        safe_name = self._sanitize_filename(book_path.stem)
        return self.checkpoint_dir / f"{safe_name}_{book_hash}.json"

    def save_checkpoint(self,
                       book_path: Path,
                       book_title: str,
                       output_dir: Path,
                       temp_dir: Path,
                       total_chapters: int,
                       completed_chapters: List[int],
                       current_chapter: Optional[int],
                       conversion_config: Dict[str, Any]) -> bool:
        """Salva checkpoint da conversão"""
        try:
            checkpoint = ConversionCheckpoint(
                book_path=str(book_path.absolute()),
                book_title=book_title,
                output_dir=str(output_dir),
                temp_dir=str(temp_dir),
                total_chapters=total_chapters,
                completed_chapters=completed_chapters.copy(),
                current_chapter=current_chapter,
                conversion_config=conversion_config,
                started_at=getattr(self, '_conversion_start_time', datetime.now().isoformat()),
                last_updated=datetime.now().isoformat()
            )

            checkpoint_path = self._get_checkpoint_path(book_path)
            with open(checkpoint_path, 'w', encoding='utf-8') as f:
                json.dump(checkpoint.__dict__, f, ensure_ascii=False, indent=2)

            return True

        except Exception as e:
            print(f"⚠️ Erro ao salvar checkpoint: {e}")
            return False

    def load_checkpoint(self, book_path: Path) -> Optional[ConversionCheckpoint]:
        """Carrega checkpoint da conversão"""
        try:
            checkpoint_path = self._get_checkpoint_path(book_path)
            if not checkpoint_path.exists():
                return None

            with open(checkpoint_path, 'r', encoding='utf-8') as f:
                data = json.load(f)

            return ConversionCheckpoint(**data)

        except Exception as e:
            print(f"⚠️ Erro ao carregar checkpoint: {e}")
            return None

    def clear_checkpoint(self, book_path: Path) -> bool:
        """Remove checkpoint da conversão"""
        try:
            checkpoint_path = self._get_checkpoint_path(book_path)
            if checkpoint_path.exists():
                checkpoint_path.unlink()
                return True
            return False

        except Exception as e:
            print(f"⚠️ Erro ao remover checkpoint: {e}")
            return False

    def has_checkpoint(self, book_path: Path) -> bool:
        """Verifica se existe checkpoint para o livro"""
        checkpoint_path = self._get_checkpoint_path(book_path)
        return checkpoint_path.exists()

    def validate_checkpoint(self, checkpoint: ConversionCheckpoint,
                          current_temp_dir: Path,
                          current_config: Dict[str, Any]) -> bool:
        """Valida se checkpoint é compatível com conversão atual"""
        try:
            # Verificar se diretório temporário ainda existe
            temp_dir = Path(checkpoint.temp_dir)
            if not temp_dir.exists():
                print(f"⚠️ Diretório temporário não encontrado: {temp_dir}")
                return False

            # Verificar se arquivos completados ainda existem
            for chapter_idx in checkpoint.completed_chapters:
                expected_files = list(temp_dir.glob(f"{chapter_idx:03d}_*.mp3"))
                if not expected_files:
                    print(f"⚠️ Arquivo do capítulo {chapter_idx} não encontrado")
                    return False

            # Verificar compatibilidade de configuração básica
            if checkpoint.conversion_config.get('engine') != current_config.get('engine'):
                print("⚠️ Engine TTS diferente - checkpoint incompatível")
                return False

            return True

        except Exception as e:
            print(f"⚠️ Erro na validação do checkpoint: {e}")
            return False

    def get_resume_info(self, checkpoint: ConversionCheckpoint) -> Dict[str, Any]:
        """Retorna informações para retomar conversão"""
        completed_count = len(checkpoint.completed_chapters)
        remaining_count = checkpoint.total_chapters - completed_count

        elapsed_time = "desconhecido"
        try:
            started = datetime.fromisoformat(checkpoint.started_at)
            last_updated = datetime.fromisoformat(checkpoint.last_updated)
            elapsed = last_updated - started
            elapsed_time = str(elapsed).split('.')[0]  # Remove microsegundos
        except:
            pass

        return {
            'completed_chapters': completed_count,
            'remaining_chapters': remaining_count,
            'progress_percentage': (completed_count / checkpoint.total_chapters) * 100,
            'elapsed_time': elapsed_time,
            'last_updated': checkpoint.last_updated,
            'temp_dir': checkpoint.temp_dir
        }

    def mark_conversion_start(self):
        """Marca início da conversão para controle de tempo"""
        self._conversion_start_time = datetime.now().isoformat()

    def list_checkpoints(self) -> List[Dict[str, Any]]:
        """Lista todos os checkpoints disponíveis"""
        checkpoints = []

        for checkpoint_file in self.checkpoint_dir.glob("*.json"):
            try:
                with open(checkpoint_file, 'r', encoding='utf-8') as f:
                    data = json.load(f)

                checkpoint = ConversionCheckpoint(**data)
                info = self.get_resume_info(checkpoint)

                checkpoints.append({
                    'book_title': checkpoint.book_title,
                    'book_path': checkpoint.book_path,
                    'progress': f"{info['completed_chapters']}/{checkpoint.total_chapters}",
                    'percentage': f"{info['progress_percentage']:.1f}%",
                    'last_updated': checkpoint.last_updated,
                    'elapsed_time': info['elapsed_time']
                })

            except Exception:
                continue

        return checkpoints

    def _sanitize_filename(self, filename: str) -> str:
        """Sanitiza nome de arquivo"""
        import re
        safe = re.sub(r'[<>:"/\\|?*]', '', filename)
        safe = re.sub(r'\s+', '_', safe)
        return safe[:50]


__all__ = ["CheckpointManager", "ConversionCheckpoint"]