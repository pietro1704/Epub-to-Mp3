"""
Sistema de retry automático para segmentos faltantes.

Este módulo fornece retry automático para segmentos que falharam durante
a conversão TTS, tentando reconvertê-los e inserir no lugar correto.
"""

import logging
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Protocol

from python_app.src.synthesis_tracker import SegmentRecord

logger = logging.getLogger(__name__)


@dataclass
class RetryReport:
    """Retry attempt report."""

    total_retried: int
    successful: int
    still_failed: int
    failed_segments: List[SegmentRecord]
    retry_details: List[Dict[str, Any]]


class RetryableEngine(Protocol):
    """Protocol para engines que suportam retry de segmentos."""

    async def synthesize_segment(
        self,
        text: str,
        output_path: Path,
        formatting_segments: List[tuple] = None,
    ) -> bool:
        """
        Sintetiza um único segmento de texto.

        Args:
            text: Texto a ser sintetizado
            output_path: Caminho para salvar o áudio
            formatting_segments: Segmentos de formatação (opcional)

        Returns:
            True se sucesso, False caso contrário
        """
        ...


class RetryManager:
    """Automatic retry manager for missing segments."""

    MAX_RETRIES = 3

    def __init__(self, max_retries: int = MAX_RETRIES):
        """
        Inicializa o gerenciador de retry.

        Args:
            max_retries: Número máximo de tentativas por segmento
        """
        self.max_retries = max_retries
        self.retry_history: List[Dict[str, Any]] = []

    async def retry_failed_segments(
        self,
        engine: Any,  # TTSEngine with synthesize_segment support
        failed_segments: List[SegmentRecord],
        output_path: Path,
        temp_dir: Path,
    ) -> RetryReport:
        """
        Tenta reconverter segmentos que falharam.

        Args:
            engine: Engine TTS a ser usado para retry
            failed_segments: Lista de segmentos que falharam
            output_path: Caminho do arquivo MP3 final
            temp_dir: Diretório temporário para arquivos de retry

        Returns:
            RetryReport com resultados das tentativas
        """
        temp_dir.mkdir(parents=True, exist_ok=True)
        retry_results = []
        still_failed_segments = []

        logger.info(
            f"Starting retry for {len(failed_segments)} failed segments "
            f"(max {self.max_retries} attempts each)"
        )

        for segment in failed_segments:
            success = False

            for attempt in range(1, self.max_retries + 1):
                logger.info(
                    f"Retry attempt {attempt}/{self.max_retries} for segment {segment.index}"
                )

                # Tentar reconverter apenas este segmento
                temp_path = temp_dir / f"retry_{segment.index}_{attempt}.mp3"

                try:
                    # Verificar se engine suporta synthesize_segment
                    if hasattr(engine, "synthesize_segment"):
                        success = await engine.synthesize_segment(segment.text, temp_path)
                    elif hasattr(engine, "synthesize_async"):
                        # Fallback: usar synthesize_async
                        result = await engine.synthesize_async(
                            segment.text,
                            temp_path,
                            formatting_segments=[],
                            progress_callback=None,
                            chunk_callback=None,
                        )
                        success = result is not None
                    else:
                        logger.error("Engine does not support segment synthesis")
                        success = False

                    if success and temp_path.exists():
                        logger.info(f"✓ Segment {segment.index} recovered on attempt {attempt}")

                        retry_results.append(
                            {
                                "segment_index": segment.index,
                                "status": "success",
                                "attempt": attempt,
                                "audio_path": str(temp_path),
                            }
                        )
                        break  # Success, move to next segment

                except Exception as e:
                    logger.warning(
                        f"Retry attempt {attempt} failed for segment {segment.index}: {e}"
                    )
                    success = False

            if not success:
                logger.error(
                    f"✗ Segment {segment.index} still failed after {self.max_retries} attempts"
                )
                still_failed_segments.append(segment)
                retry_results.append(
                    {
                        "segment_index": segment.index,
                        "status": "failed",
                        "attempts": self.max_retries,
                    }
                )

        # Statistics
        successful_retries = len([r for r in retry_results if r.get("status") == "success"])

        report = RetryReport(
            total_retried=len(failed_segments),
            successful=successful_retries,
            still_failed=len(still_failed_segments),
            failed_segments=still_failed_segments,
            retry_details=retry_results,
        )

        logger.info(
            f"Retry complete: {report.successful}/{report.total_retried} recovered, "
            f"{report.still_failed} still failed"
        )

        return report

    def _inject_audio_at_position(self, main_file: Path, segment_file: Path, position: int) -> bool:
        """
        Insere áudio de um segmento no lugar correto do arquivo principal.

        NOTA: Esta é uma operação complexa que requer:
        1. Ler o arquivo principal
        2. Dividir nas posições corretas
        3. Inserir o novo segmento
        4. Concatenar tudo

        Por enquanto, esta função apenas documenta a interface.
        A implementação real será feita quando integrarmos com os engines.

        Args:
            main_file: Arquivo MP3 principal
            segment_file: Arquivo do segmento a inserir
            position: Posição (índice) onde inserir

        Returns:
            True se sucesso, False caso contrário
        """
        logger.warning(
            "Audio injection not yet implemented. "
            "Segments will need to be reprocessed in full chapter conversion."
        )
        return False
