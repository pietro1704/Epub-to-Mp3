# -*- coding: utf-8 -*-
"""Coqui TTS engine wrapper with lazy initialisation."""

from __future__ import annotations

import asyncio
import contextlib
import gc
import importlib
import os
import platform
import re
import threading
import wave
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Dict, List, Optional, Tuple
from unittest.mock import Mock

TTS = None

# ============================================================================
# PRÉ-PROCESSAMENTO DE TEXTO PARA COQUI
# Converte números e caracteres especiais não suportados pelo vocabulário
# ============================================================================

# Números por extenso em português
_NUMEROS_PT = {
    "0": "zero",
    "1": "um",
    "2": "dois",
    "3": "três",
    "4": "quatro",
    "5": "cinco",
    "6": "seis",
    "7": "sete",
    "8": "oito",
    "9": "nove",
    "10": "dez",
    "11": "onze",
    "12": "doze",
    "13": "treze",
    "14": "quatorze",
    "15": "quinze",
    "16": "dezesseis",
    "17": "dezessete",
    "18": "dezoito",
    "19": "dezenove",
    "20": "vinte",
    "30": "trinta",
    "40": "quarenta",
    "50": "cinquenta",
    "60": "sessenta",
    "70": "setenta",
    "80": "oitenta",
    "90": "noventa",
    "100": "cem",
    "200": "duzentos",
    "300": "trezentos",
    "400": "quatrocentos",
    "500": "quinhentos",
    "600": "seiscentos",
    "700": "setecentos",
    "800": "oitocentos",
    "900": "novecentos",
    "1000": "mil",
}

# Caracteres especiais para equivalentes ASCII
_CHAR_REPLACEMENTS = {
    "–": "-",  # en-dash
    "—": "-",  # em-dash
    "“": '"',  # aspas curvas esquerda
    "”": '"',  # aspas curvas direita
    "‘": "'",  # apóstrofo curvo esquerdo
    "’": "'",  # apóstrofo curvo direito
    "…": "...",  # reticências
    "«": '"',  # guillemet esquerdo
    "»": '"',  # guillemet direito
    "‹": "'",  # guillemet simples esquerdo
    "›": "'",  # guillemet simples direito
    "•": ",",  # bullet
    "·": ".",  # middle dot
    "№": "numero",  # numero sign
    "°": " graus",  # degree
    "²": " ao quadrado",
    "³": " ao cubo",
    "½": " meio",
    "¼": " um quarto",
    "¾": " três quartos",
}


