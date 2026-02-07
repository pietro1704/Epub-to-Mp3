# -*- coding: utf-8 -*-
"""
Verificação de áudio por transcrição usando faster-whisper.

Transcreve cada segmento/capítulo de áudio gerado e compara com o texto original,
garantindo que o TTS realmente produziu o conteúdo correto.
"""

from __future__ import annotations

import difflib
import re
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional

_FASTER_WHISPER_AVAILABLE = False
try:
    from faster_whisper import WhisperModel

    _FASTER_WHISPER_AVAILABLE = True
except ImportError:
    WhisperModel = None  # type: ignore[assignment,misc]


def is_available() -> bool:
    """Return True if faster-whisper is installed."""
    return _FASTER_WHISPER_AVAILABLE


@dataclass
class VerificationResult:
    """Resultado da verificação de um segmento/capítulo de áudio."""

    transcribed_text: str
    original_text: str
    similarity_score: float  # 0.0 - 1.0
    passed: bool
    details: str = ""


# ── Text normalization ──────────────────────────────────────────────

# TTS formatting cues injected by the converter that the TTS reads aloud
# but Whisper may transcribe differently. Strip before comparison.
_TTS_CUE_PATTERNS = [
    r"\[\[lang:\w[\w-]*\]\]",  # [[lang:en]], [[lang:pt-BR]]
    r"\[\[/lang\]\]",  # [[/lang]]
    r"\bem\s+itálico\s*:\s*",  # "em itálico:"
    r"\bfim\s+do\s+itálico\b\.?",  # "fim do itálico"
    r"\bem\s+negrito\s*:\s*",  # "em negrito:"
    r"\bfim\s+do\s+negrito\b\.?",  # "fim do negrito"
    r"\bnota\s+de\s+rodapé\s*\d*\s*:",  # "nota de rodapé 1:"
    r"\bfim\s+da\s+nota\s+de\s+rodapé\b\.?",  # "fim da nota de rodapé"
]
_TTS_CUE_RE = re.compile("|".join(_TTS_CUE_PATTERNS), re.IGNORECASE)


def _strip_tts_cues(text: str) -> str:
    """Remove TTS formatting cues that don't represent real book content."""
    return _TTS_CUE_RE.sub(" ", text)


def _normalize_for_comparison(text: str) -> str:
    """Normalize text aggressively for STT comparison.

    - Strip TTS formatting cues
    - Unicode NFKC normalization (compose accented chars)
    - Lowercase
    - Remove all punctuation and special characters
    - Collapse whitespace
    - Strip leading chapter headers (repeated by TTS formatting)
    """
    text = _strip_tts_cues(text)
    # NFKC keeps accented chars composed (é stays é, not e + ´)
    text = unicodedata.normalize("NFKC", text)
    text = text.lower()
    # Remove punctuation but keep letters (including accented) and digits
    text = re.sub(r"[^\w\s]", " ", text)
    # Remove standalone single digits/numbers (page refs, footnote markers)
    text = re.sub(r"\b\d+\b", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text


def _extract_words(text: str) -> List[str]:
    """Extract word list from normalized text."""
    return _normalize_for_comparison(text).split()


def _word_similarity(words_a: List[str], words_b: List[str]) -> float:
    """Compute word-level similarity using SequenceMatcher on word lists."""
    if not words_a and not words_b:
        return 1.0
    if not words_a or not words_b:
        return 0.0
    return difflib.SequenceMatcher(None, words_a, words_b).ratio()


# ── Main verifier ───────────────────────────────────────────────────


class TranscriptionVerifier:
    """Verifica áudio gerado por TTS usando transcrição (faster-whisper)."""

    SIMILARITY_THRESHOLD = 0.75  # 75% — accounts for Whisper inaccuracies & multilingual content

    def __init__(
        self,
        model_size: str = "medium",
        language: Optional[str] = None,
        device: str = "auto",
    ) -> None:
        self._model_size = model_size
        self._language = language
        self._device = device
        self._model: Optional["WhisperModel"] = None

    def _ensure_model(self) -> "WhisperModel":
        """Carrega o modelo sob demanda (lazy loading)."""
        if self._model is None:
            # Workaround for OpenMP duplicate library conflict on macOS
            import os

            os.environ.setdefault("KMP_DUPLICATE_LIB_OK", "TRUE")

            if not _FASTER_WHISPER_AVAILABLE:
                raise RuntimeError(
                    "faster-whisper não está instalado. " "Instale com: pip install faster-whisper"
                )
            compute_type = "int8"
            device = self._device
            if device == "auto":
                try:
                    import torch

                    device = "cuda" if torch.cuda.is_available() else "cpu"
                except ImportError:
                    device = "cpu"
            self._model = WhisperModel(
                self._model_size,
                device=device,
                compute_type=compute_type,
            )
        return self._model

    def transcribe(self, audio_path: Path) -> str:
        """Transcreve um arquivo de áudio para texto."""
        model = self._ensure_model()
        kwargs = {}
        if self._language:
            kwargs["language"] = self._language
        segments, _info = model.transcribe(
            str(audio_path),
            beam_size=5,
            vad_filter=True,
            **kwargs,
        )
        return " ".join(seg.text.strip() for seg in segments)

    MULTILINGUAL_THRESHOLD = 0.40  # Lower threshold for multilingual content

    def verify_segment(
        self,
        audio_path: Path,
        original_text: str,
        threshold: Optional[float] = None,
    ) -> VerificationResult:
        """Transcreve segmento de áudio e compara com texto original."""
        if threshold is None:
            # Multilingual chapters get lower threshold (Whisper drops non-primary languages)
            if re.search(r"\[\[lang:", original_text):
                threshold = self.MULTILINGUAL_THRESHOLD
            else:
                threshold = self.SIMILARITY_THRESHOLD

        transcribed = self.transcribe(audio_path)

        # Word-level comparison after stripping TTS cues
        words_transcribed = _extract_words(transcribed)
        words_original = _extract_words(original_text)

        if not words_original:
            return VerificationResult(
                transcribed_text=transcribed,
                original_text=original_text,
                similarity_score=1.0,
                passed=True,
                details="Texto original vazio, nada para verificar",
            )

        similarity = _word_similarity(words_transcribed, words_original)

        passed = similarity >= threshold
        details = ""
        if not passed:
            details = (
                f"Similaridade {similarity:.1%} < {threshold:.0%}. "
                f"Transcrito: {len(words_transcribed)} palavras vs "
                f"Original: {len(words_original)} palavras"
            )

        return VerificationResult(
            transcribed_text=transcribed,
            original_text=original_text,
            similarity_score=similarity,
            passed=passed,
            details=details,
        )

    def verify_chapter(
        self,
        mp3_path: Path,
        original_text: str,
        threshold: Optional[float] = None,
    ) -> VerificationResult:
        """Verifica capítulo completo (MP3) contra texto original."""
        return self.verify_segment(mp3_path, original_text, threshold)

    def close(self) -> None:
        """Libera recursos do modelo."""
        self._model = None
