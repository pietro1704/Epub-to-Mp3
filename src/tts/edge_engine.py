# -*- coding: utf-8 -*-
"""Edge TTS engine wrapper used by the converter and tests."""

from __future__ import annotations

import asyncio
import importlib
from contextlib import suppress
from pathlib import Path
from typing import Dict, Optional
from unittest.mock import Mock

edge_tts = None

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
        if formatting_segments and TextFormattingProcessor:
            segments = self._prepare_formatted_segments(formatting_segments)
        else:
            segments = self._prepare_segments(text)

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

                segment_text = segment_text.strip()
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
        # Optimized timeout for speed
        estimated = (char_count / 10) * 1.2
        estimated += 20
        # Maximum timeout of 2 minutes for speed
        return int(min(max(estimated, 30), 120))

    def _prepare_segments(self, text: str) -> list[tuple[str, str]]:
        if text is None:
            if self.verbose:
                print("🔍 [VERBOSE] EdgeTTS _prepare_segments: text is None")
            return [(self.voice, "")]

        if LanguageMarkup is None:
            # Break very long texts into smaller chunks for better performance
            if len(text) > 8000:  # Increased threshold
                if self.verbose:
                    print(f"🔍 [VERBOSE] EdgeTTS processando texto muito longo: {len(text)} chars")
                chunks = []
                chunk_size = 7000  # Larger chunks
                for i in range(0, len(text), chunk_size):
                    chunk = text[i:i + chunk_size]
                    # Try to break at sentence boundaries
                    if i + chunk_size < len(text):
                        last_period = chunk.rfind('.')
                        last_exclamation = chunk.rfind('!')
                        last_question = chunk.rfind('?')
                        break_point = max(last_period, last_exclamation, last_question)
                        if break_point > chunk_size * 0.7:  # Only break if we have a reasonable chunk
                            chunk = chunk[:break_point + 1]
                    chunks.append((self.voice, chunk.strip()))
                if self.verbose:
                    print(f"🔍 [VERBOSE] EdgeTTS quebrou texto longo em {len(chunks)} chunks de ~{chunk_size} chars")
                return chunks
            return [(self.voice, text)]

        try:
            lowered = text.lower()
            if "[[lang:" not in lowered:
                # Break very long texts into smaller chunks even with LanguageMarkup
                if len(text) > 8000:  # Increased threshold
                    if self.verbose:
                        print(f"🔍 [VERBOSE] EdgeTTS processando texto longo sem tags: {len(text)} chars")
                    chunks = []
                    chunk_size = 7000  # Larger chunks
                    for i in range(0, len(text), chunk_size):
                        chunk = text[i:i + chunk_size]
                        if i + chunk_size < len(text):
                            last_period = chunk.rfind('.')
                            last_exclamation = chunk.rfind('!')
                            last_question = chunk.rfind('?')
                            break_point = max(last_period, last_exclamation, last_question)
                            if break_point > chunk_size * 0.7:
                                chunk = chunk[:break_point + 1]
                        chunks.append((self.voice, chunk.strip()))
                    if self.verbose:
                        print(f"🔍 [VERBOSE] EdgeTTS quebrou texto longo em {len(chunks)} chunks de ~{chunk_size} chars (sem tags)")
                    return chunks
                return [(self.voice, text)]

            # Count language tags for information
            lang_tag_count = lowered.count("[[lang:")
            if self.verbose and lang_tag_count > 50:
                print(f"🔍 [VERBOSE] EdgeTTS _prepare_segments: {lang_tag_count} tags [[lang:]] detectadas em texto de {len(text)} chars")

            segments = LanguageMarkup.parse(text, self.primary_language)
            if segments is None:
                if self.verbose:
                    print("🔍 [VERBOSE] EdgeTTS _prepare_segments: LanguageMarkup.parse returned None")
                return [(self.voice, text)]

            # Limit number of segments to prevent performance issues
            if len(segments) > 100:
                if self.verbose:
                    print(f"🔍 [VERBOSE] EdgeTTS _prepare_segments: {len(segments)} segments detected, using simplified processing")
                simplified_text = LanguageMarkup.strip(text) if LanguageMarkup else text
                return [(self.voice, simplified_text)]

            prepared: list[tuple[str, str]] = []
            for segment in segments:
                if segment is None:
                    if self.verbose:
                        print("🔍 [VERBOSE] EdgeTTS _prepare_segments: segment is None, skipping")
                    continue
                lang = (segment.language or "").split("-", 1)[0].lower()
                voice = self.language_voices.get(lang) or self.voice
                segment_text = getattr(segment, 'text', None) or ""
                prepared.append((voice, segment_text))

            result = prepared or [(self.voice, LanguageMarkup.strip(text) if LanguageMarkup else text)]
            if self.verbose:
                print(f"🔍 [VERBOSE] EdgeTTS _prepare_segments: returning {len(result)} segments")
            return result
        except Exception as e:
            if self.verbose:
                print(f"🔍 [VERBOSE] EdgeTTS _prepare_segments error: {e}")
            return [(self.voice, text or "")]

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

            stream = communicator.stream()
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
            try:
                with output_path.open(mode) as out_file:
                    await asyncio.wait_for(_consume_stream(out_file), timeout=timeout)
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
            except Exception as exc:  # pragma: no cover - defensive logging
                synthesis_time = asyncio.get_event_loop().time() - synthesis_start
                self.last_error = f"{exc.__class__.__name__}: {exc}" if exc else exc.__class__.__name__
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

    def _prepare_formatted_segments(self, formatting_segments) -> list[tuple[str, str]]:
        """Prepare formatted segments using SSML for Edge TTS"""
        if not formatting_segments or not TextFormattingProcessor:
            if self.verbose:
                print("🔍 [VERBOSE] EdgeTTS _prepare_formatted_segments: sem segmentos ou processador")
            return [(self.voice, "")]

        try:
            formatter = TextFormattingProcessor()
            ssml_text = formatter.to_edge_ssml(formatting_segments, self.voice)

            if self.verbose:
                print(f"🔍 [VERBOSE] EdgeTTS SSML gerado: {len(ssml_text)} chars")
                print(f"🔍 [VERBOSE] EdgeTTS SSML preview: {ssml_text[:200]}...")

            # Break very long SSML into chunks if needed
            if len(ssml_text) > 8000:
                if self.verbose:
                    print(f"🔍 [VERBOSE] EdgeTTS quebrando SSML longo em chunks")

                # For SSML, we need to be more careful about breaking
                # Extract the content between <speak> tags
                speak_start = ssml_text.find('>') + 1
                speak_end = ssml_text.rfind('</speak>')

                if speak_start > 0 and speak_end > speak_start:
                    content = ssml_text[speak_start:speak_end]
                    prefix = ssml_text[:speak_start]
                    suffix = ssml_text[speak_end:]

                    chunks = []
                    chunk_size = 7000
                    for i in range(0, len(content), chunk_size):
                        chunk_content = content[i:i + chunk_size]
                        # Try to break at voice tag boundaries for cleaner SSML
                        if i + chunk_size < len(content):
                            last_voice_end = chunk_content.rfind('</voice>')
                            if last_voice_end > chunk_size * 0.7:
                                chunk_content = chunk_content[:last_voice_end + 8]  # Include </voice>

                        chunk_ssml = prefix + chunk_content + suffix
                        chunks.append((self.voice, chunk_ssml))

                    if self.verbose:
                        print(f"🔍 [VERBOSE] EdgeTTS quebrou SSML em {len(chunks)} chunks")
                    return chunks

            return [(self.voice, ssml_text)]

        except Exception as e:
            if self.verbose:
                print(f"🔍 [VERBOSE] EdgeTTS erro ao processar formatação: {e}")
            # Fallback to plain text
            plain_text = " ".join([segment.text for segment in formatting_segments if segment.text])
            return [(self.voice, plain_text)]


__all__ = ["EdgeTTSEngine"]
