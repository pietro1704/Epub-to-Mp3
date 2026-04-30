# -*- coding: utf-8 -*-
"""
Kokoro TTS engine wrapper.

Kokoro is a lightweight (82M params) but high-quality TTS model.
Apache licensed, supports multiple languages.

Installation:
    pip install kokoro>=0.9.4 soundfile
    # Linux: apt-get install espeak-ng
    # macOS: brew install espeak

Supported languages:
    - 'a' => American English
    - 'b' => British English
    - 'j' => Japanese (requires: pip install misaki[ja])
    - 'z' => Mandarin Chinese (requires: pip install misaki[zh])

Available voices (examples):
    - af_heart, af_bella, af_nicole, af_nova, af_sky, af_sarah
    - am_adam, am_michael
    - bf_emma, bf_isabella
    - bm_george, bm_lewis
"""

from __future__ import annotations

import asyncio
import contextlib
import os
import platform
import re
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Callable, Dict, List, Optional, Tuple

_IS_MACOS = platform.system().lower() == "darwin"
_DISABLE_NATIVE_DEPENDENCIES = _IS_MACOS and os.environ.get("FORCE_KOKORO_NATIVE_DEPS", "0") != "1"

# Lazy imports
KPipeline = None
sf = None
np = None

if not _DISABLE_NATIVE_DEPENDENCIES:
    try:
        import numpy as _np
        import soundfile as _sf

        np = _np
        sf = _sf
    except ImportError:
        pass

try:
    from ..language import LanguageMarkup
except ImportError:
    LanguageMarkup = None

try:
    from ..text_formatting import TextFormattingProcessor
except ImportError:
    TextFormattingProcessor = None


# Language code mapping: ISO -> Kokoro lang_code
LANG_CODE_MAP = {
    "en": "a",  # American English (default)
    "en-us": "a",  # American English
    "en-gb": "b",  # British English
    "ja": "j",  # Japanese
    "jp": "j",  # Japanese alias
    "zh": "z",  # Mandarin Chinese
    "zh-cn": "z",  # Mandarin Chinese
}

_SUPPORTED_BASE_LANGS = {"en", "ja", "zh"}


def kokoro_supports_language(language: Optional[str]) -> bool:
    """Return True when Kokoro has a native voice for the requested language."""
    if not language:
        return True
    normalized = language.strip().lower()
    if not normalized or normalized == "auto":
        return True
    normalized = normalized.replace("_", "-")
    base = normalized.split("-", 1)[0]
    return base in _SUPPORTED_BASE_LANGS


# Default voices per language
DEFAULT_VOICES = {
    "a": "af_heart",  # American English female
    "b": "bf_emma",  # British English female
    "j": "jf_alpha",  # Japanese female
    "z": "zf_xiaobei",  # Chinese female
}

# All available Kokoro voices
KOKORO_VOICES = {
    # American English Female
    "af_alloy": "American English Female - Alloy",
    "af_aoede": "American English Female - Aoede",
    "af_bella": "American English Female - Bella",
    "af_heart": "American English Female - Heart (default)",
    "af_jessica": "American English Female - Jessica",
    "af_kore": "American English Female - Kore",
    "af_nicole": "American English Female - Nicole",
    "af_nova": "American English Female - Nova",
    "af_river": "American English Female - River",
    "af_sarah": "American English Female - Sarah",
    "af_sky": "American English Female - Sky",
    # American English Male
    "am_adam": "American English Male - Adam",
    "am_echo": "American English Male - Echo",
    "am_eric": "American English Male - Eric",
    "am_fenrir": "American English Male - Fenrir",
    "am_liam": "American English Male - Liam",
    "am_michael": "American English Male - Michael",
    "am_onyx": "American English Male - Onyx",
    "am_puck": "American English Male - Puck",
    "am_santa": "American English Male - Santa",
    # British English Female
    "bf_emma": "British English Female - Emma",
    "bf_isabella": "British English Female - Isabella",
    "bf_alice": "British English Female - Alice",
    "bf_lily": "British English Female - Lily",
    # British English Male
    "bm_george": "British English Male - George",
    "bm_lewis": "British English Male - Lewis",
    "bm_daniel": "British English Male - Daniel",
    "bm_fable": "British English Male - Fable",
    # Japanese Female
    "jf_alpha": "Japanese Female - Alpha",
    "jf_gongitsune": "Japanese Female - Gongitsune",
    "jf_nezumi": "Japanese Female - Nezumi",
    "jf_tebukuro": "Japanese Female - Tebukuro",
    # Japanese Male
    "jm_kumo": "Japanese Male - Kumo",
    # Chinese Female
    "zf_xiaobei": "Chinese Female - Xiaobei",
    "zf_xiaoni": "Chinese Female - Xiaoni",
    "zf_xiaoxiao": "Chinese Female - Xiaoxiao",
    "zf_xiaoyi": "Chinese Female - Xiaoyi",
    # Chinese Male
    "zm_yunjian": "Chinese Male - Yunjian",
    "zm_yunxi": "Chinese Male - Yunxi",
    "zm_yunxia": "Chinese Male - Yunxia",
    "zm_yunyang": "Chinese Male - Yunyang",
}

