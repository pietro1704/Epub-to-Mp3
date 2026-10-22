"""Bound parallel Piper chunks and concatenate isolated WAV artifacts."""

from __future__ import annotations

import asyncio
import contextlib
import shutil
import tempfile
from pathlib import Path
from typing import Dict, List, Optional


class PiperChunkSynthesis:
    async def _synthesize_chunked(
        self,
        text: str,
        output_path: Path,
        model_path: Path,
        progress_callback=None,
        chunk_callback=None,
        pre_segment_callback=None,
    ) -> Optional[Path]:
        """Synthesize text with parallel chunking for large inputs.

        Splits text into chunks of ~PIPER_CHUNK_CHARS, synthesizes them in
        parallel (bounded by semaphore), and concatenates WAV outputs.
        For short texts, falls back to single-shot synthesis.
        """
        from . import piper_engine as _runtime

        max_chunk_chars = _runtime._planned_piper_chunk_chars(text, self._effective_chunk_chars())
        chunks = _runtime._split_text_into_chunks(text, max_chunk_chars)
        chunks = _runtime._merge_small_chunks(
            chunks,
            max_chunk_chars,
            min_chars=max(1400, int(max_chunk_chars * 0.55)),
        )

        # Short text: single shot (no overhead)
        if len(chunks) <= 1:
            if pre_segment_callback:
                with contextlib.suppress(Exception):
                    pre_segment_callback(text, len(text))
            return await self._synthesize_single(text, output_path, model_path)

        # Need ffmpeg for concatenation
        if not shutil.which("ffmpeg"):
            # Fallback: single shot
            return await self._synthesize_single(text, output_path, model_path)

        # Use a per-synthesis isolated temp dir so parallel chapters don't
        # share piper_chunk files and trigger cross-contamination.
        temp_dir = Path(tempfile.mkdtemp(prefix="piper_synth_"))
        temp_files: List[Path] = []
        try:
            for idx in range(len(chunks)):
                tf = tempfile.NamedTemporaryFile(
                    delete=False,
                    suffix=".wav",
                    dir=temp_dir,
                    prefix=f"piper_chunk{idx:03d}_",
                )
                tf.close()
                temp_files.append(Path(tf.name))

            # Synthesize all chunks in parallel (semaphore limits concurrency)
            tasks: Dict[int, asyncio.Task[Optional[Path]]] = {}
            for idx, (chunk_text, temp_path) in enumerate(zip(chunks, temp_files)):
                if pre_segment_callback:
                    with contextlib.suppress(Exception):
                        pre_segment_callback(chunk_text, len(text))
                tasks[idx] = asyncio.create_task(
                    self._synthesize_single(chunk_text, temp_path, model_path)
                )

            task_results: Dict[int, Optional[Path]] = {}
            if tasks:
                gathered = await asyncio.gather(*tasks.values())
                task_results = {
                    chunk_idx: result for chunk_idx, result in zip(tasks.keys(), gathered)
                }

            # Check all succeeded
            for idx, file_path in enumerate(temp_files):
                result = task_results.get(idx)
                if result is None:
                    return None
                if not file_path.exists():
                    return None
                with contextlib.suppress(OSError):
                    if file_path.stat().st_size <= 0:
                        return None
                if progress_callback:
                    try:
                        progress_callback(chunks[idx], len(text))
                    except Exception:
                        pass
                if chunk_callback:
                    try:
                        chunk_callback(idx, temp_files[idx], chunks[idx])
                    except (TypeError, Exception):
                        pass

            # Concatenate WAV files using ffmpeg
            concat_list = tempfile.NamedTemporaryFile(
                delete=False,
                suffix=".txt",
                dir=temp_dir,
                prefix="piper_concat_",
            )
            try:
                for tf in temp_files:
                    concat_list.write(f"file '{tf}'\n".encode("utf-8"))
                concat_list.close()

                wav_out = output_path.with_suffix(".wav")
                ffmpeg_proc = await asyncio.create_subprocess_exec(
                    "ffmpeg",
                    "-y",
                    "-f",
                    "concat",
                    "-safe",
                    "0",
                    "-i",
                    str(concat_list.name),
                    "-c",
                    "copy",
                    str(wav_out),
                    stdout=asyncio.subprocess.DEVNULL,
                    stderr=asyncio.subprocess.DEVNULL,
                )
                try:
                    await asyncio.wait_for(ffmpeg_proc.wait(), timeout=120.0)
                except asyncio.TimeoutError:
                    ffmpeg_proc.kill()
                    with contextlib.suppress(Exception):
                        await ffmpeg_proc.wait()
                    return None
                if ffmpeg_proc.returncode != 0 or not wav_out.exists():
                    return None

                # If output_path expects wav, we're done
                if output_path.suffix.lower() == ".wav":
                    if wav_out != output_path:
                        wav_out.rename(output_path)
                    return output_path if output_path.exists() else None

                # Otherwise move wav to the expected output
                wav_out.rename(output_path)
                return output_path if output_path.exists() else None
            finally:
                Path(concat_list.name).unlink(missing_ok=True)
        finally:
            for tf in temp_files:
                with contextlib.suppress(OSError):
                    tf.unlink()
            with contextlib.suppress(OSError):
                shutil.rmtree(temp_dir, ignore_errors=True)
