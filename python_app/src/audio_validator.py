"""
Validador de áudio para verificar integridade e duração de arquivos MP3.

Este módulo fornece validação de arquivos de áudio gerados pelo TTS,
comparando duração esperada vs. real e verificando corrupção de arquivos.
"""

import re
from dataclasses import dataclass
from pathlib import Path
from typing import Optional


@dataclass
class ValidationResult:
    """Resultado de validação de áudio."""

    is_valid: bool
    expected_duration: float
    actual_duration: float
    duration_diff_percent: float
    error_message: Optional[str] = None


class AudioValidator:
    """Validador de áudio para arquivos MP3 gerados por TTS."""

    DEFAULT_WORDS_PER_MINUTE = 150  # Velocidade média de fala

    def __init__(self, words_per_minute: int = DEFAULT_WORDS_PER_MINUTE):
        """
        Inicializa o validador.

        Args:
            words_per_minute: Velocidade de fala esperada para cálculo de duração
        """
        self.words_per_minute = words_per_minute

    def estimate_duration(self, text: str) -> float:
        """
        Estima a duração esperada de um texto em segundos.

        Args:
            text: Texto a ser convertido

        Returns:
            Duração estimada em segundos
        """
        # Contar palavras
        words = re.findall(r"\b\w+\b", text)
        word_count = len(words)

        if word_count == 0:
            return 0.0

        # Duração = (palavras / palavras_por_minuto) * 60
        duration_seconds = (word_count / self.words_per_minute) * 60

        return duration_seconds

    def get_audio_duration(self, audio_path: Path) -> Optional[float]:
        """
        Obtém a duração real de um arquivo de áudio.

        Args:
            audio_path: Caminho do arquivo de áudio

        Returns:
            Duração em segundos, ou None se não for possível determinar
        """
        if not audio_path.exists():
            return None

        try:
            # Tentar usar mutagen (mais rápido e confiável)
            try:
                from mutagen.mp3 import MP3

                audio = MP3(str(audio_path))
                return audio.info.length
            except ImportError:
                pass

            # Fallback: usar pydub
            try:
                from pydub import AudioSegment

                audio = AudioSegment.from_mp3(str(audio_path))
                return len(audio) / 1000.0  # pydub retorna em milissegundos
            except ImportError:
                pass

            # Fallback: usar soundfile
            try:
                import soundfile as sf

                info = sf.info(str(audio_path))
                return info.duration
            except ImportError:
                pass

            # Se nenhuma biblioteca está disponível
            return None

        except Exception:
            return None

    def validate_audio_file(self, audio_path: Path) -> bool:
        """
        Verifica se um arquivo de áudio existe e não está corrompido.

        Args:
            audio_path: Caminho do arquivo de áudio

        Returns:
            True se o arquivo é válido, False caso contrário
        """
        if not audio_path.exists():
            return False

        # Verificar tamanho mínimo (1KB)
        if audio_path.stat().st_size < 1024:
            return False

        # Tentar obter duração (se falhar, arquivo pode estar corrompido)
        duration = self.get_audio_duration(audio_path)
        if duration is None or duration <= 0:
            return False

        return True

    def validate_duration(
        self, text: str, audio_path: Path, tolerance: float = 0.15
    ) -> ValidationResult:
        """
        Valida se a duração do áudio corresponde ao texto esperado.

        Args:
            text: Texto original
            audio_path: Caminho do arquivo de áudio gerado
            tolerance: Tolerância para diferença de duração (default: 15%)

        Returns:
            ValidationResult com detalhes da validação
        """
        # Estimar duração esperada
        expected_duration = self.estimate_duration(text)

        # Obter duração real
        actual_duration = self.get_audio_duration(audio_path)

        if actual_duration is None:
            return ValidationResult(
                is_valid=False,
                expected_duration=expected_duration,
                actual_duration=0.0,
                duration_diff_percent=0.0,
                error_message=f"Could not determine audio duration for {audio_path.name}",
            )

        # Calcular diferença percentual
        if expected_duration > 0:
            duration_diff_percent = (
                (actual_duration - expected_duration) / expected_duration
            ) * 100
        else:
            duration_diff_percent = 0.0

        # Validar
        is_valid = abs(duration_diff_percent) <= (tolerance * 100)

        error_message = None
        if not is_valid:
            error_message = (
                f"Duration mismatch: expected {expected_duration:.1f}s, "
                f"got {actual_duration:.1f}s ({duration_diff_percent:+.1f}% diff)"
            )

        return ValidationResult(
            is_valid=is_valid,
            expected_duration=expected_duration,
            actual_duration=actual_duration,
            duration_diff_percent=duration_diff_percent,
            error_message=error_message,
        )

    def validate_chapter(self, chapter_text: str, audio_path: Path) -> ValidationResult:
        """
        Valida um capítulo completo.

        Args:
            chapter_text: Texto do capítulo
            audio_path: Caminho do arquivo de áudio do capítulo

        Returns:
            ValidationResult com detalhes da validação
        """
        # Primeiro verificar se arquivo existe e não está corrompido
        if not self.validate_audio_file(audio_path):
            expected_duration = self.estimate_duration(chapter_text)
            return ValidationResult(
                is_valid=False,
                expected_duration=expected_duration,
                actual_duration=0.0,
                duration_diff_percent=0.0,
                error_message=f"Audio file is corrupted or missing: {audio_path.name}",
            )

        # Validar duração
        return self.validate_duration(chapter_text, audio_path)
