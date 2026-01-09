# -*- coding: utf-8 -*-
"""
Spark-TTS engine wrapper.

Spark-TTS is an LLM-based TTS system built on Qwen2.5 that supports
zero-shot voice cloning and high-quality speech synthesis.

Model: SparkAudio/Spark-TTS-0.5B (500M parameters)

Installation:
    # Clone the repository
    git clone https://github.com/SparkAudio/Spark-TTS.git
    cd Spark-TTS
    pip install -r requirements.txt

    # Or install via huggingface_hub
    pip install huggingface_hub transformers torch torchaudio soundfile

Features:
    - Zero-shot voice cloning
    - High quality neural TTS
    - Based on Qwen2.5 LLM
    - GPU recommended (CUDA)
"""

from __future__ import annotations

import asyncio
import contextlib
import importlib.util
import os
import re
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Callable, Dict, List, Optional

# Lazy imports
sf = None
np = None
torch = None

try:
    import numpy as _np
    import soundfile as _sf

    np = _np
    sf = _sf
except ImportError:
    pass

try:
    import torch as _torch

    torch = _torch
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


# Default settings
DEFAULT_MODEL_DIR = os.getenv("SPARK_TTS_MODEL_DIR", "pretrained_models/Spark-TTS-0.5B")
DEFAULT_CHUNK_CHARS = int(os.getenv("SPARK_CHUNK_CHARS", "1500"))
MAX_WORKERS = int(os.getenv("SPARK_MAX_WORKERS", "1"))
SAMPLE_RATE = 16000

# Voice samples directory (for cloning)
VOICE_SAMPLES_DIR = Path(__file__).parent.parent.parent / "voice_samples" / "spark"


# Built-in speaker embeddings (preset voices)
SPARK_VOICES = {
    # These are example voice names - actual voices come from reference audio
    "default": "Default Spark Voice",
    "clone": "Custom Voice (requires reference audio)",
}


def _find_spark_tts_path() -> Optional[Path]:
    """Find Spark-TTS installation path."""
    # Check environment variable
    env_path = os.getenv("SPARK_TTS_PATH")
    if env_path and Path(env_path).exists():
        return Path(env_path)

    # Check common locations
    candidates = [
        Path.home() / "Spark-TTS",
        Path("/opt/Spark-TTS"),
        Path(__file__).parent.parent.parent.parent / "Spark-TTS",
        Path.cwd() / "Spark-TTS",
    ]

    for candidate in candidates:
        if candidate.exists() and (candidate / "cli").exists():
            return candidate

    return None


def _download_model(model_dir: Path) -> bool:
    """Download Spark-TTS model from HuggingFace."""
    try:
        from huggingface_hub import snapshot_download

        model_dir.parent.mkdir(parents=True, exist_ok=True)
        snapshot_download(
            "SparkAudio/Spark-TTS-0.5B",
            local_dir=str(model_dir),
            local_dir_use_symlinks=False,
        )
        return True
    except Exception as e:
        print(f"Failed to download Spark-TTS model: {e}")
        return False