# Chunk settings
DEFAULT_CHUNK_CHARS = int(os.getenv("KOKORO_CHUNK_CHARS", "3000"))
MAX_WORKERS = int(os.getenv("KOKORO_MAX_WORKERS", str(max(2, (os.cpu_count() or 2) // 2))))
SAMPLE_RATE = 24000


def _ensure_kokoro():
    """Lazy load Kokoro pipeline."""
    global KPipeline
    if KPipeline is None:
        try:
            from kokoro import KPipeline as _KPipeline

            KPipeline = _KPipeline
        except ImportError as e:
            raise ImportError(
                "Kokoro TTS not installed. Install with: pip install kokoro>=0.9.4 soundfile\n"
                "On Linux: apt-get install espeak-ng\n"
                "On macOS: brew install espeak"
            ) from e
    return KPipeline


class KokoroTTSEngine:
    """Kokoro TTS engine - lightweight and fast."""

    def __init__(
        self,
        voice: str = "af_heart",
        *,
        primary_language: Optional[str] = None,
        language_voices: Optional[Dict[str, str]] = None,
        verbose: bool = False,
        formatting_cues_enabled: bool = True,
        formatting_locale: str = "pt",
        chunk_char_limit: Optional[int] = None,
        max_workers: Optional[int] = None,
        status_callback: Optional[Callable[[str], None]] = None,
        enable_character_voices: bool = False,
        narrator_voice: Optional[str] = None,
        character_voice: Optional[str] = None,
    ) -> None:
        self.voice = voice or "af_heart"
        self.primary_language = (primary_language or "en").split("-")[0].lower()
        self.language_voices = language_voices or {}
        self.verbose = verbose
        self.formatting_cues_enabled = formatting_cues_enabled
        self.formatting_locale = formatting_locale
        self.chunk_limit = chunk_char_limit or DEFAULT_CHUNK_CHARS
        self.max_workers = max_workers or MAX_WORKERS
        self.status_callback = status_callback

        # Multi-voice narration (v0.3.20). Kokoro voices are simple
        # string IDs (e.g. "af_heart", "bf_heart"); we just need two
        # different ones to enable the split. Falls back to single
        # voice when either slot is empty or both match.
        self.narrator_voice = (narrator_voice or "").strip() or self.voice
        self.character_voice = (character_voice or "").strip() or self.voice
        self.enable_character_voices = bool(enable_character_voices) and (
            self.narrator_voice != self.character_voice
        )

        if not kokoro_supports_language(self.primary_language):
            raise ValueError(
                f"Kokoro currently supports only English, Japanese, and Chinese voices "
                f"(requested: {self.primary_language or 'unknown'})"
            )

        # Pipeline cache per language
        self._pipelines: Dict[str, object] = {}
        self._executor = ThreadPoolExecutor(max_workers=self.max_workers)
        self._lock = asyncio.Lock()

    def supports_multilingual(self) -> bool:
        """Kokoro supports multiple languages via lang_code."""
        return True

    def supports_emphasis(self) -> bool:
        """Kokoro supports basic prosody control."""
        return True

    def _get_lang_code(self, language: str) -> str:
        """Convert ISO language code to Kokoro lang_code."""
        lang = (language or "en").lower().replace("_", "-")
        return LANG_CODE_MAP.get(lang, LANG_CODE_MAP.get(lang.split("-")[0], "a"))

    def _get_voice_for_language(self, language: str) -> str:
        """Get appropriate voice for language."""
        lang = (language or "").lower().split("-")[0]

        # Check user-defined language voices
        if lang in self.language_voices:
            return self.language_voices[lang]

        # Get lang_code and default voice
        lang_code = self._get_lang_code(language)

        # If current voice matches language, use it
        if self.voice.startswith(lang_code[0]):
            return self.voice

        # Return default voice for language
        return DEFAULT_VOICES.get(lang_code, "af_heart")

    def _get_pipeline(self, lang_code: str) -> object:
        """Get or create pipeline for language."""
        if lang_code not in self._pipelines:
            KPipelineClass = _ensure_kokoro()
            if self.status_callback:
                self.status_callback(f"Loading Kokoro model for '{lang_code}'...")
            self._pipelines[lang_code] = KPipelineClass(lang_code=lang_code)
        return self._pipelines[lang_code]

    def _split_text(self, text: str) -> List[str]:
        """Split text into chunks respecting sentence boundaries."""
        if len(text) <= self.chunk_limit:
            return [text]

        # Split by sentences
        sentences = re.split(r"(?<=[.!?])\s+", text)
        chunks = []
        current_chunk = ""

        for sentence in sentences:
            if len(current_chunk) + len(sentence) + 1 <= self.chunk_limit:
                current_chunk = f"{current_chunk} {sentence}".strip()
            else:
                if current_chunk:
                    chunks.append(current_chunk)
                if len(sentence) > self.chunk_limit:
                    # Split long sentence by words
                    words = sentence.split()
                    current_chunk = ""
                    for word in words:
                        if len(current_chunk) + len(word) + 1 <= self.chunk_limit:
                            current_chunk = f"{current_chunk} {word}".strip()
                        else:
                            if current_chunk:
                                chunks.append(current_chunk)
                            current_chunk = word
                else:
                    current_chunk = sentence

        if current_chunk:
            chunks.append(current_chunk)

        return chunks or [text]

    def _synthesize_chunk_sync(
        self,
        text: str,
        lang_code: str,
        voice: str,
    ) -> Optional[bytes]:
        """Synchronously synthesize a chunk of text."""
        try:
            pipeline = self._get_pipeline(lang_code)
            audio_chunks = []

            for gs, ps, audio in pipeline(text, voice=voice):
                if audio is not None:
                    audio_chunks.append(audio)

            if not audio_chunks:
                return None

            # Concatenate audio
            combined = np.concatenate(audio_chunks) if len(audio_chunks) > 1 else audio_chunks[0]
            return combined

        except Exception as e:
            if self.verbose:
                print(f"Kokoro synthesis error: {e}")
            return None

    async def synthesize_async(
        self,
        text: str,
        output_path: Path,
        formatting_segments=None,
        progress_callback=None,
        chunk_callback=None,
        **kwargs,
    ) -> Optional[Path]:
        """Synthesize text to audio file."""
        if not text or not text.strip():
            return None

        output_path = Path(output_path)

        # Ensure output is .wav
        if output_path.suffix.lower() != ".wav":
            output_path = output_path.with_suffix(".wav")

        # Process formatting
        if TextFormattingProcessor:
            formatter = TextFormattingProcessor(
                cues_enabled=self.formatting_cues_enabled,
                cue_locale=self.formatting_locale,
            )
            try:
                text = formatter.to_audible_text(text, formatting_segments) or text
            except Exception:
                text = formatter.clean_tts_text(text)

        # Parse language segments if markup present
        contains_markup = LanguageMarkup is not None and "[[lang:" in text.lower()
        default_lang = self.primary_language or "en"

        segments: List[Tuple[str, str]]
        if contains_markup and LanguageMarkup is not None:
            parsed = LanguageMarkup.parse(text, default_lang)
            segments = [(s.language, s.text) for s in parsed if s and s.text]
        else:
            plain_text = LanguageMarkup.strip(text) if LanguageMarkup else text
            segments = [(default_lang, plain_text)]

        # Synthesize each segment
        audio_parts = []
        loop = asyncio.get_event_loop()

        # Multi-voice expansion (v0.3.20): when character voices are
        # active, split each language segment into narrator/character
        # spans BEFORE chunking so each role gets its own Kokoro voice.
        # The dialogue splitter routes quoted dialogue to the character
        # voice and everything else stays with the narrator. Same module
        # the Edge engine uses; identical behaviour for the listener.
        expanded_segments: List[Tuple[str, str, str]] = []  # (lang, voice, text)
        if self.enable_character_voices:
            try:
                from ..dialogue_splitter import split_into_dialogue_spans
            except Exception:
                split_into_dialogue_spans = None  # type: ignore[assignment]
        else:
            split_into_dialogue_spans = None  # type: ignore[assignment]

        for lang, segment_text in segments:
            segment_text = segment_text.strip()
            if not segment_text:
                continue
            base_voice = self._get_voice_for_language(lang)
            if split_into_dialogue_spans is not None:
                spans = split_into_dialogue_spans(segment_text)
                roles_seen = {span.role for span in spans if span.text.strip()}
                if len(roles_seen) >= 2:
                    for span in spans:
                        body = span.text.strip()
                        if not body:
                            continue
                        role_voice = (
                            self.character_voice
                            if span.role == "character"
                            else self.narrator_voice
                        )
                        # Language-specific override from base voice
                        # picker still wins for non-default languages —
                        # multi-voice only kicks in for the primary lang
                        # where narrator/character voices were chosen.
                        chosen = role_voice if base_voice == self.voice else base_voice
                        expanded_segments.append((lang, chosen, body))
                    continue
            expanded_segments.append((lang, base_voice, segment_text))

        for lang, voice, segment_text in expanded_segments:
            lang_code = self._get_lang_code(lang)

            # Split into chunks
            chunks = self._split_text(segment_text)

            for i, chunk in enumerate(chunks):
                if progress_callback:
                    try:
                        progress_callback(chunk[:50], len(text))
                    except Exception:
                        pass

                # Synthesize in thread pool
                audio = await loop.run_in_executor(
                    self._executor,
                    self._synthesize_chunk_sync,
                    chunk,
                    lang_code,
                    voice,
                )

                if audio is not None:
                    audio_parts.append(audio)

                    if chunk_callback:
                        try:
                            chunk_callback(i, None, chunk)
                        except TypeError:
                            # Fallback for callbacks that don't accept text parameter
                            try:
                                chunk_callback(i, None)
                            except Exception:
                                pass
                        except Exception:
                            pass

        if not audio_parts:
            return None

        # Combine and write
        try:
            combined = np.concatenate(audio_parts) if len(audio_parts) > 1 else audio_parts[0]
            sf.write(str(output_path), combined, SAMPLE_RATE)
            return output_path if output_path.exists() else None
        except Exception as e:
            if self.verbose:
                print(f"Kokoro write error: {e}")
            return None

    def cleanup(self):
        """Release resources."""
        self._pipelines.clear()
        with contextlib.suppress(Exception):
            self._executor.shutdown(wait=False)


def get_available_voices() -> Dict[str, str]:
    """Return all available Kokoro voices."""
    return KOKORO_VOICES.copy()


def get_voices_by_language(lang_code: str = "a") -> Dict[str, str]:
    """Return voices for a specific language code."""
    prefix = lang_code[0] if lang_code else "a"
    return {k: v for k, v in KOKORO_VOICES.items() if k.startswith(prefix)}


__all__ = ["KokoroTTSEngine", "get_available_voices", "get_voices_by_language", "KOKORO_VOICES"]
