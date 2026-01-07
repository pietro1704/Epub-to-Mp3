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
_COQUI_GPU_AVAILABLE = False


def _segment_timeout_seconds(text: str) -> int:
    """Estimate a timeout based on the text size to avoid infinite hangs."""
    word_count = max(len(text.split()), 1)
    estimated = word_count * 0.45  # Slightly slower baseline (CPU-friendly)
    min_timeout = 110 if not _COQUI_GPU_AVAILABLE else 60
    max_timeout = 480 if not _COQUI_GPU_AVAILABLE else 300
    return int(max(min_timeout, min(estimated, max_timeout)))


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


def _patch_xtts_generation() -> None:
    """Restaurar métodos de geração removidos do transformers 4.50+ para XTTS."""
    try:
        from transformers import PreTrainedModel  # type: ignore
        from transformers.generation.utils import GenerationMixin  # type: ignore
        from TTS.tts.layers.xtts import gpt_inference  # type: ignore
    except Exception:
        return

    GPT2InferenceModel = getattr(gpt_inference, "GPT2InferenceModel", None)
    try:
        if GPT2InferenceModel and GenerationMixin not in GPT2InferenceModel.__mro__:
            GPT2InferenceModel.__bases__ = (GenerationMixin,) + GPT2InferenceModel.__bases__
    except Exception:
        pass

    try:
        if not hasattr(PreTrainedModel, "generate"):
            PreTrainedModel.generate = GenerationMixin.generate  # type: ignore[attr-defined]
    except Exception:
        pass


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
            # Prefer to use available CPUs but cap to 8 to limit memory use
            max_workers = max(2, min(8, cpu_count))

        # **HEAP CORRUPTION FIX**: Limit concurrent memory-intensive operations
        import asyncio

        _memory_semaphore = asyncio.Semaphore(max_workers)

        _coqui_executor = ThreadPoolExecutor(max_workers=max_workers, thread_name_prefix="CoquiTTS")
        print(f"🚀 [THREAD] Executor TTS criado: {max_workers} workers")
    return _coqui_executor


def _get_coqui_chunk_limit() -> int:
    """Max chars per Coqui segment to avoid very long synthesis calls."""
    try:
        limit = int(os.environ.get("COQUI_CHUNK_CHARS", "").strip() or "2000")
    except ValueError:
        limit = 2000
    return max(800, min(limit, 6000))


def _coqui_phonemizer_limit(language: Optional[str]) -> Optional[int]:
    """
    Some phonemizers (ex: eSpeak via piper-phonemize) truncate very long inputs.
    Keep Portuguese segments under ~200 chars to avoid the 203-char warning.
    """
    env_limit = os.getenv("COQUI_PHONEMIZER_LIMIT")
    if env_limit:
        try:
            parsed = int(env_limit)
            return max(80, min(parsed, 600))
        except ValueError:
            pass

    lang = (language or "").split("-", 1)[0].lower()
    if lang in {"pt", "pt_br", "pt-pt"}:
        return 200
    return None


