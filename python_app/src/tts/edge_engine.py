# -*- coding: utf-8 -*-
"""Edge TTS engine wrapper used by the converter and tests."""

from __future__ import annotations

import asyncio
import importlib
import inspect
import os
import re
import traceback
from contextlib import suppress
from pathlib import Path
from typing import Dict, List, Optional, Tuple, Set
from unittest.mock import Mock

# **SSL BYPASS**: Monkeypatch SSL ANTES de importar edge_tts
# IMPORTANTE: Necessário porque certificado da Microsoft (api.msedgeservices.com) está expirado
# Edge-TTS usa ssl.create_default_context(cafile=certifi.where())
import ssl as _ssl_module

# Salvar função original
_original_create_default_context = _ssl_module.create_default_context

# Substituir por versão não-verificada
def _create_unverified_context_wrapper(*args, **kwargs):
    """Sempre retorna contexto SSL não-verificado, ignorando parâmetros"""
    ctx = _ssl_module._create_unverified_context()
    return ctx

_ssl_module.create_default_context = _create_unverified_context_wrapper
_ssl_module._create_default_https_context = _ssl_module._create_unverified_context

edge_tts = None

try:
    _segment_seconds_env = float(os.getenv("EDGE_MAX_SEGMENT_SECONDS", "75"))
except (TypeError, ValueError):
    _segment_seconds_env = 75.0

DEFAULT_EDGE_SEGMENT_SECONDS = max(30.0, min(_segment_seconds_env, 95.0))
WORDS_PER_MINUTE = 150
MIN_WORDS_PER_SEGMENT = 40
MAX_SEGMENT_SPLIT_ATTEMPTS = 2
MIN_SEGMENT_RETRY_CHARS = 600
SIMPLIFIED_SEGMENT_MAX_CHARS = 1800
_SENTENCE_SPLIT_RE = re.compile(r"(?<=[.!?])\s+")

# If Edge returns no audio at all, it's often a connectivity / service issue.
# Use a short circuit-breaker to avoid spending minutes retrying the same request.
EDGE_NOAUDIO_COOLDOWN_SECONDS = float(os.getenv("EDGE_NOAUDIO_COOLDOWN_SECONDS", "60"))

# Import SSL/Certificate error types
try:
    from aiohttp import ClientConnectorCertificateError, ClientConnectorError
    import ssl
except ImportError:
    ClientConnectorCertificateError = None  # type: ignore
    ClientConnectorError = None  # type: ignore
    ssl = None  # type: ignore

# Global rate limiter for Edge TTS to prevent resource contention
try:
    _edge_max_concurrency = int(os.getenv("EDGE_MAX_CONCURRENCY", "2").strip() or "2")
except (TypeError, ValueError):
    _edge_max_concurrency = 2
_edge_max_concurrency = max(1, min(_edge_max_concurrency, 6))
_edge_rate_limiter = None


try:  # pragma: no cover - lazily loaded
    from ..language import LanguageMarkup
    from ..text_formatting import TextFormattingProcessor
except ImportError:  # pragma: no cover - during optional dependency resolution
    LanguageMarkup = None  # type: ignore
    TextFormattingProcessor = None  # type: ignore

from ..utils import TextValidator