class SparkTTSEngine:
    """Spark-TTS engine - LLM-based high-quality TTS with voice cloning."""

    def __init__(
        self,
        voice: str = "default",
        *,
        model_dir: Optional[str] = None,
        primary_language: Optional[str] = None,
        language_voices: Optional[Dict[str, str]] = None,
        verbose: bool = False,
        formatting_cues_enabled: bool = True,
        formatting_locale: str = "pt",
        chunk_char_limit: Optional[int] = None,
        max_workers: Optional[int] = None,
        status_callback: Optional[Callable[[str], None]] = None,
        reference_audio: Optional[str] = None,
        reference_text: Optional[str] = None,
        device: Optional[str] = None,
    ) -> None:
        self.voice = voice or "default"
        self.model_dir = Path(model_dir or DEFAULT_MODEL_DIR)
        self.primary_language = (primary_language or "en").split("-")[0].lower()
        self.language_voices = language_voices or {}
        self.verbose = verbose
        self.formatting_cues_enabled = formatting_cues_enabled
        self.formatting_locale = formatting_locale
        self.chunk_limit = chunk_char_limit or DEFAULT_CHUNK_CHARS
        self.max_workers = max_workers or MAX_WORKERS
        self.status_callback = status_callback

        # Voice cloning settings
        self.reference_audio = reference_audio
        self.reference_text = reference_text

        # Device selection
        if device:
            self.device = device
        elif torch is not None and torch.cuda.is_available():
            self.device = "cuda"
        elif (
            torch is not None
            and hasattr(torch.backends, "mps")
            and torch.backends.mps.is_available()
        ):
            self.device = "mps"
        else:
            self.device = "cpu"

        self._spark_path = _find_spark_tts_path()
        self._model_loaded = False
        self._inference_module = None
        self._executor = ThreadPoolExecutor(max_workers=self.max_workers)
        self._lock = asyncio.Lock()

    def supports_multilingual(self) -> bool:
        """Spark-TTS supports multiple languages."""
        return True

    def supports_emphasis(self) -> bool:
        """Spark-TTS supports prosody through LLM understanding."""
        return True

    def _ensure_model(self) -> bool:
        """Ensure model is available."""
        if self.model_dir.exists() and (self.model_dir / "config.json").exists():
            return True

        if self.status_callback:
            self.status_callback("Downloading Spark-TTS model...")

        return _download_model(self.model_dir)

    def _load_inference_module(self):
        """Load Spark-TTS inference module."""
        if self._inference_module is not None:
            return self._inference_module

        if self._spark_path is None:
            # Try to use huggingface transformers directly
            if (
                importlib.util.find_spec("transformers") is None
                or importlib.util.find_spec("torchaudio") is None
            ):
                raise ImportError(
                    "Spark-TTS not found. Either:\n"
                    "1. Clone repo: git clone https://github.com/SparkAudio/Spark-TTS.git\n"
                    "2. Set SPARK_TTS_PATH environment variable\n"
                    "3. Install: pip install transformers torch torchaudio"
                )

            # This is a simplified approach - full Spark-TTS has more complex inference
            self._inference_module = "transformers"
            return self._inference_module

        # Add Spark-TTS to path
        sys.path.insert(0, str(self._spark_path))
        try:
            from cli.SparkTTS import SparkTTS

            self._inference_module = SparkTTS
            return self._inference_module
        except ImportError as e:
            raise ImportError(f"Failed to import Spark-TTS: {e}")

    def _split_text(self, text: str) -> List[str]:
        """Split text into chunks respecting sentence boundaries."""
        if len(text) <= self.chunk_limit:
            return [text]

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

    def _synthesize_via_cli(
        self,
        text: str,
        output_path: Path,
    ) -> Optional[Path]:
        """Synthesize using Spark-TTS CLI."""
        if self._spark_path is None:
            return None

        cmd = [
            sys.executable,
            "-m",
            "cli.inference",
            "--text",
            text,
            "--model_dir",
            str(self.model_dir),
            "--save_dir",
            str(output_path.parent),
            "--device",
            "0" if self.device == "cuda" else "cpu",
        ]

        if self.reference_audio and Path(self.reference_audio).exists():
            cmd.extend(["--prompt_speech_path", self.reference_audio])
            if self.reference_text:
                cmd.extend(["--prompt_text", self.reference_text])

        try:
            result = subprocess.run(
                cmd,
                cwd=str(self._spark_path),
                capture_output=True,
                text=True,
                timeout=300,
            )

            if result.returncode == 0:
                # Find generated file
                generated = list(output_path.parent.glob("*.wav"))
                if generated:
                    latest = max(generated, key=lambda p: p.stat().st_mtime)
                    if latest != output_path:
                        shutil.move(str(latest), str(output_path))
                    return output_path

            if self.verbose:
                print(f"Spark-TTS CLI error: {result.stderr}")

        except Exception as e:
            if self.verbose:
                print(f"Spark-TTS CLI exception: {e}")

        return None

    def _synthesize_chunk_sync(
        self,
        text: str,
        output_path: Path,
    ) -> Optional[Path]:
        """Synchronously synthesize a chunk of text."""
        try:
            if not self._ensure_model():
                return None

            # Try CLI first if available
            if self._spark_path:
                return self._synthesize_via_cli(text, output_path)

            # Fallback to direct model usage (simplified)
            module = self._load_inference_module()

            if module == "transformers":
                # Simplified transformers-based inference
                # Note: Full Spark-TTS inference is more complex
                return self._synthesize_with_transformers(text, output_path)

            # Use SparkTTS class if available
            if hasattr(module, "__call__") or hasattr(module, "inference"):
                model = module(self.model_dir, device=self.device)

                if self.reference_audio and Path(self.reference_audio).exists():
                    audio = model.inference(
                        text,
                        prompt_speech_path=self.reference_audio,
                        prompt_text=self.reference_text,
                    )
                else:
                    audio = model.inference(text)

                if audio is not None and sf is not None:
                    sf.write(str(output_path), audio, SAMPLE_RATE)
                    return output_path

        except Exception as e:
            if self.verbose:
                print(f"Spark-TTS synthesis error: {e}")

        return None

    def _synthesize_with_transformers(
        self,
        text: str,
        output_path: Path,
    ) -> Optional[Path]:
        """Simplified synthesis using transformers (may not produce optimal results)."""
        try:
            from transformers import AutoModelForCausalLM, AutoTokenizer

            # This is a placeholder - actual Spark-TTS uses custom inference
            # Full implementation requires the SparkTTS class from the repo
            if self.verbose:
                print(
                    "Warning: Using simplified transformers inference. "
                    "For best results, install full Spark-TTS repo."
                )

            # Load model
            model = AutoModelForCausalLM.from_pretrained(
                str(self.model_dir),
                torch_dtype=torch.float16 if self.device != "cpu" else torch.float32,
                device_map=self.device,
            )
            tokenizer = AutoTokenizer.from_pretrained(str(self.model_dir))

            # Generate (simplified - actual inference is more complex)
            inputs = tokenizer(text, return_tensors="pt").to(self.device)
            model.generate(**inputs, max_new_tokens=2048)

            # Note: Actual audio decoding requires BiCodec from Spark-TTS
            # This is a placeholder that won't produce valid audio without full repo

            return None

        except Exception as e:
            if self.verbose:
                print(f"Transformers synthesis error: {e}")
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

        if contains_markup and LanguageMarkup is not None:
            text = LanguageMarkup.strip(text)

        # Split into chunks
        chunks = self._split_text(text.strip())

        if not chunks:
            return None

        # Synthesize chunks
        audio_parts = []
        loop = asyncio.get_event_loop()

        with tempfile.TemporaryDirectory() as temp_dir:
            temp_dir = Path(temp_dir)

            for i, chunk in enumerate(chunks):
                if progress_callback:
                    try:
                        progress_callback(chunk[:50], len(text))
                    except Exception:
                        pass

                temp_output = temp_dir / f"chunk_{i}.wav"

                # Synthesize in thread pool
                result = await loop.run_in_executor(
                    self._executor,
                    self._synthesize_chunk_sync,
                    chunk,
                    temp_output,
                )

                if result and result.exists() and sf is not None:
                    audio, sr = sf.read(str(result))
                    audio_parts.append((audio, sr))

                    if chunk_callback:
                        try:
                            chunk_callback(i, result)
                        except Exception:
                            pass

        if not audio_parts:
            return None

        # Combine and write
        try:
            # Use first sample rate
            target_sr = audio_parts[0][1]
            combined_audio = []

            for audio, sr in audio_parts:
                if sr != target_sr and np is not None:
                    # Simple resampling
                    ratio = target_sr / sr
                    indices = np.round(np.arange(0, len(audio), 1 / ratio)).astype(int)
                    indices = indices[indices < len(audio)]
                    audio = audio[indices]
                combined_audio.append(audio)

            final_audio = (
                np.concatenate(combined_audio) if len(combined_audio) > 1 else combined_audio[0]
            )
            sf.write(str(output_path), final_audio, target_sr)
            return output_path if output_path.exists() else None

        except Exception as e:
            if self.verbose:
                print(f"Spark-TTS write error: {e}")
            return None

    def cleanup(self):
        """Release resources."""
        self._inference_module = None
        with contextlib.suppress(Exception):
            self._executor.shutdown(wait=False)


def get_available_voices() -> Dict[str, str]:
    """Return available Spark-TTS voices."""
    return SPARK_VOICES.copy()


def check_installation() -> Dict[str, bool]:
    """Check Spark-TTS installation status."""
    status = {
        "spark_tts_path": _find_spark_tts_path() is not None,
        "model_available": Path(DEFAULT_MODEL_DIR).exists(),
        "torch_available": torch is not None,
        "cuda_available": torch is not None and torch.cuda.is_available(),
        "soundfile_available": sf is not None,
    }
    return status


__all__ = ["SparkTTSEngine", "get_available_voices", "check_installation", "SPARK_VOICES"]