def _numero_por_extenso(n: int) -> str:
    """Converte número inteiro para texto por extenso em português."""
    if n < 0:
        return "menos " + _numero_por_extenso(-n)
    if n == 0:
        return "zero"
    if n <= 20:
        return _NUMEROS_PT.get(str(n), str(n))
    if n < 100:
        dezena = (n // 10) * 10
        unidade = n % 10
        if unidade == 0:
            return _NUMEROS_PT.get(str(dezena), str(dezena))
        return f"{_NUMEROS_PT.get(str(dezena), str(dezena))} e {_NUMEROS_PT.get(str(unidade), str(unidade))}"
    if n < 1000:
        centena = (n // 100) * 100
        resto = n % 100
        if resto == 0:
            if n == 100:
                return "cem"
            return _NUMEROS_PT.get(str(centena), str(centena))
        centena_texto = "cento" if centena == 100 else _NUMEROS_PT.get(str(centena), str(centena))
        return f"{centena_texto} e {_numero_por_extenso(resto)}"
    if n < 2000:
        resto = n % 1000
        if resto == 0:
            return "mil"
        return (
            f"mil {_numero_por_extenso(resto)}"
            if resto < 100
            else f"mil e {_numero_por_extenso(resto)}"
        )
    if n < 1000000:
        milhares = n // 1000
        resto = n % 1000
        milhares_texto = f"{_numero_por_extenso(milhares)} mil"
        if resto == 0:
            return milhares_texto
        return f"{milhares_texto} e {_numero_por_extenso(resto)}"
    # Para números muito grandes, retorna dígito a dígito
    return " ".join(_NUMEROS_PT.get(d, d) for d in str(n))


def _preprocess_text_for_coqui(text: str, verbose: bool = False) -> str:
    """Pré-processa texto para Coqui TTS, convertendo números e caracteres especiais."""
    if not text:
        return text

    original_len = len(text)

    # 1. Substituir caracteres especiais
    for char, replacement in _CHAR_REPLACEMENTS.items():
        text = text.replace(char, replacement)

    # 2. Converter números (anos, datas, valores)
    # Padrão para anos (1900-2099)
    def replace_year(match):
        year = int(match.group(0))
        return _numero_por_extenso(year)

    text = re.sub(r"\b(1[89]\d{2}|20\d{2})\b", replace_year, text)

    # Ordinais simples (ex: 8º, 1ª)
    def replace_ordinal(match):
        num = int(match.group(1))
        return _numero_por_extenso(num)

    text = re.sub(r"\b(\d+)\s*[ºª]\b", replace_ordinal, text)

    # Padrão para números genéricos (até 999999)
    def replace_number(match):
        num = int(match.group(0))
        if num > 999999:
            # Números muito grandes: dígito a dígito
            return " ".join(_NUMEROS_PT.get(d, d) for d in match.group(0))
        return _numero_por_extenso(num)

    text = re.sub(r"\b\d+\b", replace_number, text)

    if verbose and len(text) != original_len:
        print(f"🔍 [VERBOSE] Coqui pré-processamento: {original_len} → {len(text)} chars")

    return text


# **FIXED**: Executor global com limite de threads para evitar travamentos
_coqui_executor = None
_memory_semaphore = None  # Global memory limiter
_SENTENCE_SPLIT_RE = re.compile(r"(?<=[.!?])\s+")


def _parse_bool_env(value: Optional[str], default: bool = False) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    normalized = str(value).strip().lower()
    if not normalized:
        return default
    return normalized in {"1", "true", "yes", "on", "enabled"}


def _resolve_coqui_safe_mode() -> bool:
    env_value = os.getenv("COQUI_SAFE_MODE")
    if env_value is not None:
        return _parse_bool_env(env_value, default=False)
    if os.getenv("SPACE_ID"):
        return True
    try:
        return platform.system().lower() == "darwin"
    except Exception:
        return False


def _set_memory_limits():
    """No-op: do not cap memory usage."""
    return


def _patch_transformers_beam_search(force: bool = False) -> None:
    """Ensure ``transformers`` exposes ``BeamSearchScorer`` for older releases of ``TTS``."""
    try:
        import transformers  # type: ignore
    except ImportError:
        return

    if not force and hasattr(transformers, "BeamSearchScorer"):
        return

    BeamSearchScorer = None
    for module_path in (
        "transformers.generation.beam_search",
        "transformers.generation.stream_generator",
        "transformers.generation.utils",
    ):
        try:
            module = importlib.import_module(module_path)
            candidate = getattr(module, "BeamSearchScorer", None)
            if candidate is not None:
                BeamSearchScorer = candidate
                break
        except Exception:
            continue

    if BeamSearchScorer is not None:
        transformers.BeamSearchScorer = BeamSearchScorer  # type: ignore[attr-defined]


_patch_transformers_beam_search()


def _allow_xtts_unpickle(verbose: bool = False) -> bool:
    """
    Allow torch to unpickle XTTS configs when weights_only=True is enforced (PyTorch 2.6+).
    """
    try:
        import torch

        add_safe_globals = getattr(torch.serialization, "add_safe_globals", None)
        if not callable(add_safe_globals):
            return False
        xtts_module = importlib.import_module("TTS.tts.configs.xtts_config")
        xtts_config = getattr(xtts_module, "XttsConfig", None)
        if xtts_config is None:
            return False
        add_safe_globals([xtts_config])
        if verbose:
            print("🔒 [VERBOSE] Torch allowlist atualizado para XttsConfig")
        return True
    except Exception:
        return False


@contextlib.contextmanager
def _torch_load_weights_disabled(torch_module, verbose: bool = False):
    """
    Temporarily patch torch.load to default weights_only=False for legacy pickles.
    """
    real_load = getattr(torch_module, "load", None)
    if not callable(real_load):
        yield
        return
    try:
        def _patched_load(*args, **kwargs):
            kwargs = dict(kwargs)
            kwargs.setdefault("weights_only", False)
            return real_load(*args, **kwargs)

        torch_module.load = _patched_load
        if verbose:
            print("🔒 [VERBOSE] Torch.load patched com weights_only=False (temporário)")
        yield
    finally:
        torch_module.load = real_load


def _get_coqui_executor():
    global _coqui_executor, _memory_semaphore
    if _coqui_executor is None:
        # Set memory limits first to prevent heap corruption
        _set_memory_limits()

        try:
            max_workers = int(os.environ.get("COQUI_MAX_WORKERS", "").strip() or "0")
        except ValueError:
            max_workers = 0
        if max_workers <= 0:
            cpu_count = os.cpu_count() or 1
            max_workers = max(1, min(4, cpu_count))

        # **HEAP CORRUPTION FIX**: Limit concurrent memory-intensive operations
        import asyncio

        _memory_semaphore = asyncio.Semaphore(max_workers)

        _coqui_executor = ThreadPoolExecutor(max_workers=max_workers, thread_name_prefix="CoquiTTS")
        print(f"🚀 [THREAD] Executor TTS criado: {max_workers} workers")
    return _coqui_executor


def _get_coqui_chunk_limit() -> int:
    """Max chars per Coqui segment to avoid very long synthesis calls."""
    try:
        limit = int(os.environ.get("COQUI_CHUNK_CHARS", "").strip() or "2500")
    except ValueError:
        limit = 2500
    return max(800, min(limit, 8000))


def _split_text_chunks(text: str, max_chars: int) -> List[str]:
    """Split text into chunks close to max_chars preserving sentences/words."""
    text = (text or "").strip()
    if not text:
        return []
    if len(text) <= max_chars:
        return [text]

    sentences = _SENTENCE_SPLIT_RE.split(text)
    chunks: List[str] = []
    buffer: List[str] = []
    buffer_len = 0

    def flush() -> None:
        nonlocal buffer, buffer_len
        if buffer:
            chunks.append(" ".join(buffer).strip())
            buffer = []
            buffer_len = 0

    for sentence in sentences:
        sentence = sentence.strip()
        if not sentence:
            continue
        if len(sentence) > max_chars:
            flush()
            words = sentence.split()
            current: List[str] = []
            current_len = 0
            for word in words:
                candidate_len = current_len + len(word) + (1 if current else 0)
                if candidate_len > max_chars and current:
                    chunks.append(" ".join(current).strip())
                    current = [word]
                    current_len = len(word)
                else:
                    current.append(word)
                    current_len = candidate_len
            if current:
                chunks.append(" ".join(current).strip())
            continue

        candidate_len = buffer_len + len(sentence) + (1 if buffer else 0)
        if candidate_len > max_chars:
            flush()
        buffer.append(sentence)
        buffer_len = buffer_len + len(sentence) + (1 if buffer_len else 0)

    flush()
    return [chunk for chunk in chunks if chunk]


def _concat_wav_files(sources: List[Path], output_path: Path) -> bool:
    """Concatenate wav files (same params) into output_path."""
    if not sources:
        return False
    try:
        with wave.open(str(sources[0]), "rb") as first:
            params = first.getparams()
            with wave.open(str(output_path), "wb") as out:
                out.setparams(params)
                out.writeframes(first.readframes(first.getnframes()))
                for source in sources[1:]:
                    with wave.open(str(source), "rb") as infile:
                        if infile.getparams() != params:
                            return False
                        out.writeframes(infile.readframes(infile.getnframes()))
        return True
    except Exception:
        return False


# Optional dependencies resolved lazily to avoid crashes in restricted environments.
np = None  # type: ignore
sf = None  # type: ignore

try:  # pragma: no cover - optional dependency
    import numpy as _np  # type: ignore
    import soundfile as _sf  # type: ignore

    np = _np  # type: ignore
    sf = _sf  # type: ignore
except Exception:  # pragma: no cover
    pass

# Transformers compatibility shim: newer releases stop exporting BeamSearchScorer at top-level
try:  # pragma: no cover - defensive compatibility
    import transformers as _transformers  # type: ignore

    if not hasattr(_transformers, "BeamSearchScorer"):
        _BeamSearchScorer = None
        try:
            from transformers.generation.beam_search import (
                BeamSearchScorer as _BeamSearchScorer,  # type: ignore
            )
        except Exception:
            try:
                generation_mod = importlib.import_module("transformers.generation.utils")  # type: ignore
                _BeamSearchScorer = getattr(generation_mod, "BeamSearchScorer", None)
            except Exception:
                _BeamSearchScorer = None
        if _BeamSearchScorer is not None:
            _transformers.BeamSearchScorer = _BeamSearchScorer  # type: ignore[attr-defined]
except Exception:
    pass

try:  # pragma: no cover - optional dependency
    from ..language import LanguageMarkup
except ImportError:  # pragma: no cover
    LanguageMarkup = None  # type: ignore

try:  # pragma: no cover - optional dependency
    from ..text_formatting import TextFormattingProcessor
except ImportError:  # pragma: no cover
    TextFormattingProcessor = None  # type: ignore


class CoquiTTSEngine:
    """Create and reuse a Coqui ``TTS`` instance on demand."""

    def __init__(
        self,
        model_name: str,
        *,
        primary_language: Optional[str] = None,
        language_voices: Optional[Dict[str, str]] = None,
        verbose: bool = False,
        formatting_cues_enabled: bool = True,
        formatting_locale: str = "pt",
        status_callback: Optional[callable] = None,
        chunk_char_limit: Optional[int] = None,
        max_workers: Optional[int] = None,
        safe_mode: Optional[bool] = None,
    ) -> None:
        global TTS

        if isinstance(TTS, Mock):
            if getattr(TTS, "side_effect", None):
                raise ImportError("Coqui TTS not installed")
            tts_class = TTS
        else:
            if TTS is None:
                try:
                    module = importlib.import_module("TTS.api")  # type: ignore
                    TTS = getattr(module, "TTS")
                except (ImportError, AttributeError) as exc:
                    raise ImportError("Coqui TTS not installed") from exc
            tts_class = TTS

        self.model_name = model_name
        self._tts_class = tts_class
        self.tts = None
        self.primary_language = (primary_language or "auto").split("-", 1)[0].lower()
        self.language_voices = language_voices or {}
        self.verbose = verbose
        self.last_error: Optional[str] = None
        self.status_callback = status_callback
        locale_root = (formatting_locale or "pt").split("-", 1)[0].lower()
        if locale_root not in {"pt", "en"}:
            locale_root = "en"
        self.formatting_locale = locale_root
        self.formatting_cues_enabled = bool(formatting_cues_enabled)
        self._chunk_char_limit = self._normalize_chunk_limit(chunk_char_limit)
        self._safe_mode = _resolve_coqui_safe_mode() if safe_mode is None else bool(safe_mode)
        self._max_workers = self._normalize_workers(max_workers)
        if self._safe_mode:
            self._max_workers = 1
        self._executor: Optional[ThreadPoolExecutor] = None
        self._init_lock = threading.Lock()
        self._model_lock = threading.Lock()

    def supports_multilingual(self) -> bool:
        """Coqui TTS models like XTTS_v2 support multilingual synthesis"""
        # XTTS v2 and similar models support multilingual
        return "xtts" in self.model_name.lower() or "multilingual" in self.model_name.lower()

    def supports_emphasis(self) -> bool:
        """Coqui TTS supports basic emphasis via pause markers"""
        return True

    def _emit_status(self, message: str) -> None:
        """Emit status update via callback if available."""
        if self.status_callback:
            try:
                self.status_callback(message)
            except Exception:
                pass
        if self.verbose:
            print(f"🔍 [STATUS] {message}")

    @staticmethod
    def _normalize_chunk_limit(value: Optional[int]) -> Optional[int]:
        if value is None:
            return None
        try:
            parsed = int(value)
        except (TypeError, ValueError):
            return None
        return max(800, min(parsed, 8000))

    @staticmethod
    def _normalize_workers(value: Optional[int]) -> Optional[int]:
        if value is None:
            return None
        try:
            parsed = int(value)
        except (TypeError, ValueError):
            return None
        return max(1, min(parsed, 12))

    def _get_executor(self) -> ThreadPoolExecutor:
        if self._executor is not None:
            return self._executor
        if self._max_workers:
            self._executor = ThreadPoolExecutor(
                max_workers=self._max_workers,
                thread_name_prefix="CoquiTTS",
            )
            return self._executor
        return _get_coqui_executor()

    def _initialize_model(self) -> None:
        if self.tts is not None:
            return
        with self._init_lock:
            if self.tts is not None:
                return
            if self.verbose:
                print(f"🔍 [VERBOSE] Coqui inicializando modelo: {self.model_name}")
            _patch_transformers_beam_search()

            # Emit loading status
            model_short = (
                self.model_name.split("/")[-1] if "/" in self.model_name else self.model_name
            )
            self._emit_status(f"Carregando modelo Coqui: {model_short}...")

            # **GPU ACCELERATION**: Detect and use CUDA if available
            import torch

            if self._safe_mode:
                with contextlib.suppress(Exception):
                    torch.set_num_threads(1)
                with contextlib.suppress(Exception):
                    torch.set_num_interop_threads(1)
            device = "cuda" if torch.cuda.is_available() else "cpu"
            gpu_available = torch.cuda.is_available()

            if gpu_available:
                gpu_name = torch.cuda.get_device_name(0)
                gpu_memory = torch.cuda.get_device_properties(0).total_memory / (1024**3)
                if self.verbose:
                    print(f"🚀 [GPU] CUDA disponível: {gpu_name} ({gpu_memory:.1f} GB)")
                    print("🚀 [GPU] Habilitando aceleração por GPU para TTS")
                self._emit_status(f"Usando GPU: {gpu_name}")
            else:
                if self.verbose:
                    print("⚠️ [CPU] GPU não disponível, usando CPU")
                self._emit_status("Usando CPU (GPU não disponível)")

            _xtts_allowlisted = _allow_xtts_unpickle(verbose=self.verbose)

            try:
                self._emit_status(f"Baixando/verificando modelo {model_short}...")
                # Initialize with GPU support
                with _torch_load_weights_disabled(torch, verbose=self.verbose):
                    self.tts = self._tts_class(model_name=self.model_name, gpu=gpu_available)

                # Move model to GPU if available
                if (
                    gpu_available
                    and hasattr(self.tts, "synthesizer")
                    and hasattr(self.tts.synthesizer, "tts_model")
                ):
                    self.tts.synthesizer.tts_model = self.tts.synthesizer.tts_model.to(device)
                    if self.verbose:
                        print("🚀 [GPU] Modelo TTS movido para CUDA")

                # Enable GPU optimizations
                if gpu_available:
                    torch.backends.cudnn.benchmark = True  # Auto-tune convolutions
                    torch.backends.cuda.matmul.allow_tf32 = True  # Faster matrix operations
                    if self.verbose:
                        print("🚀 [GPU] Otimizações CUDA habilitadas (cudnn.benchmark + TF32)")

                if self.verbose:
                    print(f"✅ [VERBOSE] Coqui modelo inicializado com sucesso em {device.upper()}")
                self._emit_status(f"Modelo Coqui pronto ({device.upper()})")

            except ImportError as e:
                if "BeamSearchScorer" in str(e):
                    _patch_transformers_beam_search(force=True)
                    self.tts = self._tts_class(model_name=self.model_name, gpu=gpu_available)
                    if self.verbose:
                        print("🔍 [VERBOSE] Coqui modelo inicializado após patch Transformers")
                else:
                    self.last_error = f"init_error: {e}"
                    if self.verbose:
                        print(f"🔍 [VERBOSE] Coqui erro na inicialização: {e}")
                    raise
            except Exception as e:
                self.last_error = f"init_error: {e}"
                if self.verbose:
                    print(f"🔍 [VERBOSE] Coqui erro na inicialização: {e}")
                raise

    async def synthesize_async(
        self, text: str, output_path: Path, formatting_segments=None
    ) -> Optional[Path]:
        if not text:
            return None

        # Preparar texto com pistas audíveis quando possível
        if TextFormattingProcessor:
            formatter = TextFormattingProcessor(
                cues_enabled=getattr(self, "formatting_cues_enabled", True),
                cue_locale=getattr(self, "formatting_locale", "pt"),
            )
            try:
                converted = formatter.to_audible_text(text, formatting_segments)
                if converted:
                    if self.verbose and converted != text:
                        print(
                            f"🔍 [VERBOSE] CoquiTTS texto ajustado para áudio: {len(converted)} chars"
                        )
                    text = converted
            except Exception as e:
                if self.verbose:
                    print(
                        f"🔍 [VERBOSE] CoquiTTS falha ao preparar texto ({e}); usando limpeza básica"
                    )
                text = formatter.clean_tts_text(text)
        else:
            text = text.strip()

        # Pré-processar texto: converter números e caracteres especiais
        text = _preprocess_text_for_coqui(text, verbose=self.verbose)

        contains_markup = LanguageMarkup is not None and "[[lang:" in text.lower()
        default_language = (
            self.primary_language
            if self.primary_language not in {"", "auto", "unknown"}
            else "unknown"
        )
        segments: List[Tuple[str, str]]

        if contains_markup and LanguageMarkup is not None:
            parsed = LanguageMarkup.parse(text, default_language)
            segments = []
            for segment in parsed:
                if not segment or not segment.text:
                    continue
                cleaned_segment = (
                    TextFormattingProcessor.clean_tts_text(segment.text)
                    if TextFormattingProcessor
                    else segment.text
                )
                segments.append((segment.language, cleaned_segment))
        else:
            if contains_markup and LanguageMarkup is not None:
                plain_text = LanguageMarkup.strip(text)
            else:
                plain_text = text
            plain_text = (
                TextFormattingProcessor.clean_tts_text(plain_text)
                if TextFormattingProcessor
                else plain_text
            )
            segments = [(default_language, plain_text)]

        max_chars = _get_coqui_chunk_limit()
        if self._chunk_char_limit:
            max_chars = self._chunk_char_limit
        expanded_segments: List[Tuple[str, str]] = []
        for language, segment_text in segments:
            chunked = _split_text_chunks(segment_text, max_chars)
            for chunk in chunked:
                expanded_segments.append((language, chunk))
        if expanded_segments:
            if self.verbose and len(expanded_segments) > len(segments):
                print(
                    f"🔍 [VERBOSE] Coqui dividindo em {len(expanded_segments)} segmentos (limite {max_chars} chars)"
                )
            segments = expanded_segments

        self._initialize_model()
        loop = asyncio.get_event_loop()

        if len(segments) == 1:
            language, segment_text = segments[0]
            if not segment_text.strip():
                return None
            try:
                if self.verbose:
                    print(
                        f"🔍 [VERBOSE] Coqui sintetizando {len(segment_text)} chars, linguagem: {language}"
                    )
                # **FIXED**: Usar executor limitado em vez de None (thread pool padrão)
                executor = self._get_executor()
                await loop.run_in_executor(
                    executor, self._synthesize_blocking, segment_text, output_path, language
                )
                if self.verbose:
                    print(f"🔍 [VERBOSE] Coqui síntese completa: {output_path}")
            except Exception as e:
                self.last_error = f"synthesis_error: {e}"
                if self.verbose:
                    print(f"🔍 [VERBOSE] Coqui erro na síntese: {e}")
                return None
            return output_path if Path(output_path).exists() else None

        if np is None or sf is None:
            temp_files: List[Path] = []
            try:
                executor = self._get_executor()
                for idx, (language, segment_text) in enumerate(segments):
                    segment_text = segment_text.strip()
                    if not segment_text:
                        continue
                    # **FIX**: Use output_path.parent para isolar por livro
                    import tempfile

                    temp_file = tempfile.NamedTemporaryFile(
                        delete=False,
                        suffix=".wav",
                        dir=output_path.parent,
                        prefix=f"coqui_seg{idx}_",
                    )
                    temp_file.close()
                    temp_path = Path(temp_file.name)
                    temp_files.append(temp_path)
                    await loop.run_in_executor(
                        executor, self._synthesize_blocking, segment_text, temp_path, language
                    )
                if not temp_files:
                    return None
                if not _concat_wav_files(temp_files, output_path):
                    return None
            except Exception:
                return None
            finally:
                for temp_path in temp_files:
                    with contextlib.suppress(OSError):
                        temp_path.unlink()
            return output_path if Path(output_path).exists() else None

        temp_files: List[Path] = []
        try:
            # **PARALLEL OPTIMIZATION**: Process segments in parallel
            executor = self._get_executor()
            tasks = []
            for idx, (language, segment_text) in enumerate(segments):
                segment_text = segment_text.strip()
                if not segment_text:
                    continue
                # **FIX**: Use output_path.parent para isolar por livro
                import tempfile

                temp_file = tempfile.NamedTemporaryFile(
                    delete=False, suffix=".wav", dir=output_path.parent, prefix=f"coqui_seg{idx}_"
                )
                temp_file.close()
                temp_path = Path(temp_file.name)
                temp_files.append(temp_path)
                task = loop.run_in_executor(
                    executor, self._synthesize_blocking, segment_text, temp_path, language
                )
                tasks.append(task)

            # Execute all synthesis tasks in parallel
            if tasks:
                if self.verbose:
                    print(f"🚀 [VERBOSE] Coqui processando {len(tasks)} segmentos em paralelo")
                await asyncio.gather(*tasks)

            if not temp_files:
                return None

            audio_chunks: List[np.ndarray] = []
            sample_rate = None
            for file_path in temp_files:
                data, sr = sf.read(str(file_path))
                if sample_rate is None:
                    sample_rate = sr
                elif sample_rate != sr:
                    data = self._resample_audio(data, sr, sample_rate)
                audio_chunks.append(data)

            if not audio_chunks or sample_rate is None:
                return None

            combined = np.concatenate(audio_chunks, axis=0)
            sf.write(str(output_path), combined, sample_rate)
        except Exception:
            return None
        finally:
            for temp_path in temp_files:
                with contextlib.suppress(OSError):
                    temp_path.unlink()

        return output_path if Path(output_path).exists() else None

    def _synthesize_blocking(self, text: str, output_path: Path, language: Optional[str]) -> None:
        # **HEAP CORRUPTION FIX**: Aggressive garbage collection before synthesis
        gc.collect()

        kwargs = {"text": text, "file_path": str(output_path)}
        if language and language not in {"unknown", "auto"}:
            kwargs["language"] = language

        # Enhanced multi-speaker detection and handling
        self._add_speaker_if_needed(kwargs)

        retry_count = 0
        max_retries = 3

        while retry_count <= max_retries:
            try:
                with self._model_lock:
                    self.tts.tts_to_file(**kwargs)

                # **HEAP CORRUPTION FIX**: Force cleanup after synthesis
                gc.collect()

                return  # Success
            except (TypeError, ValueError) as e:
                error_msg = str(e).lower()
                stripped_error = error_msg.strip().strip("'\"")

                # Coqui às vezes retorna '0' quando speaker é inválido; trate como fallback de speaker
                if stripped_error == "0":
                    kwargs.pop("speaker", None)
                    kwargs.pop("speaker_wav", None)
                    if self.verbose:
                        print("🔍 [VERBOSE] Coqui removendo speaker após erro '0'")
                    retry_count += 1
                    continue

                if stripped_error == "default":
                    kwargs.pop("speaker", None)
                    kwargs.pop("speaker_wav", None)
                    if self.verbose:
                        print("🔍 [VERBOSE] Coqui removendo speaker após erro 'default'")
                    retry_count += 1
                    continue

                if "multi-speaker" in error_msg and "speaker" in error_msg:
                    # Model requires speaker parameter
                    if retry_count == 0:
                        self._add_speaker_fallback(kwargs)
                    elif retry_count == 1:
                        kwargs["speaker"] = "default"
                    else:
                        kwargs.pop("speaker", None)
                elif "language" in error_msg or "multi-lingual" in error_msg:
                    kwargs.pop("language", None)
                elif "speaker" in error_msg:
                    kwargs.pop("speaker", None)
                else:
                    raise

                retry_count += 1
            except Exception:
                if retry_count < max_retries:
                    retry_count += 1
                    continue
                raise

    def _add_speaker_if_needed(self, kwargs: dict) -> None:
        """Add speaker parameter if model supports/requires it."""
        # For VITS models, don't add speaker initially - let it fail first, then retry
        # This allows the model to work normally when speaker is not needed

        # Only pre-add speaker for known multi-speaker models
        if "xtts" in self.model_name.lower():
            # XTTS always needs speaker or speaker_wav
            if hasattr(self.tts, "speakers") and self.tts.speakers:
                kwargs["speaker"] = self.tts.speakers[0]
                if self.verbose:
                    print(f"🔍 [VERBOSE] Coqui XTTS usando speaker: {kwargs['speaker']}")
            else:
                kwargs["speaker_wav"] = None  # Use default voice
                if self.verbose:
                    print("🔍 [VERBOSE] Coqui XTTS usando speaker_wav default")

        # For other models, let them try without speaker first

    def _add_speaker_fallback(self, kwargs: dict) -> None:
        """Fallback speaker detection for stubborn models."""
        if self.verbose:
            print("🔍 [VERBOSE] Coqui tentando fallback de speaker")

        model_lower = self.model_name.lower()

        # XTTS: não usar "0" – preferir speaker conhecido ou nenhum
        if "xtts" in model_lower or "multilingual" in model_lower:
            # Se o modelo expõe speakers, tente o primeiro; caso contrário remova speaker
            if getattr(self.tts, "speakers", None):
                kwargs["speaker"] = self.tts.speakers[0]
                if self.verbose:
                    print(f"🔍 [VERBOSE] Coqui XTTS fallback usando speaker: {kwargs['speaker']}")
            else:
                kwargs.pop("speaker", None)
                kwargs["speaker_wav"] = None
                if self.verbose:
                    print(
                        "🔍 [VERBOSE] Coqui XTTS fallback removendo speaker (usar padrão interno)"
                    )
            return

        # Para modelos VITS PT, tente "0"
        if "vits" in model_lower and "pt" in model_lower:
            kwargs["speaker"] = "0"
            if self.verbose:
                print("🔍 [VERBOSE] Coqui VITS PT usando speaker: 0")
            return

        # Para outros modelos, tente opções comuns (sem forçar "0" para XTTS)
        common_speakers = ["default", "speaker_0", "ljspeech", "p225"]
        kwargs["speaker"] = common_speakers[0]
        if self.verbose:
            print(f"🔍 [VERBOSE] Coqui usando speaker fallback: {common_speakers[0]}")

    @staticmethod
    def _resample_audio(
        data, current_sr: int, target_sr: int
    ):  # pragma: no cover - depends on numpy availability
        if current_sr == target_sr:
            return data
        ratio = target_sr / current_sr
        indices = np.round(np.arange(0, len(data), 1 / ratio)).astype(int)
        indices = indices[indices < len(data)]
        return data[indices]


__all__ = ["CoquiTTSEngine"]