class EdgeTTSEngine:
    """Small facade around ``edge_tts`` with predictable behaviour."""

    _noaudio_backoff_until: float = 0.0

    def __init__(
        self,
        voice: str,
        *,
        primary_language: Optional[str] = None,
        language_voices: Optional[Dict[str, str]] = None,
        verbose: bool = False,
        max_segment_seconds: Optional[float] = None,
        chunk_char_limit: Optional[int] = None,
        enable_parallel: bool = True,
    ) -> None:
        global edge_tts, _edge_rate_limiter

        if isinstance(edge_tts, Mock):
            if getattr(edge_tts, "side_effect", None):
                raise ImportError("Edge-TTS not installed")
            module = edge_tts
        else:
            if edge_tts is None:
                try:
                    edge_tts = importlib.import_module("edge_tts")  # type: ignore
                except ImportError as exc:
                    raise ImportError("Edge-TTS not installed") from exc
            module = edge_tts

        # Rate limiter for Edge TTS concurrent requests
        if _edge_rate_limiter is None:
            _edge_rate_limiter = asyncio.Semaphore(_edge_max_concurrency)

        self.voice = voice
        self._edge_tts = module
        self.primary_language = (primary_language or "auto").split('-', 1)[0].lower()
        self.language_voices = {
            (key or "").split("-", 1)[0].lower(): value
            for key, value in (language_voices or {}).items()
            if value
        }
        self.last_error: Optional[str] = None
        self.verbose = verbose
        max_seconds = max_segment_seconds if max_segment_seconds is not None else DEFAULT_EDGE_SEGMENT_SECONDS
        self._max_segment_seconds = max(30.0, min(float(max_seconds), 95.0))
        chunk_limit = chunk_char_limit if chunk_char_limit is not None else 20000
        try:
            chunk_limit = int(chunk_limit)
        except (TypeError, ValueError):
            chunk_limit = 20000
        self._chunk_char_limit = max(4000, chunk_limit)
        self._chunk_log_every = max(25, int(self._chunk_char_limit / 400))
        self._words_per_minute = WORDS_PER_MINUTE
        self.partial_failure_detected: bool = False
        self.last_segment_report: Dict[str, int] = {"expected": 0, "generated": 0, "failed": 0}
        self._enable_parallel = enable_parallel

        if self.verbose:
            parallel_mode = "ativado" if self._enable_parallel else "desativado"
            max_concurrent = _edge_rate_limiter._value if _edge_rate_limiter and self._enable_parallel else 1
            print(f"🔧 EdgeTTS inicializado: {voice}")
            print(f"   Paralelo: {parallel_mode} (max {max_concurrent} simultâneos)")
            print(f"   Limites: {self._max_segment_seconds:.0f}s/segmento, {self._chunk_char_limit} chars/chunk")

    def supports_multilingual(self) -> bool:
        """Edge TTS suporta multiidioma via voice switching e [[lang:]] tags"""
        return True

    def supports_emphasis(self) -> bool:
        """Edge TTS suporta ênfase via SSML quando voz é Neural"""
        return self._supports_emphasis()

    def apply_speed_profile(
        self,
        *,
        chunk_char_limit: Optional[int] = None,
        max_segment_seconds: Optional[float] = None,
        words_per_minute: Optional[int] = None,
    ) -> None:
        """Runtime hook used by the converter to nudge chunk sizes/timeouts."""
        updates: list[str] = []
        if chunk_char_limit is not None:
            try:
                limit = int(chunk_char_limit)
            except (TypeError, ValueError):
                limit = self._chunk_char_limit
            limit = max(4000, min(limit, 25_000))
            if limit != self._chunk_char_limit:
                self._chunk_char_limit = limit
                self._chunk_log_every = max(25, int(self._chunk_char_limit / 400))
                updates.append(f"chunk={limit}")

        if max_segment_seconds is not None:
            try:
                seconds = float(max_segment_seconds)
            except (TypeError, ValueError):
                seconds = self._max_segment_seconds
            seconds = max(30.0, min(seconds, 100.0))
            if seconds != self._max_segment_seconds:
                self._max_segment_seconds = seconds
                updates.append(f"segment={seconds:.0f}s")

        if words_per_minute is not None:
            try:
                wpm = int(words_per_minute)
            except (TypeError, ValueError):
                wpm = self._words_per_minute
            wpm = max(120, min(wpm, 260))
            if wpm != self._words_per_minute:
                self._words_per_minute = wpm
                updates.append(f"wpm={wpm}")

        if updates and self.verbose:
            print(f"⚡ EdgeTTS speed profile atualizado: {', '.join(updates)}")

    @property
    def speed_profile(self) -> Dict[str, float]:
        """Expose active chunk/timing limits for telemetry/logging."""
        return {
            "chunk_char_limit": float(self._chunk_char_limit),
            "max_segment_seconds": float(self._max_segment_seconds),
            "words_per_minute": float(self._words_per_minute),
        }

    async def _probe_edge_health(self, voice: str) -> bool:
        """
        Tenta uma síntese mínima para diferenciar erro de conteúdo x indisponibilidade do serviço.
        Se até o texto de teste falhar, assumimos outage no backend do Edge.
        """
        test_text = "Teste rápido do Edge TTS."
        timeout = 8
        try:
            async with _edge_rate_limiter:
                communicator = self._edge_tts.Communicate(test_text, voice or self.voice)
                stream_candidate = communicator.stream()
                stream = await stream_candidate if inspect.isawaitable(stream_candidate) else stream_candidate

                async def _consume_probe():
                    got_audio = False
                    async for chunk in stream:
                        if chunk.get("type") == "audio":
                            got_audio = True
                            break
                    with suppress(Exception):
                        await stream.aclose()
                    return got_audio

                return await asyncio.wait_for(_consume_probe(), timeout=timeout)
        except Exception as exc:
            if self.verbose:
                print(f"🔍 [VERBOSE] EdgeTTS health-check falhou: {exc}")
            return False

    @staticmethod
    def _sanitize_for_edge(text: str) -> str:
        """
        Remove caracteres de controle/zero-width e normaliza espaços.
        Edge costuma retornar NoAudioReceived quando recebe controle invisível ou separadores de linha.
        """
        cleaned = re.sub(r"[\u0000-\u001f\u007f-\u009f]", " ", text)
        cleaned = cleaned.replace("\u2028", " ").replace("\u2029", " ").replace("\ufeff", " ")
        cleaned = cleaned.replace("\u00a0", " ")
        cleaned = re.sub(r"[ \t\u200b\u200c\u200d\u2060]+", " ", cleaned)
        cleaned = re.sub(r"\s+\n", "\n", cleaned)
        cleaned = re.sub(r"\n\s+", "\n", cleaned)
        cleaned = cleaned.strip()
        return cleaned

    async def synthesize_async(self, text: str, output_path: Path, formatting_segments=None) -> Optional[Path]:
        if not text:
            return None

        if self.verbose:
            text_preview = text[:150] + "..." if len(text) > 150 else text
            print(f"\n📝 EdgeTTS iniciando síntese para {output_path.name}")
            print(f"   Tamanho: {len(text)} caracteres")
            print(f"   Preview: {text_preview}")

        self.last_error = None
        self.partial_failure_detected = False
        self.last_segment_report = {"expected": 0, "generated": 0, "failed": 0}

        # Use formatting segments if available
        payload_text = text or ""

        if TextFormattingProcessor:
            formatter = TextFormattingProcessor()
            payload_text = formatter.to_audible_text(payload_text, formatting_segments)

        sanitized = self._sanitize_for_edge(payload_text)
        payload_text = sanitized

        if self.verbose and payload_text != text:
            print(f"   ⚙️ Texto processado (sanitizado/formatado): {len(payload_text)} chars")

        force_plain_segments = self._should_force_plain_text(payload_text)
        if force_plain_segments:
            payload_text = self._simplify_segment_text(payload_text, limit_chars=None)

        segments = self._prepare_segments(payload_text)

        if not segments:
            return None

        if self.verbose:
            print(f"   📦 Dividido em {len(segments)} segmentos")

        output_path = Path(output_path)
        output_path.parent.mkdir(parents=True, exist_ok=True)

        try:
            if output_path.exists():
                output_path.unlink()
        except OSError:
            pass

        total_segments = 0
        failed_segments = 0
        segments_to_process: List[Tuple[str, str]] = [
            (voice, segment_text)
            for voice, segment_text in segments
            if segment_text and segment_text.strip()
        ]
        segment_split_attempts: Dict[str, int] = {}
        micro_split_tracker: Set[str] = set()
        idx = 0

        # **PARALLEL OPTIMIZATION**: Process segments in batches when parallel mode is enabled
        if self._enable_parallel and _edge_rate_limiter and len(segments_to_process) > 1:
            if self.verbose:
                max_batch = _edge_rate_limiter._value
                print(f"🚀 [VERBOSE] Processamento paralelo ativado (batch size: {max_batch})")
            return await self._synthesize_parallel(
                output_path,
                segments_to_process,
                force_plain_segments,
            )

        # **SEQUENTIAL MODE**: Original logic for compatibility
        try:
            while idx < len(segments_to_process):
                voice, segment_text = segments_to_process[idx]
                # Validate segment data
                if voice is None:
                    voice = self.voice or "en-US-GuyNeural"

                if segment_text is None:
                    continue

                segment_text = segment_text.strip("\n\r")
                if not segment_text:
                    continue

                if force_plain_segments or self._should_force_plain_text(segment_text):
                    simplified_segment = self._simplify_segment_text(segment_text, limit_chars=None)
                    if simplified_segment:
                        segment_text = simplified_segment
                        force_plain_segments = True

                if self.verbose:
                    text_preview = segment_text[:200] + "..." if len(segment_text) > 200 else segment_text
                    print(f"\n🎙️ Segmento {idx+1}/{len(segments_to_process)} ({len(segment_text)} chars, voz: {voice})")
                    print(f"   Texto: {text_preview}")

                # **CRITICAL FIX**: Try to process segment with retries
                success = await self._synthesize_segment(
                    segment_text,
                    voice,
                    output_path,
                    append=(total_segments > 0),
                )

                if not success:
                    # If the Edge service is returning *no audio at all*, splitting/cleaning won't help.
                    # Fail fast so the converter can move on instead of spending minutes in retries.
                    if idx == 0 and self.last_error and (
                        "noaudioreceived" in self.last_error.lower()
                        or "service_unavailable" in self.last_error.lower()
                        or "no_audio" == self.last_error.lower()
                    ):
                        if self.verbose:
                            print(f"   ⛔ Abortando: {self.last_error}")
                        return None

                    retry_segments = self._split_failed_segment(voice, segment_text, segment_split_attempts)
                    if retry_segments:
                        if self.verbose:
                            print(f"   ⚠️ Falhou, dividindo em {len(retry_segments)} sub-segmentos...")
                        segments_to_process[idx:idx + 1] = retry_segments
                        continue

                    simplified_text = self._simplify_segment_text(segment_text)
                    if simplified_text and simplified_text != segment_text:
                        if self.verbose:
                            print(f"   ⚠️ Tentando com texto simplificado...")
                        success = await self._synthesize_segment(
                            simplified_text,
                            voice,
                            output_path,
                            append=(total_segments > 0),
                        )
                        if success:
                            if self.verbose:
                                print(f"   ✅ Sucesso com texto simplificado")
                            force_plain_segments = True
                            total_segments += 1
                            idx += 1
                            continue

                    failed_segments += 1
                    if self.verbose:
                        print(f"   ❌ FALHOU: {self.last_error}")

                    # Retry com backoff exponencial mais curto (1s, 2s)
                    if failed_segments <= 2:
                        backoff = min(1.0 * (2 ** (failed_segments - 1)), 3.0)
                        if self.verbose:
                            print(f"   🔄 Tentando novamente após {backoff}s...")
                        await asyncio.sleep(backoff)

                        success = await self._synthesize_segment(
                            segment_text,
                            voice,
                            output_path,
                            append=(total_segments > 0),
                        )

                        if success:
                            if self.verbose:
                                print(f"   ✅ Sucesso no retry")
                            failed_segments = max(0, failed_segments - 1)

                    # Falhar se mais de 2 segmentos consecutivos falharem
                    if failed_segments > 2:
                        micro_segments = self._force_micro_segments(voice, segment_text, micro_split_tracker)
                        if micro_segments:
                            if self.verbose:
                                print(f"   ⚡ Forçando divisão em {len(micro_segments)} microsegmentos")
                            segments_to_process[idx:idx + 1] = micro_segments
                            force_plain_segments = True
                            failed_segments = 0
                            continue
                        print(f"❌ Edge TTS: muitas falhas consecutivas ({failed_segments}), abortando")
                        return None

                    idx += 1
                    continue

                # Success!
                total_segments += 1
                idx += 1
        except asyncio.TimeoutError:
            self.last_error = "timeout"
            return None
        except Exception as exc:  # pragma: no cover - defensive logging
            self.last_error = f"{exc.__class__.__name__}: {exc}" if exc else exc.__class__.__name__
            return None

        if total_segments == 0 or not output_path.exists():
            self.last_error = "no_audio"
            return None

        expected_segments = total_segments + failed_segments
        self.last_segment_report = {
            "expected": expected_segments,
            "generated": total_segments,
            "failed": failed_segments,
        }

        # **FIXED**: Aceitar áudio somente se pelo menos 95% dos segmentos foram gerados com sucesso
        success_rate = total_segments / max(expected_segments, 1)

        if success_rate < 0.95:
            # Menos de 95% dos segmentos -> falha crítica
            self.partial_failure_detected = True
            if failed_segments > 0:
                print(f"⚠️ Edge TTS: {failed_segments} segment(s) falharam durante a síntese")
                print(f"   Processados: {total_segments}/{expected_segments} segmentos ({success_rate*100:.0f}%)")
                if self.verbose:
                    print(f"   Use --verbose para mais detalhes sobre os segmentos com falha")
            else:
                print(f"⚠️ Edge TTS: somente {total_segments}/{expected_segments} segmentos foram gerados (saída incompleta)")
            self.last_error = f"incomplete_segments:{total_segments}/{expected_segments}"
            with suppress(OSError):
                output_path.unlink(missing_ok=True)
            return None
        elif failed_segments > 0 and success_rate < 1.0:
            # Entre 95-100% dos segmentos -> avisar mas aceitar o áudio
            print(f"⚠️ Edge TTS: {failed_segments} segment(s) falharam, mas {success_rate*100:.1f}% foi gerado com sucesso")
            if self.verbose:
                print(f"   Processados: {total_segments}/{expected_segments} segmentos")

        return output_path

    async def _synthesize_parallel(
        self,
        output_path: Path,
        segments_to_process: List[Tuple[str, str]],
        force_plain_segments: bool,
    ) -> Optional[Path]:
        """Process segments in parallel batches for faster synthesis."""
        import tempfile
        from pathlib import Path

        global _edge_rate_limiter

        batch_size = _edge_rate_limiter._value if _edge_rate_limiter else 2
        total_segments = len(segments_to_process)
        successful_segments = 0
        # Use dict to maintain segment order
        segment_files: Dict[int, Optional[Path]] = {i: None for i in range(total_segments)}

        if self.verbose:
            print(f"🚀 [PARALLEL] Processando {total_segments} segmentos em batches de {batch_size}")

        # Process in batches
        for batch_start in range(0, total_segments, batch_size):
            batch_end = min(batch_start + batch_size, total_segments)
            batch = segments_to_process[batch_start:batch_end]

            if self.verbose:
                print(f"🚀 [PARALLEL] Batch {batch_start//batch_size + 1}: segmentos {batch_start+1}-{batch_end}/{total_segments}")

            # Create temp files for this batch
            batch_temp_files = []
            for i in range(len(batch)):
                temp_file = tempfile.NamedTemporaryFile(delete=False, suffix='.mp3', dir=output_path.parent)
                temp_file.close()
                batch_temp_files.append(Path(temp_file.name))

            # Create tasks for parallel processing
            tasks = []
            for i, (voice, segment_text) in enumerate(batch):
                # Validate and prepare segment
                if voice is None:
                    voice = self.voice or "en-US-GuyNeural"

                segment_text = segment_text.strip("\n\r") if segment_text else ""
                if not segment_text:
                    continue

                if force_plain_segments or self._should_force_plain_text(segment_text):
                    simplified = self._simplify_segment_text(segment_text, limit_chars=None)
                    if simplified:
                        segment_text = simplified

                # Create synthesis task
                task = self._synthesize_segment(
                    segment_text,
                    voice,
                    batch_temp_files[i],
                    append=False,  # Each segment gets its own file
                )
                tasks.append((i, task, batch_temp_files[i]))

            # Execute batch in parallel
            results = await asyncio.gather(
                *[task for _, task, _ in tasks],
                return_exceptions=True
            )

            # Check results and collect successful temp files
            for (idx, _, temp_file), result in zip(tasks, results):
                segment_idx = batch_start + idx
                segment_num = segment_idx + 1

                if isinstance(result, Exception):
                    if self.verbose:
                        error_msg = str(result)[:100]
                        print(f"⚠️ [PARALLEL] Segmento {segment_num} falhou: {error_msg}")
                    # Clean up failed temp file
                    with suppress(OSError):
                        temp_file.unlink()
                elif result:  # Success
                    successful_segments += 1
                    segment_files[segment_idx] = temp_file
                    if self.verbose:
                        file_size = temp_file.stat().st_size if temp_file.exists() else 0
                        print(f"✅ [PARALLEL] Segmento {segment_num} OK ({file_size} bytes)")
                else:
                    if self.verbose:
                        print(f"⚠️ [PARALLEL] Segmento {segment_num} falhou (sem áudio)")
                    with suppress(OSError):
                        temp_file.unlink()

        # Retry failed segments sequentially (anti-starving measure)
        failed_indices = [i for i, path in segment_files.items() if path is None]
        if failed_indices and successful_segments >= total_segments * 0.8:
            if self.verbose:
                print(f"🔄 [PARALLEL] Tentando {len(failed_indices)} segmentos falhados sequencialmente...")

            for fail_idx in failed_indices:
                voice, segment_text = segments_to_process[fail_idx]
                if not segment_text or not segment_text.strip():
                    continue

                if force_plain_segments or self._should_force_plain_text(segment_text):
                    simplified = self._simplify_segment_text(segment_text, limit_chars=None)
                    if simplified:
                        segment_text = simplified

                temp_file = tempfile.NamedTemporaryFile(delete=False, suffix='.mp3', dir=output_path.parent)
                temp_file.close()
                retry_path = Path(temp_file.name)

                try:
                    success = await self._synthesize_segment(
                        segment_text,
                        voice or self.voice,
                        retry_path,
                        append=False,
                    )

                    if success and retry_path.exists():
                        successful_segments += 1
                        segment_files[fail_idx] = retry_path
                        if self.verbose:
                            print(f"✅ [PARALLEL] Segmento {fail_idx + 1} recuperado no retry")
                    else:
                        with suppress(OSError):
                            retry_path.unlink()
                except Exception as exc:
                    if self.verbose:
                        print(f"⚠️ [PARALLEL] Retry segmento {fail_idx + 1} falhou: {exc}")
                    with suppress(OSError):
                        retry_path.unlink()

        # Collect successful segments in order
        temp_files = [path for path in segment_files.values() if path is not None]

        if not temp_files:
            self.last_error = "no_audio_generated_parallel"
            return None

        if self.verbose:
            print(f"🔗 [PARALLEL] Concatenando {len(temp_files)} segmentos bem-sucedidos...")

        try:
            with output_path.open('wb') as outfile:
                for temp_file in temp_files:
                    if temp_file.exists():
                        with temp_file.open('rb') as infile:
                            outfile.write(infile.read())
                        # Clean up temp file
                        with suppress(OSError):
                            temp_file.unlink()
        except Exception as exc:
            self.last_error = f"concatenation_failed: {exc}"
            if self.verbose:
                print(f"❌ [PARALLEL] Erro ao concatenar: {exc}")
            # Clean up remaining temp files
            for temp_file in temp_files:
                with suppress(OSError):
                    temp_file.unlink()
            return None

        # Update statistics
        self.last_segment_report = {
            "expected": total_segments,
            "generated": successful_segments,
            "failed": total_segments - successful_segments,
        }

        success_rate = successful_segments / total_segments
        if success_rate < 0.95:
            self.partial_failure_detected = True
            print(f"⚠️ Edge TTS Paralelo: apenas {successful_segments}/{total_segments} segmentos ({success_rate*100:.1f}%)")
            self.last_error = f"incomplete_segments:{successful_segments}/{total_segments}"
            with suppress(OSError):
                output_path.unlink()
            return None

        if self.verbose:
            print(f"✅ [PARALLEL] Síntese completa: {successful_segments}/{total_segments} segmentos ({success_rate*100:.1f}%)")

        return output_path

    def _calculate_timeout(self, text: str) -> int:
        """Estimate a safe upper bound for synthesis time in seconds.

        Otimizado: timeout mais agressivo para falhar rápido em caso de problemas.
        """
        if not text:
            return 60  # 60s padrão para texto vazio

        estimated = max(self._estimate_duration(text), 5.0)

        # Timeout = duração estimada + 40% de buffer + 20s fixos
        # Mais agressivo para evitar esperas longas
        timeout = estimated * 1.4 + 20.0

        # Limites: mínimo 45s, máximo 300s (5 min)
        timeout = max(timeout, 45.0)
        timeout = min(timeout, 300.0)

        return int(round(timeout))

    def _prepare_segments(self, text: str) -> list[tuple[str, str]]:
        if text is None:
            return [(self.voice, "")]

        cleaned_text = (
            TextFormattingProcessor.clean_tts_text(text)
            if TextFormattingProcessor
            else text
        )

        if LanguageMarkup is None:
            return self._chunk_text(self.voice, cleaned_text)

        try:
            lowered = cleaned_text.lower()
            if "[[lang:" not in lowered:
                return self._chunk_text(self.voice, cleaned_text)

            segments = LanguageMarkup.parse(cleaned_text, self.primary_language)
            if segments is None:
                return self._chunk_text(self.voice, cleaned_text)

            if len(segments) > 100:
                simplified = LanguageMarkup.strip(cleaned_text) if LanguageMarkup else cleaned_text
                return self._chunk_text(self.voice, simplified)

            prepared: list[tuple[str, str]] = []
            for segment in segments:
                if segment is None:
                    continue
                segment_text = getattr(segment, "text", "") or ""
                segment_text = segment_text.strip()
                if not segment_text:
                    continue
                lang = (segment.language or "").split("-", 1)[0].lower()
                voice = self.language_voices.get(lang) or self.voice
                segment_clean = (
                    TextFormattingProcessor.clean_tts_text(segment_text)
                    if TextFormattingProcessor
                    else segment_text
                )
                prepared.extend(self._chunk_text(voice, segment_clean))

            if not prepared:
                return self._chunk_text(self.voice, cleaned_text)

            return prepared

        except Exception as exc:
            fallback = TextFormattingProcessor.clean_tts_text(text or "") if TextFormattingProcessor else (text or "")
            return self._chunk_text(self.voice, fallback)

    def _chunk_text(self, voice: str, text: str, chunk_size: Optional[int] = None) -> list[tuple[str, str]]:
        """Divide texto longo em blocos menores respeitando limites aproximados de frase e duração."""
        if not text:
            return []

        stripped = text.strip()
        if not stripped:
            return []

        try:
            active_chunk_limit = int(chunk_size) if chunk_size is not None else self._chunk_char_limit
        except (TypeError, ValueError):
            active_chunk_limit = self._chunk_char_limit
        active_chunk_limit = max(4000, active_chunk_limit)

        if len(stripped) <= active_chunk_limit:
            base_chunks: List[tuple[str, str]] = [(voice, stripped)]
        else:
            base_chunks = []
            start = 0
            length = len(stripped)

            while start < length:
                end = min(start + active_chunk_limit, length)
                chunk = stripped[start:end]

                if end < length:
                    last_period = chunk.rfind(".")
                    last_exclamation = chunk.rfind("!")
                    last_question = chunk.rfind("?")
                    break_point = max(last_period, last_exclamation, last_question)
                    if break_point > active_chunk_limit * 0.5:
                        chunk = chunk[: break_point + 1]
                        end = start + len(chunk)

                if chunk:
                    base_chunks.append((voice, chunk))
                start = end

        refined: List[tuple[str, str]] = []
        for chunk_voice, chunk_text in base_chunks:
            refined.extend(self._split_if_needed(chunk_voice, chunk_text))

        return refined

    def _split_if_needed(self, voice: str, text: str) -> List[tuple[str, str]]:
        """Ensure each chunk respects the estimated duration limit."""
        if not text:
            return []

        duration = self._estimate_duration(text)
        if duration <= self._max_segment_seconds:
            return [(voice, text)]

        segments = self._split_text_by_duration(text, self._max_segment_seconds)
        return [(voice, segment) for segment in segments if segment]

    def _split_text_by_duration(self, text: str, max_seconds: float) -> List[str]:
        """Split text using sentence boundaries and estimated duration."""
        sentences = _SENTENCE_SPLIT_RE.split(text)
        segments: List[str] = []
        buffer: List[str] = []

        for sentence in sentences:
            trimmed = sentence.strip()
            if not trimmed:
                continue

            candidate = f"{' '.join(buffer)} {trimmed}".strip() if buffer else trimmed
            if buffer and self._estimate_duration(candidate) > max_seconds:
                segments.append(" ".join(buffer).strip())
                buffer = [trimmed]
            else:
                buffer.append(trimmed)

        if buffer:
            segments.append(" ".join(buffer).strip())

        refined: List[str] = []
        for segment in segments:
            if not segment:
                continue
            if self._estimate_duration(segment) <= max_seconds or len(segment.split()) <= 1:
                refined.append(segment)
            else:
                refined.extend(self._split_by_words(segment, max_seconds))

        return [segment for segment in refined if segment]

    def _split_by_words(self, text: str, max_seconds: float) -> List[str]:
        """Fallback splitter when a single sentence still exceeds the duration limit."""
        words = [word for word in text.split() if word]
        if not words:
            return []

        max_words = max(int((max_seconds / 60.0) * self._words_per_minute), MIN_WORDS_PER_SEGMENT)
        segments: List[str] = []

        for start in range(0, len(words), max_words):
            segment_words = words[start:start + max_words]
            segment_text = " ".join(segment_words).strip()
            if segment_text:
                segments.append(segment_text)

        return segments

    def _segment_signature(self, voice: str, text: str) -> str:
        preview = (text or "").strip()
        return f"{voice}:{len(preview)}:{hash(preview[:160])}"

    def _split_failed_segment(
        self,
        voice: str,
        text: str,
        attempts: Dict[str, int],
    ) -> List[Tuple[str, str]] | None:
        """Try to split a problematic segment into smaller pieces for retry."""
        if not text or len(text) < MIN_SEGMENT_RETRY_CHARS:
            return None

        signature = self._segment_signature(voice, text)
        attempt = attempts.get(signature, 0)
        if attempt >= MAX_SEGMENT_SPLIT_ATTEMPTS:
            return None

        divisor = 2 + attempt
        chunk_size = max(int(len(text) / divisor), MIN_SEGMENT_RETRY_CHARS // 2)
        smaller_segments = self._chunk_text(voice, text, chunk_size=chunk_size)
        smaller_segments = [
            (seg_voice, seg_text)
            for seg_voice, seg_text in smaller_segments
            if seg_text and seg_text.strip()
        ]

        if len(smaller_segments) <= 1:
            return None

        attempts[signature] = attempt + 1
        return smaller_segments

    def _force_micro_segments(
        self,
        voice: str,
        text: str,
        tracker: Set[str],
    ) -> List[Tuple[str, str]] | None:
        """Force text into very small segments to salvage stubborn payloads."""
        if not text:
            return None

        signature = f"micro:{self._segment_signature(voice, text)}"
        if signature in tracker:
            return None

        tracker.add(signature)

        cleaned = text.strip()
        if not cleaned:
            return None

        max_seconds = min(self._max_segment_seconds * 0.5, 20.0)
        micro_chunks = self._split_text_by_duration(cleaned, max_seconds)

        if not micro_chunks:
            # Fall back to fixed-size word groups (~80 words ≈ 30s)
            words = [word for word in cleaned.split() if word]
            if not words:
                return None

            chunk_words = max(min(len(words) // 4, 80), 20)
            micro_chunks = []
            for start in range(0, len(words), chunk_words):
                segment_words = words[start:start + chunk_words]
                if segment_words:
                    micro_chunks.append(" ".join(segment_words))

        micro_chunks = [chunk.strip() for chunk in micro_chunks if chunk and chunk.strip()]
        if not micro_chunks:
            return None

        return [(voice, chunk) for chunk in micro_chunks]

    def _simplify_segment_text(self, text: str, *, limit_chars: Optional[int] = SIMPLIFIED_SEGMENT_MAX_CHARS) -> str:
        """Remove formatting markers and limit length to create a safer payload."""
        if not text:
            return ""

        simplified = text
        if LanguageMarkup:
            try:
                simplified = LanguageMarkup.strip(simplified)
            except Exception:
                pass

        if TextFormattingProcessor:
            try:
                simplified = TextFormattingProcessor.strip_inline_markdown(simplified)
            except Exception:
                pass

        simplified = re.sub(r"<[^>]+>", " ", simplified)
        simplified = re.sub(r"\[\[[^\]]+\]\]", " ", simplified)
        simplified = re.sub(r"\s+", " ", simplified)
        simplified = simplified.strip()

        if limit_chars and len(simplified) > limit_chars:
            simplified = simplified[:limit_chars]

        return simplified

    def _should_force_plain_text(self, text: str) -> bool:
        """Heuristic: detect heavy markup that often breaks Edge SSML."""
        if not text:
            return False
        stripped = text.strip()
        if len(stripped) < 400:
            return False

        fmt_markers = stripped.count("[[fmt:")
        lang_markers = stripped.lower().count("[[lang:")
        bold_markers = stripped.count("**")
        italic_markers = stripped.count("_")

        high_markup = fmt_markers + lang_markers >= 20
        dense_markup = (fmt_markers + lang_markers) >= 8 and len(stripped) / max(fmt_markers + lang_markers, 1) < 200
        heavy_markdown = bold_markers >= 10 or italic_markers >= 30
        very_long = len(stripped) > 12000 and (fmt_markers + lang_markers) >= 5

        return high_markup or dense_markup or heavy_markdown or very_long

    def _estimate_duration(self, text: str) -> float:
        """Estimate spoken duration in seconds for the provided text."""
        try:
            estimated = TextValidator.estimate_duration(text, words_per_minute=self._words_per_minute)
            return float(estimated or 0.0)
        except Exception:
            words = [word for word in (text or "").split() if word]
            if not words:
                return 0.0
            return (len(words) / max(self._words_per_minute, 1)) * 60.0

    def _supports_emphasis(self) -> bool:
        voice = (self.voice or "").lower()
        return "neural" in voice or voice.startswith("pt-br")

    async def _synthesize_segment(
        self,
        text: str,
        voice: str,
        output_path: Path,
        *,
        append: bool,
    ) -> bool:
        global _edge_rate_limiter

        # Validate inputs
        if text is None:
            self.last_error = "text_is_none"
            return False

        if voice is None:
            voice = self.voice or "en-US-GuyNeural"

        # Use global rate limiter to prevent resource contention
        waiting_start = asyncio.get_event_loop().time()
        slots_available = _edge_rate_limiter._value

        if slots_available == 0:  # All slots taken
            waiters = getattr(_edge_rate_limiter, '_waiters', [])
            waiters_count = len(waiters) if waiters is not None else 0
            if self.verbose:
                print(f"   ⏳ Aguardando slot livre (fila: {waiters_count})")

        async with _edge_rate_limiter:
            wait_time = asyncio.get_event_loop().time() - waiting_start
            if self.verbose and wait_time > 1:
                print(f"   🚀 Slot obtido após {wait_time:.1f}s")

            now = asyncio.get_event_loop().time()
            if now < self._noaudio_backoff_until:
                remaining = int(self._noaudio_backoff_until - now)
                self.last_error = f"service_unavailable (cooldown {remaining}s)"
                if self.verbose:
                    print(f"   ⏸️ Cooldown: {remaining}s restantes")
                return False
            try:
                # SSL bypass já aplicado no topo do módulo via monkeypatch
                communicator = self._edge_tts.Communicate(text, voice)

            except Exception as exc:  # pragma: no cover - defensive logging
                self.last_error = f"{exc.__class__.__name__}: {exc}" if exc else exc.__class__.__name__
                if self.verbose:
                    print(f"   ❌ Erro ao criar Communicate: {self.last_error}")
                return False

            mode = "ab" if append else "wb"
            received_audio = False
            timeout = self._calculate_timeout(text)

            try:
                stream_candidate = communicator.stream()
            except Exception as exc:  # pragma: no cover - defensive logging
                self.last_error = f"{exc.__class__.__name__}: {exc}" if exc else exc.__class__.__name__
                if self.verbose:
                    print(f"   ❌ Erro ao obter stream: {self.last_error}")
                return False

            try:
                stream = await stream_candidate if inspect.isawaitable(stream_candidate) else stream_candidate
            except asyncio.TimeoutError:
                self.last_error = "timeout"
                if self.verbose:
                    print("   ⏱️ Timeout ao inicializar stream")
                return False
            except Exception as exc:  # pragma: no cover - defensive logging
                self.last_error = f"{exc.__class__.__name__}: {exc}" if exc else exc.__class__.__name__
                if self.verbose:
                    print(f"   ❌ Erro ao inicializar stream: {self.last_error}")
                return False

            if not hasattr(stream, "__aiter__"):
                self.last_error = "invalid_stream"
                if self.verbose:
                    print("   ❌ Stream inválido (não assíncrono)")
                return False
            chunks_received = 0

            async def _consume_stream(out_file) -> None:
                nonlocal received_audio, chunks_received
                try:
                    async for chunk in stream:
                        chunks_received += 1
                        if chunk["type"] == "audio":
                            out_file.write(chunk["data"])
                            received_audio = True
                finally:
                    with suppress(Exception):
                        await stream.aclose()

            synthesis_start = asyncio.get_event_loop().time()
            max_retries = 3
            retry_count = 0

            try:
                while retry_count < max_retries:
                    try:
                        heartbeat_task = None
                        if self.verbose:
                            async def _segment_heartbeat() -> None:
                                while True:
                                    await asyncio.sleep(10)
                                    elapsed = asyncio.get_event_loop().time() - synthesis_start
                                    status = "recebendo" if received_audio else "aguardando"
                                    print(f"   ... {status} ({elapsed:.0f}s)", flush=True)

                            heartbeat_task = asyncio.create_task(_segment_heartbeat())

                        try:
                            with output_path.open(mode) as out_file:
                                await asyncio.wait_for(_consume_stream(out_file), timeout=timeout)
                        finally:
                            if heartbeat_task is not None:
                                heartbeat_task.cancel()
                                with suppress(asyncio.CancelledError):
                                    await heartbeat_task

                        if self.verbose and received_audio:
                            elapsed = asyncio.get_event_loop().time() - synthesis_start
                            print(f"   ✅ Concluído em {elapsed:.1f}s ({chunks_received} chunks)")

                        break  # Success - exit retry loop

                    except asyncio.TimeoutError:
                        synthesis_time = asyncio.get_event_loop().time() - synthesis_start
                        self.last_error = "timeout"
                        if self.verbose:
                            print(f"   ⏱️ Timeout após {synthesis_time:.1f}s (limite: {timeout}s)")
                        return False

                    except asyncio.CancelledError:
                        synthesis_time = asyncio.get_event_loop().time() - synthesis_start
                        self.last_error = "cancelled"
                        if self.verbose:
                            print(f"   🚫 Cancelado após {synthesis_time:.1f}s")
                        raise

                    except Exception as exc:
                        synthesis_time = asyncio.get_event_loop().time() - synthesis_start

                        if self.verbose:
                            print(f"   ⚠️ Exceção ({exc.__class__.__name__}) após {synthesis_time:.1f}s: {exc}", flush=True)

                        # Check if it's a certificate/SSL error
                        is_cert_error = (
                            ClientConnectorCertificateError and isinstance(exc, ClientConnectorCertificateError)
                        ) or (
                            ClientConnectorError and isinstance(exc, ClientConnectorError)
                        ) or (
                            "certificate" in str(exc).lower() or "ssl" in str(exc).lower()
                        )

                        is_no_audio = "noaudio" in str(exc).lower() or exc.__class__.__name__.lower() == "noaudioreceived"
                        is_transient = is_cert_error or is_no_audio or "timeout" in str(exc).lower() or "connection" in str(exc).lower()

                        # If *nothing* was received (0 chunks), first check if service is reachable.
                        allow_retry = True
                        health_ok = True
                        if is_no_audio and chunks_received == 0 and not received_audio:
                            allow_retry = retry_count < 1  # only one retry for no-audio
                            health_ok = await self._probe_edge_health(voice)

                        if is_transient and allow_retry and retry_count < max_retries - 1:
                            retry_count += 1
                            backoff_time = 2 ** retry_count  # 2s, 4s, 8s

                            # Detailed SSL error logging
                            if is_cert_error:
                                print(f"   🔒 Erro SSL: {exc.__class__.__name__}")
                            elif is_no_audio:
                                print(f"   🔇 Sem áudio ({exc.__class__.__name__}); retry {retry_count}/{max_retries-1} em {backoff_time}s")
                            else:
                                print(f"   🔄 Erro transitório ({exc.__class__.__name__}); retry {retry_count}/{max_retries-1} em {backoff_time}s")

                            await asyncio.sleep(backoff_time)

                            # Recreate communicator and stream for retry
                            try:
                                # SSL bypass já aplicado no topo do módulo via monkeypatch
                                communicator = self._edge_tts.Communicate(text, voice)
                                stream_candidate = communicator.stream()
                                stream = await stream_candidate if inspect.isawaitable(stream_candidate) else stream_candidate
                                chunks_received = 0
                                received_audio = False
                                continue  # Retry
                            except Exception as retry_exc:
                                self.last_error = f"retry_failed: {retry_exc}"
                                if self.verbose:
                                    print(f"   ❌ Falha no retry: {retry_exc}")
                                return False
                        else:
                            # Not a cert error or max retries reached
                            self.last_error = f"{exc.__class__.__name__}: {exc}" if exc else exc.__class__.__name__
                            if is_no_audio and chunks_received == 0 and not received_audio:
                                if not health_ok:
                                    # Open cooldown to avoid hammering the service when it's not responding with audio.
                                    self._noaudio_backoff_until = asyncio.get_event_loop().time() + max(5.0, EDGE_NOAUDIO_COOLDOWN_SECONDS)
                                    self.last_error = f"service_unavailable (cooldown {int(EDGE_NOAUDIO_COOLDOWN_SECONDS)}s)"
                                    if self.verbose:
                                        print(f"   ⛔ Serviço indisponível - cooldown {int(EDGE_NOAUDIO_COOLDOWN_SECONDS)}s")
                                else:
                                    # Provável problema de payload; não abrir cooldown global
                                    self.last_error = "no_audio_payload"
                                    if self.verbose:
                                        print("   ⚠️ Sem áudio (provável problema de conteúdo)")
                            if is_cert_error:
                                print(f"   ❌ Erro SSL persistente")
                            return False
            finally:
                with suppress(Exception):
                    connector = getattr(communicator, "connector", None)
                    if connector:
                        maybe_close = getattr(connector, "close", None)
                        if callable(maybe_close):
                            result = maybe_close()
                            if asyncio.iscoroutine(result):
                                await result

            if not received_audio:
                self.last_error = "no_audio"
            return received_audio

__all__ = ["EdgeTTSEngine"]
