# -*- coding: utf-8 -*-
"""Bounded scheduling and merge of parallel Edge segments."""

from __future__ import annotations

from pathlib import Path
from typing import Dict, List, Optional, Tuple


class EdgeParallelSynthesis:
    """Own the bounded scheduling and merge of parallel Edge segments."""

    async def _synthesize_parallel(
        self,
        output_path: Path,
        segments_to_process: List[Tuple[str, str]],
        force_plain_segments: bool,
        progress_callback=None,
        chunk_callback=None,
        pre_segment_callback=None,
        pre_existing_chunks: Optional[Dict[int, Path]] = None,
    ) -> Optional[Path]:
        """Process segments in parallel batches for faster synthesis."""
        from . import edge_engine as _runtime
        import tempfile
        from pathlib import Path

        total_segments = len(segments_to_process)
        batch_size = self._determine_parallel_batch_size(total_segments)
        successful_segments = 0
        total_text_chars = sum(len(text) for _, text in segments_to_process)
        # Use dict to maintain segment order
        segment_files: Dict[int, Optional[Path]] = {i: None for i in range(total_segments)}
        next_stream_index = 0

        def _emit_ready_stream_chunks() -> None:
            """Expose only the contiguous ready prefix so streaming stays sequential."""
            nonlocal next_stream_index
            if not chunk_callback:
                return
            while next_stream_index < total_segments:
                ready_path = segment_files.get(next_stream_index)
                if ready_path is None or not ready_path.exists():
                    break
                try:
                    _, seg_text = segments_to_process[next_stream_index]
                    chunk_callback(next_stream_index, ready_path, seg_text)
                except TypeError:
                    try:
                        chunk_callback(next_stream_index, ready_path)
                    except Exception as e:
                        if self.verbose:
                            self._log(f"⚠️ Chunk callback error: {e}")
                except Exception as e:
                    if self.verbose:
                        self._log(f"⚠️ Chunk callback error: {e}")
                next_stream_index += 1

        async def _retry_failed_segments(failed_indices: List[int], *, reason: str) -> None:
            nonlocal successful_segments
            if not failed_indices:
                return
            if self.verbose:
                self._log(
                    f"🔄 [PARALLEL] Retrying {len(failed_indices)} failed segment(s) sequentially"
                    f" ({reason})..."
                )

            for fail_idx in failed_indices:
                if segment_files.get(fail_idx) is not None:
                    continue
                voice, segment_text = segments_to_process[fail_idx]
                if not segment_text or not segment_text.strip():
                    continue

                if force_plain_segments or self._should_force_plain_text(segment_text):
                    simplified = self._simplify_segment_text(segment_text, limit_chars=None)
                    if simplified:
                        segment_text = simplified

                temp_file = tempfile.NamedTemporaryFile(
                    delete=False, suffix=".mp3", dir=output_path.parent
                )
                temp_file.close()
                retry_path = Path(temp_file.name)

                try:
                    if pre_segment_callback:
                        with _runtime.suppress(Exception):
                            pre_segment_callback(
                                segment_text, total_text_chars or len(segment_text)
                            )
                    success = await self._synthesize_segment(
                        segment_text,
                        voice or self.voice,
                        retry_path,
                        append=False,
                    )

                    # Recovery: when the segment still won't synthesise
                    # (typically `no_audio_payload` for a deterministic-bad
                    # text/voice combo), try cleanup + sub-division before
                    # giving up. Avoids a single hostile sentence killing
                    # an otherwise complete chapter — the documented
                    # 2026-04-29 Carl, Capítulo 40/47 case.
                    if not success or not retry_path.exists():
                        last_err = str(self.last_error or "")
                        if "no_audio" in last_err or "service_unavailable" in last_err:
                            recovered = await self._recover_failed_segment(
                                segment_text,
                                voice or self.voice,
                                retry_path,
                            )
                            if recovered:
                                success = True

                    if success and retry_path.exists():
                        successful_segments += 1
                        segment_files[fail_idx] = retry_path

                        if self._synthesis_tracker:
                            try:
                                duration = self._measure_segment_validation(retry_path, fail_idx)
                                self._synthesis_tracker.record_segment(
                                    index=fail_idx,
                                    text=segment_text,
                                    audio_path=retry_path,
                                    duration=duration,
                                    status="success",
                                )
                            except Exception:
                                pass

                        _emit_ready_stream_chunks()

                        if progress_callback:
                            try:
                                progress_callback(segment_text, total_text_chars)
                            except Exception as e:
                                if self.verbose:
                                    self._log(f"⚠️ Progress callback error: {e}")
                        if self.verbose:
                            self._log(f"✅ [PARALLEL] Segment {fail_idx + 1} recovered in retry")
                    else:
                        with _runtime.suppress(OSError):
                            retry_path.unlink()
                except Exception as exc:
                    if self._synthesis_tracker:
                        try:
                            error_msg = f"Retry failed: {str(exc)[:150]}"
                            self._synthesis_tracker.record_segment(
                                index=fail_idx, text=segment_text, status="failed", error=error_msg
                            )
                        except Exception:
                            pass

                    if self.verbose:
                        self._log(f"⚠️ [PARALLEL] Retry segment {fail_idx + 1} failed: {exc}")
                    with _runtime.suppress(OSError):
                        retry_path.unlink()

        # **RESUME**: Pre-populate with existing chunks
        if pre_existing_chunks:
            for idx, existing_path in pre_existing_chunks.items():
                if 0 <= idx < total_segments and existing_path.exists():
                    segment_files[idx] = existing_path
                    successful_segments += 1
            _emit_ready_stream_chunks()

        # **OPTIMIZED**: Process in fixed batches to avoid semaphore queue explosion
        # asyncio.gather respects rate limiter naturally without creating excessive queue
        completed_count = 0

        if self.verbose:
            resumed_count = len(pre_existing_chunks) if pre_existing_chunks else 0
            remaining = total_segments - resumed_count
            if resumed_count > 0:
                self._log(
                    f"🚀 [PARALLEL] Processing {remaining} remaining segments "
                    f"(♻️ {resumed_count} already done) in batches of {batch_size}"
                )
            else:
                self._log(
                    f"🚀 [PARALLEL] Processing {total_segments} segments in batches of {batch_size}"
                )

        # Process segments in fixed batches
        for batch_idx, batch_start in enumerate(range(0, total_segments, batch_size)):
            # Inter-batch delay to avoid rate limits (configurable via EDGE_BATCH_DELAY_MS)
            if batch_idx > 0 and _runtime._edge_batch_delay > 0:
                await _runtime.asyncio.sleep(_runtime._edge_batch_delay)

            batch_end = min(batch_start + batch_size, total_segments)
            batch_segments = segments_to_process[batch_start:batch_end]

            tasks = []
            task_metadata: List[Tuple[int, Path]] = []  # (segment_idx, temp_path)

            for i, (voice, segment_text) in enumerate(batch_segments, start=batch_start):
                # **RESUME**: Skip segments that already have files
                if segment_files.get(i) is not None:
                    completed_count += 1
                    if self.verbose:
                        self._log(f"♻️ [RESUME] Segment {i + 1} already exists, skipping")
                    # **INTEGRITY TRACKING**: Mark resumed segment as success
                    if self._synthesis_tracker:
                        try:
                            duration = self._measure_segment_validation(segment_files[i], i)
                            _, seg_text = segments_to_process[i]
                            self._synthesis_tracker.record_segment(
                                index=i,
                                text=seg_text,
                                audio_path=segment_files[i],
                                duration=duration,
                                status="success",
                            )
                        except Exception:
                            pass  # Non-critical
                    continue

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

                if pre_segment_callback:
                    with _runtime.suppress(Exception):
                        pre_segment_callback(segment_text, total_text_chars or len(segment_text))

                # **INTEGRITY TRACKING**: Record segment as pending before synthesis
                if self._synthesis_tracker:
                    try:
                        self._synthesis_tracker.record_segment(
                            index=i, text=segment_text, status="pending"
                        )
                    except Exception:
                        pass  # Non-critical

                # Create temp file
                temp_file = tempfile.NamedTemporaryFile(
                    delete=False, suffix=".mp3", dir=output_path.parent
                )
                temp_file.close()
                temp_path = Path(temp_file.name)

                # Add synthesis task
                task = self._synthesize_segment(segment_text, voice, temp_path, append=False)
                tasks.append(task)
                task_metadata.append((i, temp_path))

            # Process batch - gather respects rate limiter without queueing
            try:
                results = await _runtime.asyncio.gather(*tasks, return_exceptions=True)
            except (_runtime.asyncio.CancelledError, Exception):
                # Clean up temp files created for this batch before re-raising
                for _, tmp_path in task_metadata:
                    if tmp_path not in segment_files.values():
                        with _runtime.suppress(OSError):
                            tmp_path.unlink(missing_ok=True)
                raise

            # Process results
            for (segment_idx, temp_file), result in zip(task_metadata, results):
                segment_num = segment_idx + 1
                completed_count += 1

                try:
                    if isinstance(result, Exception):
                        raise result

                    if result:  # Success
                        successful_segments += 1
                        segment_files[segment_idx] = temp_file

                        # **INTEGRITY TRACKING**: Record successful segment
                        if self._synthesis_tracker:
                            try:
                                duration = self._measure_segment_validation(temp_file, segment_idx)
                                _, seg_text = segments_to_process[segment_idx]
                                self._synthesis_tracker.record_segment(
                                    index=segment_idx,
                                    text=seg_text,
                                    audio_path=temp_file,
                                    duration=duration,
                                    status="success",
                                )
                            except Exception:
                                pass  # Non-critical

                        _emit_ready_stream_chunks()

                        # **NOVO**: Report progress to callback
                        if progress_callback:
                            try:
                                if segment_idx < len(segments_to_process):
                                    _, segment_text = segments_to_process[segment_idx]
                                    progress_callback(segment_text, total_text_chars)
                            except Exception as e:
                                if self.verbose:
                                    self._log(f"⚠️ Progress callback error: {e}")

                        if self.verbose:
                            file_size = temp_file.stat().st_size if temp_file.exists() else 0
                            self._log(
                                f"✅ [PARALLEL] Segment {segment_num} OK ({file_size} bytes, {completed_count}/{total_segments})"
                            )
                    else:
                        # **INTEGRITY TRACKING**: Record failed segment
                        if self._synthesis_tracker:
                            try:
                                _, seg_text = segments_to_process[segment_idx]
                                self._synthesis_tracker.record_segment(
                                    index=segment_idx,
                                    text=seg_text,
                                    status="failed",
                                    error="No audio generated",
                                )
                            except Exception:
                                pass  # Non-critical

                        if self.verbose:
                            self._log(f"⚠️ [PARALLEL] Segment {segment_num} failed (no audio)")
                        with _runtime.suppress(OSError):
                            temp_file.unlink()

                except Exception as exc:
                    # **INTEGRITY TRACKING**: Record exception
                    if self._synthesis_tracker:
                        try:
                            _, seg_text = segments_to_process[segment_idx]
                            error_msg = str(exc)[:200]
                            self._synthesis_tracker.record_segment(
                                index=segment_idx, text=seg_text, status="failed", error=error_msg
                            )
                        except Exception:
                            pass  # Non-critical

                    if self.verbose:
                        error_msg = str(exc)[:100]
                        self._log(f"⚠️ [PARALLEL] Segment {segment_num} failed: {error_msg}")
                    with _runtime.suppress(OSError):
                        temp_file.unlink()

            priority_retry_indices: list[int] = []
            probe = next_stream_index
            while probe < batch_end:
                if segment_files.get(probe) is not None:
                    break
                priority_retry_indices.append(probe)
                probe += 1
            await _retry_failed_segments(priority_retry_indices, reason="streaming priority")

        # Retry failed segments sequentially (anti-starving measure)
        failed_indices = [i for i, path in segment_files.items() if path is None]
        if failed_indices and successful_segments >= total_segments * 0.8:
            await _retry_failed_segments(failed_indices, reason="final recovery")

        # Collect successful segments in order
        temp_files = [path for path in segment_files.values() if path is not None]

        if not temp_files:
            self.last_error = "no_audio_generated_parallel"
            return None

        if self.verbose:
            self._log(f"🔗 [PARALLEL] Concatenating {len(temp_files)} successful segment(s)...")

        try:
            # **OPTIMIZED**: Buffered chunked I/O to reduce memory pressure
            CHUNK_SIZE = 1024 * 1024  # 1MB chunks
            concatenated_segments = 0
            with output_path.open("wb") as outfile:
                for temp_file in temp_files:
                    # **DEFENSE-IN-DEPTH**: Skip missing or empty/tiny fragments
                    # so a single corrupt segment never poisons the whole MP3.
                    try:
                        seg_size = temp_file.stat().st_size if temp_file.exists() else 0
                    except OSError:
                        seg_size = 0
                    if seg_size < _runtime._MIN_VALID_CHUNK_BYTES:
                        if self.verbose:
                            self._log(
                                f"⚠️ [PARALLEL] Skipping empty/tiny segment "
                                f"{temp_file.name} ({seg_size} bytes)"
                            )
                        successful_segments = max(0, successful_segments - 1)
                        with _runtime.suppress(OSError):
                            temp_file.unlink()
                        continue
                    with temp_file.open("rb") as infile:
                        while True:
                            chunk = infile.read(CHUNK_SIZE)
                            if not chunk:
                                break
                            outfile.write(chunk)
                    concatenated_segments += 1
                    # Clean up temp file
                    with _runtime.suppress(OSError):
                        temp_file.unlink()
        except Exception as exc:
            self.last_error = f"concatenation_failed: {exc}"
            if self.verbose:
                self._log(f"❌ [PARALLEL] Error concatenating segments: {exc}")
            # Clean up remaining temp files
            for temp_file in temp_files:
                with _runtime.suppress(OSError):
                    temp_file.unlink()
            return None

        # **EMPTY-OUTPUT GUARD**: If every segment was skipped as empty/tiny the
        # output file is 0 bytes — fail clean instead of returning a corrupt MP3
        # that only gets caught by late coverage validation.
        if concatenated_segments == 0 or (
            output_path.exists() and output_path.stat().st_size < _runtime._MIN_VALID_CHUNK_BYTES
        ):
            self.partial_failure_detected = True
            self.last_error = "no_audio_generated_parallel"
            with _runtime.suppress(OSError):
                output_path.unlink(missing_ok=True)
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

            # Adaptive: reduce chunk size for next attempt
            new_chunk = _runtime._reduce_chunk_size(self._log if self.verbose else None)
            self._chunk_char_limit = new_chunk

            self._log(
                f"⚠️ Edge TTS parallel: only {successful_segments}/{total_segments} segments succeeded ({success_rate * 100:.1f}%)"
            )
            self.last_error = f"incomplete_segments:{successful_segments}/{total_segments}"
            with _runtime.suppress(OSError):
                output_path.unlink()
            return None

        if self.verbose:
            self._log(
                f"✅ [PARALLEL] Synthesis complete: {successful_segments}/{total_segments} segments ({success_rate * 100:.1f}%)"
            )

        return output_path