def _expand_segments_with_limits(
    segments: List[Tuple[str, str]],
    *,
    max_chars: int,
    verbose: bool = False,
    phonemizer_limit_fn=_coqui_phonemizer_limit,
) -> List[Tuple[str, str]]:
    """Split segments by chunk and phonemizer limits."""
    if not segments:
        return []

    safe_segments: List[Tuple[str, str]] = []
    logged_limit = False

    for language, segment_text in segments:
        primary_chunks = _split_text_chunks(segment_text, max_chars)
        for chunk in primary_chunks:
            limit = phonemizer_limit_fn(language) if phonemizer_limit_fn else None
            if limit and len(chunk) > limit:
                smaller_chunks = _split_text_chunks(chunk, limit)
                if verbose and not logged_limit and len(smaller_chunks) > 1:
                    lang_label = language or "desconhecido"
                    print(
                        f"🔍 [VERBOSE] Coqui limitando segmentos para {limit} chars (idioma: {lang_label})"
                    )
                    logged_limit = True
                for sub_chunk in smaller_chunks:
                    safe_segments.append((language, sub_chunk))
            else:
                safe_segments.append((language, chunk))

    return safe_segments


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
            _patch_xtts_generation()

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
                global _COQUI_GPU_AVAILABLE
                _COQUI_GPU_AVAILABLE = True
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

                # Melhorar tokenização para evitar avisos de attention_mask no Transformers
                try:
                    tokenizer = getattr(self.tts, "tokenizer", None)
                    model = getattr(self.tts, "model", None) or getattr(
                        getattr(self.tts, "synthesizer", None), "tts_model", None
                    )
                    if tokenizer:
                        pad_id = tokenizer.pad_token_id
                        eos_id = getattr(tokenizer, "eos_token_id", None)
                        if pad_id is None or (eos_id is not None and pad_id == eos_id):
                            tokenizer.add_special_tokens({"pad_token": "<pad>"})
                            pad_id = tokenizer.pad_token_id
                        if model and hasattr(model, "generation_config"):
                            gen_cfg = model.generation_config
                            if (
                                getattr(gen_cfg, "pad_token_id", None) is None
                                or gen_cfg.pad_token_id == gen_cfg.eos_token_id
                            ):
                                gen_cfg.pad_token_id = pad_id
                                gen_cfg.eos_token_id = gen_cfg.eos_token_id or eos_id or pad_id
                except Exception:
                    # Best effort para reduzir ruído de warning
                    pass

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
        self,
        text: str,
        output_path: Path,
        formatting_segments=None,
        progress_callback=None,
        chunk_callback=None,
    ) -> Optional[Path]:
        if not text:
            return None

        def _notify_progress(segment_text: str) -> None:
            if not progress_callback:
                return
            try:
                progress_callback(segment_text, len(segment_text))
            except Exception:
                # Progress updates are best-effort; ignore failures
                pass

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
        base_segments = len(segments)
        segments = _expand_segments_with_limits(segments, max_chars=max_chars, verbose=self.verbose)
        if self.verbose and len(segments) > base_segments:
            print(
                f"🔍 [VERBOSE] Coqui dividindo em {len(segments)} segmentos (limite {max_chars} chars + segurança)"
            )

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
                timeout = _segment_timeout_seconds(segment_text)
                await asyncio.wait_for(
                    loop.run_in_executor(
                        executor, self._synthesize_blocking, segment_text, output_path, language
                    ),
                    timeout=timeout,
                )
                _notify_progress(segment_text)
                if chunk_callback:
                    try:
                        chunk_callback(0, output_path)
                    except Exception:
                        pass
                if self.verbose:
                    print(f"🔍 [VERBOSE] Coqui síntese completa: {output_path}")
            except asyncio.TimeoutError:
                self.last_error = "synthesis_timeout"
                if self.verbose:
                    print(
                        f"⏱️ [VERBOSE] Coqui timeout após {_segment_timeout_seconds(segment_text)}s no segmento único"
                    )
                return None
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
                    timeout = _segment_timeout_seconds(segment_text)
                    try:
                        await asyncio.wait_for(
                            loop.run_in_executor(
                                executor,
                                self._synthesize_blocking,
                                segment_text,
                                temp_path,
                                language,
                            ),
                            timeout=timeout,
                        )
                    except asyncio.TimeoutError:
                        self.last_error = f"synthesis_timeout_segment_{idx}"
                        if self.verbose:
                            print(
                                f"⏱️ [VERBOSE] Coqui timeout após {timeout}s no segmento {idx} (sem numpy)"
                            )
                        return None
                    _notify_progress(segment_text)
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
            # Track if parallel timed out to allow sequential fallback
            parallel_failed = False
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

                async def _run_and_track(
                    text_value: str, lang_value: str, target_path: Path, segment_index: int
                ):
                    timeout = _segment_timeout_seconds(text_value)
                    try:
                        await asyncio.wait_for(
                            loop.run_in_executor(
                                executor,
                                self._synthesize_blocking,
                                text_value,
                                target_path,
                                lang_value,
                            ),
                            timeout=timeout,
                        )
                    except asyncio.TimeoutError:
                        self.last_error = f"synthesis_timeout_segment_{segment_index}"
                        if self.verbose:
                            print(
                                f"⏱️ [VERBOSE] Coqui timeout após {timeout}s no segmento {segment_index}"
                            )
                        raise
                    _notify_progress(text_value)
                    if chunk_callback:
                        try:
                            chunk_callback(segment_index, target_path)
                        except Exception:
                            pass

                tasks.append(_run_and_track(segment_text, language, temp_path, idx))

            # Execute all synthesis tasks in parallel
            if tasks:
                if self.verbose:
                    print(f"🚀 [VERBOSE] Coqui processando {len(tasks)} segmentos em paralelo")
                try:
                    await asyncio.gather(*tasks)
                except asyncio.TimeoutError:
                    parallel_failed = True
                    if self.verbose:
                        print(
                            "⏱️ [VERBOSE] Coqui timeout durante a síntese paralela; refazendo em modo sequencial"
                        )

            if parallel_failed:
                # Limpar arquivos temporários parcialmente escritos e refazer sequencialmente
                for temp_path in temp_files:
                    with contextlib.suppress(OSError):
                        temp_path.unlink()
                temp_files = []
                for idx, (language, segment_text) in enumerate(segments):
                    segment_text = segment_text.strip()
                    if not segment_text:
                        continue
                    import tempfile

                    temp_file = tempfile.NamedTemporaryFile(
                        delete=False,
                        suffix=".wav",
                        dir=output_path.parent,
                        prefix=f"coqui_seq{idx}_",
                    )
                    temp_file.close()
                    temp_path = Path(temp_file.name)
                    temp_files.append(temp_path)
                    timeout = max(_segment_timeout_seconds(segment_text) * 2, 180)
                    try:
                        await asyncio.wait_for(
                            loop.run_in_executor(
                                executor,
                                self._synthesize_blocking,
                                segment_text,
                                temp_path,
                                language,
                            ),
                            timeout=timeout,
                        )
                    except asyncio.TimeoutError:
                        self.last_error = f"synthesis_timeout_segment_{idx}_seq"
                        if self.verbose:
                            print(
                                f"⏱️ [VERBOSE] Coqui timeout após {timeout}s no segmento {idx} (sequencial)"
                            )
                        return None
                    _notify_progress(segment_text)
                    if chunk_callback:
                        try:
                            chunk_callback(idx, temp_path)
                        except Exception:
                            pass

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
            speaker = self._resolve_xtts_speaker()
            if speaker:
                kwargs["speaker"] = speaker
                kwargs.pop("speaker_wav", None)
                if self.verbose:
                    print(f"🔍 [VERBOSE] Coqui XTTS usando speaker: {speaker}")
            else:
                kwargs["speaker_wav"] = None  # Use default voice
                kwargs.pop("speaker", None)
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
            speaker = self._resolve_xtts_speaker()
            if speaker:
                kwargs["speaker"] = speaker
                kwargs.pop("speaker_wav", None)
                if self.verbose:
                    print(f"🔍 [VERBOSE] Coqui XTTS fallback usando speaker: {speaker}")
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

    def _resolve_xtts_speaker(self) -> Optional[str]:
        """Resolve um speaker válido para XTTS a partir do modelo ou cache."""
        candidates: List[str] = []

        # Tentativa 1: atributo speakers direto do TTS
        speakers_attr = getattr(self.tts, "speakers", None)
        if isinstance(speakers_attr, dict):
            candidates.extend([str(k) for k in speakers_attr.keys()])
        elif isinstance(speakers_attr, (list, tuple)) and speakers_attr:
            candidates.extend([str(speakers_attr[0])])

        # Tentativa 2: speaker_manager
        speaker_manager = getattr(self.tts, "speaker_manager", None)
        if speaker_manager:
            sm_speakers = getattr(speaker_manager, "speakers", None)
            if isinstance(sm_speakers, dict):
                candidates.extend([str(k) for k in sm_speakers.keys()])
            sm_ids = getattr(speaker_manager, "speaker_ids", None)
            if sm_ids:
                candidates.extend([str(sm_ids[0])])

        for candidate in candidates:
            if candidate:
                return candidate

        # Tentativa 3: ler speakers_xtts.pth do cache local
        try:
            import torch
        except Exception:
            return None

        cache_root = Path(os.getenv("COQUI_TTS_CACHE_DIR", "") or Path.home() / ".local/share/tts")
        model_slug = self.model_name.replace("/", "--")
        for candidate_path in [
            cache_root / "tts" / model_slug / "speakers_xtts.pth",
            cache_root / model_slug / "speakers_xtts.pth",
        ]:
            if candidate_path.exists():
                try:
                    state = torch.load(candidate_path, map_location="cpu")
                    if isinstance(state, dict) and state:
                        return str(next(iter(state.keys())))
                except Exception:
                    continue

        return None


__all__ = ["CoquiTTSEngine"]
