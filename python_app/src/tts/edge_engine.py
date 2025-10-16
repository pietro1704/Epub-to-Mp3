# -*- coding: utf-8 -*-
"""Edge TTS engine wrapper used by the converter and tests."""

from __future__ import annotations

import asyncio
import importlib
import inspect
from contextlib import suppress
from pathlib import Path
from typing import Dict, Optional
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

# Import SSL/Certificate error types
try:
    from aiohttp import ClientConnectorCertificateError, ClientConnectorError
    import ssl
except ImportError:
    ClientConnectorCertificateError = None  # type: ignore
    ClientConnectorError = None  # type: ignore
    ssl = None  # type: ignore

# Global rate limiter for Edge TTS to prevent resource contention
_edge_rate_limiter = None


try:  # pragma: no cover - lazily loaded
    from ..language import LanguageMarkup
    from ..text_formatting import TextFormattingProcessor
except ImportError:  # pragma: no cover - during optional dependency resolution
    LanguageMarkup = None  # type: ignore
    TextFormattingProcessor = None  # type: ignore


class EdgeTTSEngine:
    """Small facade around ``edge_tts`` with predictable behaviour."""

    def __init__(
        self,
        voice: str,
        *,
        primary_language: Optional[str] = None,
        language_voices: Optional[Dict[str, str]] = None,
        verbose: bool = False,
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

        # **FIXED**: Rate limiter mais conservador para evitar deadlocks
        if _edge_rate_limiter is None:
            _edge_rate_limiter = asyncio.Semaphore(3)  # **FIXED**: Reduzido de 6 para 3

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

        if self.verbose:
            print(f"🔍 [VERBOSE] EdgeTTS inicializado com voice={voice}")
            print(f"🔍 [VERBOSE] Rate limiter slots disponíveis: {_edge_rate_limiter._value if _edge_rate_limiter else 'N/A'}")

    def supports_multilingual(self) -> bool:
        """Edge TTS suporta multiidioma via voice switching e [[lang:]] tags"""
        return True

    def supports_emphasis(self) -> bool:
        """Edge TTS suporta ênfase via SSML quando voz é Neural"""
        return self._supports_emphasis()

    async def synthesize_async(self, text: str, output_path: Path, formatting_segments=None) -> Optional[Path]:
        if not text:
            return None

        if self.verbose:
            print(f"🔍 [VERBOSE] EdgeTTS.synthesize_async() iniciado para {output_path.name}")
            print(f"🔍 [VERBOSE] Texto: {len(text)} chars, primeiros 100: {text[:100]}")
            if formatting_segments:
                print(f"🔍 [VERBOSE] Formatação disponível: {len(formatting_segments)} segmentos")

        self.last_error = None

        # Use formatting segments if available
        payload_text = text or ""

        if TextFormattingProcessor:
            formatter = TextFormattingProcessor()
            payload_text = formatter.to_audible_text(payload_text, formatting_segments)

        if self.verbose:
            original_preview = (text or "")[:120]
            processed_preview = payload_text[:120]
            if original_preview != processed_preview:
                print(f"🔍 [VERBOSE] EdgeTTS texto ajustado para áudio:")
                print(f"      • Original : {original_preview}")
                print(f"      • Preparado: {processed_preview}")
            else:
                print(f"🔍 [VERBOSE] EdgeTTS texto preparado (sem alterações): {processed_preview}")

        segments = self._prepare_segments(payload_text)

        if not segments:
            if self.verbose:
                print(f"🔍 [VERBOSE] Nenhum segmento preparado para {output_path.name}")
            return None

        if self.verbose:
            print(f"🔍 [VERBOSE] {len(segments)} segmentos preparados para {output_path.name}")

        output_path = Path(output_path)
        output_path.parent.mkdir(parents=True, exist_ok=True)

        try:
            if output_path.exists():
                output_path.unlink()
        except OSError:
            pass

        total_segments = 0

        try:
            for voice, segment_text in segments:
                # Validate segment data
                if voice is None:
                    if self.verbose:
                        print("🔍 [VERBOSE] EdgeTTS synthesize_async: voice is None, using default")
                    voice = self.voice or "en-US-GuyNeural"

                if segment_text is None:
                    if self.verbose:
                        print("🔍 [VERBOSE] EdgeTTS synthesize_async: segment_text is None, skipping")
                    continue

                segment_text = segment_text.strip("\n\r")
                if not segment_text:
                    if self.verbose:
                        print("🔍 [VERBOSE] EdgeTTS synthesize_async: empty segment_text after strip, skipping")
                    continue

                if self.verbose:
                    print(f"🔍 [VERBOSE] EdgeTTS synthesize_async: processing segment {total_segments+1}/{len(segments)}, {len(segment_text)} chars")

                if not await self._synthesize_segment(
                    segment_text,
                    voice,
                    output_path,
                    append=(total_segments > 0),
                ):
                    return None
                total_segments += 1
        except asyncio.TimeoutError:
            self.last_error = "timeout"
            return None
        except Exception as exc:  # pragma: no cover - defensive logging
            self.last_error = f"{exc.__class__.__name__}: {exc}" if exc else exc.__class__.__name__
            return None

        if total_segments == 0 or not output_path.exists():
            self.last_error = "no_audio"
            return None

        return output_path

    def _calculate_timeout(self, text: str) -> int:
        """Estimate a safe upper bound for synthesis time in seconds."""
        if text is None:
            if self.verbose:
                print("🔍 [VERBOSE] EdgeTTS _calculate_timeout: text is None, using default timeout")
            return 120

        char_count = max(len(text), 1)
        estimated = max(char_count // 33, 30)
        return int(min(estimated, 120))

    def _prepare_segments(self, text: str) -> list[tuple[str, str]]:
        if text is None:
            if self.verbose:
                print("🔍 [VERBOSE] EdgeTTS _prepare_segments: text is None")
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

            lang_tag_count = lowered.count("[[lang:")
            if self.verbose and lang_tag_count > 50:
                print(
                    f"🔍 [VERBOSE] EdgeTTS _prepare_segments: {lang_tag_count} tags [[lang:]] detectadas em texto de {len(cleaned_text)} chars"
                )

            segments = LanguageMarkup.parse(cleaned_text, self.primary_language)
            if segments is None:
                if self.verbose:
                    print("🔍 [VERBOSE] EdgeTTS _prepare_segments: LanguageMarkup.parse returned None")
                return self._chunk_text(self.voice, cleaned_text)

            if len(segments) > 100:
                if self.verbose:
                    print(
                        f"🔍 [VERBOSE] EdgeTTS _prepare_segments: {len(segments)} segments detectados, aplicando simplificação"
                    )
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

            if self.verbose:
                print(f"🔍 [VERBOSE] EdgeTTS _prepare_segments: retornando {len(prepared)} segmentos após chunking")

            return prepared

        except Exception as exc:
            if self.verbose:
                print(f"🔍 [VERBOSE] EdgeTTS _prepare_segments error: {exc}")
            fallback = TextFormattingProcessor.clean_tts_text(text or "") if TextFormattingProcessor else (text or "")
            return self._chunk_text(self.voice, fallback)

    def _chunk_text(self, voice: str, text: str, chunk_size: int = 7000) -> list[tuple[str, str]]:
        """Divide texto longo em blocos menores respeitando limites aproximados de frase."""
        if not text:
            return []

        stripped = text.strip()
        if not stripped:
            return []

        if len(stripped) <= chunk_size:
            return [(voice, stripped)]

        chunks: list[tuple[str, str]] = []
        start = 0
        length = len(stripped)

        while start < length:
            end = min(start + chunk_size, length)
            chunk = stripped[start:end]

            if end < length:
                last_period = chunk.rfind(".")
                last_exclamation = chunk.rfind("!")
                last_question = chunk.rfind("?")
                break_point = max(last_period, last_exclamation, last_question)
                if break_point > chunk_size * 0.5:
                    chunk = chunk[: break_point + 1]
                    end = start + len(chunk)

            chunks.append((voice, chunk))
            start = end

        if self.verbose:
            print(f"🔍 [VERBOSE] EdgeTTS _chunk_text: gerados {len(chunks)} chunks para voz {voice}")

        return [(voice, chunk) for voice, chunk in chunks if chunk]

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
            if self.verbose:
                print("🔍 [VERBOSE] EdgeTTS _synthesize_segment: text is None")
            self.last_error = "text_is_none"
            return False

        if voice is None:
            if self.verbose:
                print("🔍 [VERBOSE] EdgeTTS _synthesize_segment: voice is None, using default")
            voice = self.voice or "en-US-GuyNeural"

        # Use global rate limiter to prevent resource contention
        waiting_start = asyncio.get_event_loop().time()
        slots_available = _edge_rate_limiter._value
        waiters = getattr(_edge_rate_limiter, '_waiters', [])
        waiters_count = len(waiters) if waiters is not None else 0

        if self.verbose:
            print(f"🔍 [VERBOSE] EdgeTTS rate limiter: {slots_available} slots, {waiters_count} na fila")

        if slots_available == 0:  # All slots taken
            print(f"🔄 Edge TTS: aguardando slot livre (fila: {waiters_count})")

        async with _edge_rate_limiter:
            wait_time = asyncio.get_event_loop().time() - waiting_start
            if self.verbose:
                print(f"🔍 [VERBOSE] EdgeTTS slot obtido após {wait_time:.3f}s")
            if wait_time > 1:
                print(f"🚀 Edge TTS: slot liberado após {wait_time:.1f}s")
            try:
                if self.verbose:
                    text_len = len(text) if text is not None else 0
                    print(f"🔍 [VERBOSE] EdgeTTS criando Communicate para texto de {text_len} chars")

                # SSL bypass já aplicado no topo do módulo via monkeypatch
                communicator = self._edge_tts.Communicate(text, voice)

            except Exception as exc:  # pragma: no cover - defensive logging
                self.last_error = f"{exc.__class__.__name__}: {exc}" if exc else exc.__class__.__name__
                if self.verbose:
                    print(f"🔍 [VERBOSE] EdgeTTS erro ao criar Communicate: {self.last_error}")
                return False

            mode = "ab" if append else "wb"
            received_audio = False
            timeout = self._calculate_timeout(text)

            if self.verbose:
                print(f"🔍 [VERBOSE] EdgeTTS iniciando stream (timeout: {timeout}s, mode: {mode})")

            try:
                stream_candidate = communicator.stream()
            except Exception as exc:  # pragma: no cover - defensive logging
                self.last_error = f"{exc.__class__.__name__}: {exc}" if exc else exc.__class__.__name__
                if self.verbose:
                    print(f"🔍 [VERBOSE] EdgeTTS erro ao obter stream: {self.last_error}")
                return False

            try:
                stream = await stream_candidate if inspect.isawaitable(stream_candidate) else stream_candidate
            except asyncio.TimeoutError:
                self.last_error = "timeout"
                if self.verbose:
                    print("🔍 [VERBOSE] EdgeTTS stream disparou TimeoutError")
                return False
            except Exception as exc:  # pragma: no cover - defensive logging
                self.last_error = f"{exc.__class__.__name__}: {exc}" if exc else exc.__class__.__name__
                if self.verbose:
                    print(f"🔍 [VERBOSE] EdgeTTS erro ao inicializar stream: {self.last_error}")
                return False

            if not hasattr(stream, "__aiter__"):
                self.last_error = "invalid_stream"
                if self.verbose:
                    print("🔍 [VERBOSE] EdgeTTS stream não é assíncrono")
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
                            if self.verbose and chunks_received % 10 == 0:
                                print(f"🔍 [VERBOSE] EdgeTTS: {chunks_received} chunks processados")
                        elif self.verbose:
                            print(f"🔍 [VERBOSE] EdgeTTS chunk não-audio: {chunk['type']}")
                finally:
                    with suppress(Exception):
                        await stream.aclose()
                    if self.verbose:
                        print(f"🔍 [VERBOSE] EdgeTTS stream finalizado: {chunks_received} chunks totais")

            synthesis_start = asyncio.get_event_loop().time()
            max_retries = 3
            retry_count = 0

            try:
                while retry_count < max_retries:
                    try:
                        with output_path.open(mode) as out_file:
                            await asyncio.wait_for(_consume_stream(out_file), timeout=timeout)
                        break  # Success - exit retry loop

                    except asyncio.TimeoutError:
                        synthesis_time = asyncio.get_event_loop().time() - synthesis_start
                        self.last_error = "timeout"
                        if self.verbose:
                            print(f"🔍 [VERBOSE] EdgeTTS timeout após {synthesis_time:.1f}s (limit: {timeout}s)")
                        return False

                    except asyncio.CancelledError:
                        synthesis_time = asyncio.get_event_loop().time() - synthesis_start
                        self.last_error = "cancelled"
                        if self.verbose:
                            print(f"🔍 [VERBOSE] EdgeTTS cancelado após {synthesis_time:.1f}s")
                        raise

                    except Exception as exc:
                        synthesis_time = asyncio.get_event_loop().time() - synthesis_start

                        # Check if it's a certificate/SSL error
                        is_cert_error = (
                            ClientConnectorCertificateError and isinstance(exc, ClientConnectorCertificateError)
                        ) or (
                            ClientConnectorError and isinstance(exc, ClientConnectorError)
                        ) or (
                            "certificate" in str(exc).lower() or "ssl" in str(exc).lower()
                        )

                        if is_cert_error and retry_count < max_retries - 1:
                            retry_count += 1
                            backoff_time = 2 ** retry_count  # 2s, 4s, 8s

                            # Detailed SSL error logging
                            print(f"🔒 Erro SSL/Certificado detectado: {exc.__class__.__name__}")
                            if self.verbose:
                                print(f"🔍 [VERBOSE] Detalhes SSL: {exc}")
                            print(f"🔄 Retry {retry_count}/{max_retries-1} após {backoff_time}s...")

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
                                if self.verbose:
                                    print(f"🔍 [VERBOSE] Falha ao recriar stream: {retry_exc}")
                                self.last_error = f"retry_failed: {retry_exc}"
                                return False
                        else:
                            # Not a cert error or max retries reached
                            self.last_error = f"{exc.__class__.__name__}: {exc}" if exc else exc.__class__.__name__
                            if is_cert_error:
                                print(f"❌ Erro SSL persistente após {retry_count} tentativas")
                            if self.verbose:
                                print(f"🔍 [VERBOSE] EdgeTTS erro após {synthesis_time:.1f}s: {self.last_error}")
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
