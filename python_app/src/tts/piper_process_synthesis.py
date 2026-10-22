"""Own single-process Piper synthesis, stall detection and character-voice composition."""

from __future__ import annotations

import asyncio
import contextlib
import os
import shutil
import tempfile
import time
from pathlib import Path
from typing import List, Optional


class PiperProcessSynthesis:
    async def _synthesize_with_character_voices(
        self,
        text: str,
        output_path: Path,
        *,
        progress_callback=None,
        chunk_callback=None,
        pre_segment_callback=None,
    ) -> Optional[Path]:
        """Mirror of Edge-TTS dialogue splitting for Piper.

        Splits ``text`` into narrator/character spans using the same
        ``dialogue_splitter`` Edge uses; synthesises each span with the
        matching Piper model; concatenates the WAV outputs into
        ``output_path``. Returns ``None`` and lets the caller fall back
        to single-voice synthesis when:

          * the splitter found only one role (no quoted dialogue);
          * numpy/soundfile aren't available (concat impossible);
          * any individual span synthesis failed.
        """
        from . import piper_engine as _runtime

        if _runtime.np is None or _runtime.sf is None:
            return None
        try:
            from ..dialogue_splitter import split_into_dialogue_spans
        except Exception:
            return None

        spans = split_into_dialogue_spans(text)
        roles = {span.role for span in spans if span.text.strip()}
        if len(roles) < 2:
            # Pure narration or pure dialogue — single-voice path is fine.
            return None

        temp_dir = Path(tempfile.mkdtemp(prefix="piper_charvoice_"))
        temp_files: List[Path] = []
        try:
            for idx, span in enumerate(spans):
                payload = span.text.strip()
                if not payload:
                    continue
                model = (
                    self.character_model_path
                    if span.role == "character"
                    else self.narrator_model_path
                )
                temp_file = tempfile.NamedTemporaryFile(
                    delete=False,
                    suffix=".wav",
                    dir=temp_dir,
                    prefix=f"piper_role_{span.role}_{idx}_",
                )
                temp_file.close()
                temp_path = Path(temp_file.name)
                temp_files.append(temp_path)
                if pre_segment_callback:
                    with contextlib.suppress(Exception):
                        pre_segment_callback(payload, len(text))
                result = await self._synthesize_single(payload, temp_path, model)
                if result is None:
                    return None
                if progress_callback:
                    with contextlib.suppress(Exception):
                        progress_callback(payload, len(text))
                if chunk_callback:
                    with contextlib.suppress(TypeError):
                        chunk_callback(idx, temp_path, payload)
                    with contextlib.suppress(Exception):
                        chunk_callback(idx, temp_path)

            if not temp_files:
                return None

            audio_chunks: List[_runtime.np.ndarray] = []
            sample_rate: Optional[int] = None
            for path in temp_files:
                data, sr = _runtime.sf.read(str(path))
                if sample_rate is None:
                    sample_rate = sr
                elif sr != sample_rate:
                    data = self._resample_audio(data, sr, sample_rate)
                audio_chunks.append(data)

            if not audio_chunks or sample_rate is None:
                return None

            combined = _runtime.np.concatenate(audio_chunks, axis=0)
            _runtime.sf.write(str(output_path), combined, sample_rate)
        finally:
            for path in temp_files:
                with contextlib.suppress(OSError):
                    path.unlink()
            with contextlib.suppress(OSError):
                shutil.rmtree(temp_dir, ignore_errors=True)

        return output_path if Path(output_path).exists() else None

    async def _synthesize_single(
        self, text: str, output_path: Path, model_path: Path
    ) -> Optional[Path]:
        from . import piper_engine as _runtime

        piper_bin = _runtime._find_piper_binary()
        command = (
            piper_bin,
            "--model",
            str(model_path),
            "--output_file",
            str(output_path),
        )
        max_retries = max(0, int(os.environ.get("PIPER_CHUNK_MAX_RETRIES", "1") or "1"))
        stall_seconds = float(os.environ.get("PIPER_CHUNK_STALL_SECONDS", "45") or "45")
        stall_seconds = max(0.0, stall_seconds)

        # **FIXED**: Use semaphore to limit simultaneous processes
        async with self._semaphore:
            for _attempt in range(max_retries + 1):
                with contextlib.suppress(Exception):
                    output_path.unlink(missing_ok=True)
                try:
                    process = await asyncio.create_subprocess_exec(
                        *command,
                        stdin=asyncio.subprocess.PIPE,
                        stdout=asyncio.subprocess.DEVNULL,
                        stderr=asyncio.subprocess.DEVNULL,
                    )
                    if stall_seconds > 0:
                        ok = await self._communicate_with_stall_watchdog(
                            process=process,
                            payload=text.encode("utf-8"),
                            output_path=output_path,
                            stall_seconds=stall_seconds,
                        )
                        if not ok:
                            continue
                    else:
                        await process.communicate(input=text.encode("utf-8"))
                except Exception:
                    continue

                if process.returncode == 0 and Path(output_path).exists():
                    return output_path

        return None

    async def _communicate_with_stall_watchdog(
        self,
        *,
        process: asyncio.subprocess.Process,
        payload: bytes,
        output_path: Path,
        stall_seconds: float,
    ) -> bool:
        """Abort stuck Piper process when output file stops growing for too long."""
        task = asyncio.create_task(process.communicate(input=payload))
        last_size = -1
        last_growth = time.time()
        try:
            while not task.done():
                await asyncio.sleep(1.0)
                current_size = 0
                with contextlib.suppress(OSError):
                    current_size = int(output_path.stat().st_size)
                if current_size > last_size:
                    last_size = current_size
                    last_growth = time.time()
                    continue
                if (time.time() - last_growth) >= stall_seconds:
                    with contextlib.suppress(Exception):
                        process.kill()
                    with contextlib.suppress(Exception):
                        await process.wait()
                    with contextlib.suppress(Exception):
                        task.cancel()
                    return False
            with contextlib.suppress(Exception):
                await task
        finally:
            if not task.done():
                with contextlib.suppress(Exception):
                    task.cancel()
        return True

    @staticmethod
    def _resample_audio(
        data, current_sr: int, target_sr: int
    ):  # pragma: no cover - depends on numpy availability
        from . import piper_engine as _runtime

        if _runtime.np is None or current_sr == target_sr:
            return data
        ratio = target_sr / current_sr
        indices = _runtime.np.round(_runtime.np.arange(0, len(data), 1 / ratio)).astype(int)
        indices = indices[indices < len(data)]
        return data[indices]
