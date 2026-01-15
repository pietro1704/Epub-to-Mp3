"""
Sistema de rastreamento de segmentos de síntese de TTS.

Este módulo fornece rastreamento detalhado de cada segmento de texto enviado
para os motores TTS, permitindo validação de integridade e retry seletivo.
"""

import hashlib
import json
import re
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional


@dataclass
class SegmentRecord:
    """Registro de um segmento de texto processado pelo TTS."""

    index: int
    text: str
    text_hash: str
    char_count: int
    word_count: int
    estimated_duration_seconds: float
    audio_path: Optional[str] = None
    actual_duration_seconds: Optional[float] = None
    status: str = "pending"  # "pending", "success", "failed", "skipped"
    error: Optional[str] = None

    @staticmethod
    def create(index: int, text: str, words_per_minute: int = 150) -> "SegmentRecord":
        """Cria um novo registro de segmento."""
        text_hash = hashlib.md5(text.encode("utf-8")).hexdigest()
        char_count = len(text)

        # Contar palavras
        words = re.findall(r"\b\w+\b", text)
        word_count = len(words)

        # Estimar duração (palavras / palavras_por_minuto * 60)
        estimated_duration = (word_count / words_per_minute) * 60 if word_count > 0 else 0.0

        return SegmentRecord(
            index=index,
            text=text,
            text_hash=text_hash,
            char_count=char_count,
            word_count=word_count,
            estimated_duration_seconds=estimated_duration,
        )


@dataclass
class ValidationReport:
    """Relatório de validação de um capítulo."""

    is_valid: bool
    total_segments: int
    successful_segments: int
    failed_segments: int
    missing_segments: List[int]
    expected_duration: float
    actual_duration: float
    duration_diff_percent: float
    validation_errors: List[str]

    def to_dict(self) -> Dict[str, Any]:
        """Converte para dicionário."""
        return asdict(self)

    def save(self, path: Path) -> None:
        """Salva relatório em arquivo JSON."""
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(self.to_dict(), f, indent=2, ensure_ascii=False)

    @staticmethod
    def load(path: Path) -> "ValidationReport":
        """Carrega relatório de arquivo JSON."""
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return ValidationReport(**data)


class SynthesisTracker:
    """Rastreador de segmentos de síntese de TTS."""

    def __init__(self, chapter_title: str = "Unknown"):
        self.chapter_title = chapter_title
        self.segments: List[SegmentRecord] = []
        self._segment_map: Dict[int, SegmentRecord] = {}

    def record_segment(
        self,
        index: int,
        text: str,
        audio_path: Optional[Path] = None,
        duration: Optional[float] = None,
        status: str = "pending",
        error: Optional[str] = None,
    ) -> None:
        """
        Registra um segmento de texto.

        Args:
            index: Índice do segmento
            text: Texto do segmento
            audio_path: Caminho do arquivo de áudio (se gerado)
            duration: Duração real do áudio em segundos
            status: Status do segmento ("pending", "success", "failed", "skipped")
            error: Mensagem de erro (se houver)
        """
        if index not in self._segment_map:
            # Criar novo registro
            segment = SegmentRecord.create(index, text)
            self.segments.append(segment)
            self._segment_map[index] = segment
        else:
            # Atualizar registro existente
            segment = self._segment_map[index]

        # Atualizar campos
        segment.status = status
        segment.error = error

        if audio_path:
            segment.audio_path = str(audio_path)

        if duration is not None:
            segment.actual_duration_seconds = duration

    def get_segment(self, index: int) -> Optional[SegmentRecord]:
        """Retorna o registro de um segmento específico."""
        return self._segment_map.get(index)

    def get_missing_segments(self) -> List[SegmentRecord]:
        """Retorna lista de segmentos que falharam ou não foram processados."""
        return [s for s in self.segments if s.status in ("failed", "pending")]

    def get_successful_segments(self) -> List[SegmentRecord]:
        """Retorna lista de segmentos processados com sucesso."""
        return [s for s in self.segments if s.status == "success"]

    def validate_completeness(self, tolerance: float = 0.15) -> ValidationReport:
        """
        Valida se todos os segmentos foram processados corretamente.

        Args:
            tolerance: Tolerância para diferença de duração (default: 15%)

        Returns:
            ValidationReport com resultados da validação
        """
        total_segments = len(self.segments)
        successful = self.get_successful_segments()
        successful_count = len(successful)
        failed = self.get_missing_segments()
        failed_count = len(failed)
        missing_indices = [s.index for s in failed]

        # Calcular duração esperada vs. real
        expected_duration = sum(s.estimated_duration_seconds for s in self.segments)
        actual_duration = sum(
            s.actual_duration_seconds for s in successful if s.actual_duration_seconds is not None
        )

        # Calcular diferença percentual
        duration_diff_percent = 0.0
        if expected_duration > 0:
            duration_diff_percent = (
                (actual_duration - expected_duration) / expected_duration
            ) * 100

        # Validar
        validation_errors = []

        if failed_count > 0:
            validation_errors.append(
                f"{failed_count} segment(s) failed or not processed: {missing_indices}"
            )

        if abs(duration_diff_percent) > (tolerance * 100):
            validation_errors.append(
                f"Duration mismatch: expected {expected_duration:.1f}s, "
                f"got {actual_duration:.1f}s ({duration_diff_percent:+.1f}% diff)"
            )

        is_valid = len(validation_errors) == 0

        return ValidationReport(
            is_valid=is_valid,
            total_segments=total_segments,
            successful_segments=successful_count,
            failed_segments=failed_count,
            missing_segments=missing_indices,
            expected_duration=expected_duration,
            actual_duration=actual_duration,
            duration_diff_percent=duration_diff_percent,
            validation_errors=validation_errors,
        )

    def export_to_json(self, path: Path) -> None:
        """Exporta todos os registros para arquivo JSON."""
        path.parent.mkdir(parents=True, exist_ok=True)

        data = {
            "chapter_title": self.chapter_title,
            "total_segments": len(self.segments),
            "segments": [asdict(s) for s in self.segments],
        }

        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)

    @staticmethod
    def load_from_json(path: Path) -> "SynthesisTracker":
        """Carrega tracker de arquivo JSON."""
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)

        tracker = SynthesisTracker(chapter_title=data.get("chapter_title", "Unknown"))

        for seg_data in data.get("segments", []):
            segment = SegmentRecord(**seg_data)
            tracker.segments.append(segment)
            tracker._segment_map[segment.index] = segment

        return tracker

    def get_synthesis_log(self) -> List[Dict[str, Any]]:
        """Retorna log de síntese em formato de dicionário."""
        return [asdict(s) for s in self.segments]

    def __repr__(self) -> str:
        successful = len(self.get_successful_segments())
        failed = len(self.get_missing_segments())
        return (
            f"SynthesisTracker(chapter='{self.chapter_title}', "
            f"total={len(self.segments)}, success={successful}, failed={failed})"
        )
