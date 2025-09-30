# -*- coding: utf-8 -*-
"""Edge TTS engine wrapper used by the converter and tests."""

from __future__ import annotations

import asyncio
import html
import importlib
import inspect
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
            for entry in segments:
                if len(entry) == 3:
                    voice, segment_text, is_ssml = entry
                else:
                    voice, segment_text = entry
                    is_ssml = segment_text.strip().lower().startswith('<speak')
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
                    ssml=is_ssml,
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
                sanitised = TextFormattingProcessor.strip_inline_markdown(text) if TextFormattingProcessor else text
                return [(self.voice, sanitised)]

            # Limit number of segments to prevent performance issues
            if len(segments) > 100:
                if self.verbose:
                    print(f"🔍 [VERBOSE] EdgeTTS _prepare_segments: {len(segments)} segments detected, using simplified processing")
                simplified_text = LanguageMarkup.strip(text) if LanguageMarkup else text
                simplified_text = TextFormattingProcessor.strip_inline_markdown(simplified_text) if TextFormattingProcessor else simplified_text
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
                if TextFormattingProcessor:
                    segment_text = TextFormattingProcessor.strip_inline_markdown(segment_text)
                prepared.append((voice, segment_text))

            final_segments: list[tuple[str, str, bool]] = []
            idx = 0
            while idx < len(prepared):
                voice, segment_text = prepared[idx]
                if not segment_text:
                    idx += 1
                    continue

                if (
                    voice == self.voice
                    and idx + 2 < len(prepared)
                    and prepared[idx + 1][0] != voice
                    and prepared[idx + 2][0] == voice
                ):
                    next_voice, next_text = prepared[idx + 1]
                    _, trailing_text = prepared[idx + 2]
                    final_segments.append((voice, segment_text, False))
                    combined = self._build_voice_switch_ssml(next_text, trailing_text, voice)
                    final_segments.append((next_voice, combined, True))
                    idx += 3
                    continue

                final_segments.append((voice, segment_text, False))
                idx += 1

            collapsed: list[tuple[str, str, bool]] = []
            for voice, segment_text, is_ssml in final_segments:
                if not segment_text:
                    continue
                if (
                    collapsed
                    and collapsed[-1][0] == voice
                    and not collapsed[-1][2]
                    and not is_ssml
                ):
                    prev_voice, prev_text, _ = collapsed[-1]
                    joiner = ""
                    if prev_text and not prev_text.endswith((" ", "\t", "\n")) and not segment_text.startswith((" ", "\t", "\n")):
                        joiner = " "
                    collapsed[-1] = (prev_voice, prev_text + joiner + segment_text, False)
                else:
                    collapsed.append((voice, segment_text, is_ssml))

            fallback_text = LanguageMarkup.strip(text) if LanguageMarkup else text
            if TextFormattingProcessor:
                fallback_text = TextFormattingProcessor.strip_inline_markdown(fallback_text)

            result = collapsed or [(self.voice, fallback_text)]
            if self.verbose:
                print(f"🔍 [VERBOSE] EdgeTTS _prepare_segments: returning {len(result)} segments")
            return result
        except Exception as e:
            if self.verbose:
                print(f"🔍 [VERBOSE] EdgeTTS _prepare_segments error: {e}")
            sanitised = TextFormattingProcessor.strip_inline_markdown(text or "") if TextFormattingProcessor else (text or "")
            return [(self.voice, sanitised)]

    def _supports_emphasis(self) -> bool:
        voice = (self.voice or "").lower()
        return "neural" in voice or voice.startswith("pt-br")

    def _build_emphasis_ssml(self, formatter: TextFormattingProcessor, segments) -> str:
        parts: list[str] = []
        for segment in segments:
            raw = (segment.text or "").strip()
            if not raw:
                continue
            escaped = formatter._escape_ssml(raw)
            fmt = (segment.formatting or '').lower()
            if fmt in {"italic", "emphasis"}:
                parts.append(f'<prosody rate="-10%" pitch="+7%">{escaped}</prosody>')
            elif fmt == "bold":
                parts.append(f'<prosody volume="+20%" rate="-5%">{escaped}</prosody>')
            elif fmt == "quote":
                parts.append(f'<prosody rate="-6%" pitch="-4%"><break time="150ms"/>{escaped}<break time="170ms"/></prosody>')
            elif fmt == "code":
                parts.append(f'<prosody rate="-25%" pitch="-8%">{escaped}</prosody>')
            else:
                parts.append(escaped)

        if not parts:
            fallback = " ".join(segment.text for segment in segments if segment.text)
            fallback = formatter._escape_ssml(fallback)
            parts.append(fallback)

        body = ' '.join(parts)
        return (
            '<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" '
            'xmlns:mstts="http://www.w3.org/2001/mstts">'
            f'{body}'
            '</speak>'
        )

    @staticmethod
    def _escape_ssml(text: str) -> str:
        return html.escape(text or "", quote=False)

    def _build_voice_switch_ssml(self, lead_text: str, trailing_text: str, fallback_voice: str) -> str:
        lead = self._escape_ssml(lead_text)
        trailing = self._escape_ssml(trailing_text)
        trailing_part = (
            f'<voice name="{self._escape_ssml(fallback_voice)}">{trailing}</voice>'
            if trailing_text
            else ""
        )
        return (
            '<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" '
            'xmlns:mstts="http://www.w3.org/2001/mstts">'
            f'{lead}{trailing_part}'
            '</speak>'
        )

    async def _synthesize_segment(
        self,
        text: str,
        voice: str,
        output_path: Path,
        *,
        append: bool,
        ssml: bool = False,
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
                kwargs = {"ssml": True} if ssml else {}
                try:
                    communicator = self._edge_tts.Communicate(text, voice, **kwargs)
                except TypeError:
                    if ssml:
                        communicator = self._edge_tts.Communicate(text, voice)
                    else:
                        raise
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

    def _prepare_formatted_segments(self, formatting_segments) -> list[tuple[str, str, bool]]:
        """Prepare formatted segments, applying emphasis when supported."""
        if not formatting_segments or not TextFormattingProcessor:
            if self.verbose:
                print("🔍 [VERBOSE] EdgeTTS _prepare_formatted_segments: sem segmentos ou processador")
            return [(self.voice, "", False)]

        formatter = TextFormattingProcessor()

        try:
            if self._supports_emphasis():
                ssml_payload = self._build_emphasis_ssml(formatter, formatting_segments)
                if self.verbose:
                    print(f"🔍 [VERBOSE] EdgeTTS SSML gerado: {len(ssml_payload)} chars")
                return [(self.voice, ssml_payload, True)]

            plain_text = formatter.to_plain_text_with_pauses(formatting_segments)
            plain_text = TextFormattingProcessor.strip_inline_markdown(plain_text)

            if len(plain_text) > 8000:
                if self.verbose:
                    print(f"🔍 [VERBOSE] EdgeTTS quebrando texto longo em chunks")
                chunks = []
                chunk_size = 7000
                for i in range(0, len(plain_text), chunk_size):
                    chunk = plain_text[i:i + chunk_size]
                    if i + chunk_size < len(plain_text):
                        last_period = chunk.rfind('.')
                        last_exclamation = chunk.rfind('!')
                        last_question = chunk.rfind('?')
                        break_point = max(last_period, last_exclamation, last_question)
                        if break_point > chunk_size * 0.7:
                            chunk = chunk[:break_point + 1]
                    chunks.append((self.voice, chunk.strip(), False))
                return chunks

            return [(self.voice, plain_text, False)]

        except Exception as e:
            if self.verbose:
                print(f"🔍 [VERBOSE] EdgeTTS erro ao processar formatação: {e}")
            fallback = " ".join([segment.text for segment in formatting_segments if segment.text])
            fallback = TextFormattingProcessor.strip_inline_markdown(fallback)
            return [(self.voice, fallback, False)]


__all__ = ["EdgeTTSEngine"]
