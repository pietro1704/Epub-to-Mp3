# -*- coding: utf-8 -*-
"""Single-request chapter synthesis orchestration."""

from __future__ import annotations

from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple


class EdgeRequestCoordinator:
    """Own the single-request chapter synthesis orchestration."""

    async def _synthesize_async_impl(
        self,
        text: str,
        output_path: Path,
        formatting_segments=None,
        progress_callback=None,
        chunk_callback=None,
        pre_segment_callback=None,
        resume_chunks_dir: Optional[Path] = None,
    ) -> Optional[Path]:
        from . import edge_engine as _runtime
        if not text:
            return None

        if self.verbose:
            text_preview = text[:150] + "..." if len(text) > 150 else text
            self._log(f"\n📝 EdgeTTS starting synthesis for {output_path.name}")
            self._log(f"   Size: {len(text)} characters")
            self._log(f"   Preview: {text_preview}")

        self.last_error = None
        self.partial_failure_detected = False
        self.last_segment_report = {"expected": 0, "generated": 0, "failed": 0}

        # **INTEGRITY TRACKING**: Initialize synthesis tracker
        from ..synthesis_tracker import SynthesisTracker

        self._synthesis_tracker = SynthesisTracker(chapter_title=output_path.stem)

        # Use formatting segments if available
        payload_text = text or ""

        if _runtime.TextFormattingProcessor:
            formatter = _runtime.TextFormattingProcessor(
                cues_enabled=self.formatting_cues_enabled,
                cue_locale=self.formatting_locale,
            )
            payload_text = formatter.to_audible_text(payload_text, formatting_segments)

        sanitized = self._sanitize_for_edge(payload_text)
        payload_text = sanitized

        if self.verbose and payload_text != text:
            self._log(f"   ⚙️ Text processed (sanitized/formatted): {len(payload_text)} chars")

        force_plain_segments = self._should_force_plain_text(payload_text)
        if force_plain_segments:
            payload_text = self._simplify_segment_text(payload_text, limit_chars=None)

        segments = self._prepare_segments(payload_text)

        if not segments:
            return None

        if self.verbose:
            self._log(f"   📦 Split into {len(segments)} segments")

        output_path = _runtime.Path(output_path)
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
        total_text_chars = None
        if progress_callback:
            total_text_chars = sum(len(text) for _, text in segments_to_process)

        # **RESUME**: Detect pre-existing chunks to resume from
        pre_existing_chunks: Dict[int, _runtime.Path] = {}
        if resume_chunks_dir and resume_chunks_dir.exists():
            for chunk_file in resume_chunks_dir.glob("chunk_*.mp3"):
                try:
                    # Extract segment index from filename: chunk_0000.mp3 -> 0
                    chunk_idx = int(chunk_file.stem.split("_")[1])
                    # Validate chunk file is not empty/corrupt (min 1KB)
                    if chunk_file.stat().st_size >= 1024:
                        pre_existing_chunks[chunk_idx] = chunk_file
                except (ValueError, IndexError, OSError):
                    pass
            if pre_existing_chunks:
                self._log(
                    f"♻️ [RESUME] Found {len(pre_existing_chunks)}/{len(segments_to_process)} "
                    f"segments already processed, resuming from the rest"
                )

        use_chunk_files = bool(chunk_callback) or bool(resume_chunks_dir)

        def _append_chunk_file(chunk_path: Path, first: bool) -> bool:
            # **DEFENSE-IN-DEPTH**: Never append a missing or empty/tiny chunk;
            # a 0-byte fragment produces an undecodable MP3 that fails coverage
            # validation. Report failure so the caller re-synthesises instead of
            # persisting corrupt audio.
            try:
                if (not chunk_path.exists()) or chunk_path.stat().st_size < _runtime._MIN_VALID_CHUNK_BYTES:
                    self.last_error = "empty_chunk_skipped"
                    if self.verbose:
                        size = chunk_path.stat().st_size if chunk_path.exists() else 0
                        self._log(
                            f"❌ Refusing to append empty/tiny chunk {chunk_path.name} ({size} bytes)"
                        )
                    return False
            except OSError:
                return False
            try:
                mode = "wb" if first else "ab"
                with output_path.open(mode) as outfile, chunk_path.open("rb") as infile:
                    while True:
                        block = infile.read(1024 * 1024)
                        if not block:
                            break
                        outfile.write(block)
                return True
            except Exception as exc:
                self.last_error = f"append_failed:{exc}"
                if self.verbose:
                    self._log(f"❌ Failed to append chunk: {exc}")
                return False

        # **PARALLEL OPTIMIZATION**: Process segments in batches when parallel mode is enabled
        if self._enable_parallel and self._rate_limiter and len(segments_to_process) > 1:
            if self.verbose:
                batch_size = self._determine_parallel_batch_size(len(segments_to_process))
                self._log(f"🚀 [VERBOSE] Parallel processing enabled (batch size: {batch_size})")
            return await self._synthesize_parallel(
                output_path,
                segments_to_process,
                force_plain_segments,
                progress_callback=progress_callback,
                chunk_callback=chunk_callback,
                pre_segment_callback=pre_segment_callback,
                pre_existing_chunks=pre_existing_chunks,
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

                if pre_segment_callback:
                    with _runtime.suppress(Exception):
                        pre_segment_callback(segment_text, total_text_chars or len(segment_text))

                if use_chunk_files:
                    existing_chunk = pre_existing_chunks.get(idx)
                    if existing_chunk and existing_chunk.exists():
                        if self.verbose:
                            self._log(f"♻️ [RESUME] Segment {idx + 1} already exists, appending")
                        if not _append_chunk_file(existing_chunk, total_segments == 0):
                            return None
                        if chunk_callback:
                            try:
                                chunk_callback(idx, existing_chunk, segment_text)
                            except TypeError:
                                try:
                                    chunk_callback(idx, existing_chunk)
                                except Exception:
                                    pass
                        if progress_callback:
                            progress_callback(segment_text, total_text_chars or 0)
                        total_segments += 1
                        idx += 1
                        continue

                if self.verbose:
                    text_preview = (
                        segment_text[:200] + "..." if len(segment_text) > 200 else segment_text
                    )
                    self._log(
                        f"\n🎙️ Segment {idx + 1}/{len(segments_to_process)} ({len(segment_text)} chars, voice: {voice})"
                    )
                    self._log(f"   Text: {text_preview}")

                # **CRITICAL FIX**: Try to process segment with retries
                segment_output_path = output_path
                temp_segment_path: Optional[_runtime.Path] = None
                if use_chunk_files:
                    if resume_chunks_dir:
                        segment_output_path = _runtime.Path(resume_chunks_dir) / f"chunk_{idx:04d}.mp3"
                    else:
                        import tempfile

                        temp_file = tempfile.NamedTemporaryFile(
                            delete=False, suffix=".mp3", dir=output_path.parent
                        )
                        temp_file.close()
                        temp_segment_path = _runtime.Path(temp_file.name)
                        segment_output_path = temp_segment_path

                success = await self._synthesize_segment(
                    segment_text,
                    voice,
                    segment_output_path,
                    append=False if use_chunk_files else (total_segments > 0),
                )

                if use_chunk_files and not success:
                    with _runtime.suppress(OSError):
                        if segment_output_path != output_path:
                            segment_output_path.unlink(missing_ok=True)

                if not success:
                    # If the Edge service is returning *no audio at all*, splitting/cleaning won't help.
                    # Fail fast so the converter can move on instead of spending minutes in retries.
                    if (
                        idx == 0
                        and self.last_error
                        and (
                            "noaudioreceived" in self.last_error.lower()
                            or "service_unavailable" in self.last_error.lower()
                            or "no_audio" == self.last_error.lower()
                        )
                    ):
                        if self.verbose:
                            self._log(f"   ⛔ Abortando: {self.last_error}")
                        return None

                    retry_segments = self._split_failed_segment(
                        voice, segment_text, segment_split_attempts
                    )
                    if retry_segments:
                        if self.verbose:
                            self._log(
                                f"   ⚠️ Failed, splitting into {len(retry_segments)} sub-segments..."
                            )
                        segments_to_process[idx : idx + 1] = retry_segments
                        continue

                    simplified_text = self._simplify_segment_text(segment_text)
                    if simplified_text and simplified_text != segment_text:
                        if self.verbose:
                            self._log("   ⚠️ Retrying with simplified text...")
                        success = await self._synthesize_segment(
                            simplified_text,
                            voice,
                            segment_output_path if use_chunk_files else output_path,
                            append=False if use_chunk_files else (total_segments > 0),
                        )
                        if success:
                            if use_chunk_files:
                                if chunk_callback:
                                    try:
                                        chunk_callback(idx, segment_output_path, simplified_text)
                                    except TypeError:
                                        try:
                                            chunk_callback(idx, segment_output_path)
                                        except Exception:
                                            pass
                                if not _append_chunk_file(segment_output_path, total_segments == 0):
                                    return None
                                if temp_segment_path is not None:
                                    with _runtime.suppress(OSError):
                                        temp_segment_path.unlink(missing_ok=True)
                            if self.verbose:
                                self._log("   ✅ Success with simplified text")
                            force_plain_segments = True
                            if progress_callback:
                                progress_callback(simplified_text, total_text_chars or 0)
                            total_segments += 1
                            idx += 1
                            continue
                        if use_chunk_files and not success:
                            with _runtime.suppress(OSError):
                                if segment_output_path != output_path:
                                    segment_output_path.unlink(missing_ok=True)

                    failed_segments += 1
                    if self.verbose:
                        self._log(f"   ❌ FAILED: {self.last_error}")

                    # Retry with shorter exponential backoff.
                    if failed_segments <= _runtime.EDGE_SEGMENT_MAX_RETRIES:
                        backoff = min(1.0 * (2 ** (failed_segments - 1)), 3.0)
                        if self.verbose:
                            self._log(f"   🔄 Retrying after {backoff}s...")
                        await _runtime.asyncio.sleep(backoff)

                        success = await self._synthesize_segment(
                            segment_text,
                            voice,
                            segment_output_path if use_chunk_files else output_path,
                            append=False if use_chunk_files else (total_segments > 0),
                        )

                        if use_chunk_files and not success:
                            with _runtime.suppress(OSError):
                                if segment_output_path != output_path:
                                    segment_output_path.unlink(missing_ok=True)

                        if success:
                            if self.verbose:
                                self._log("   ✅ Success on retry")
                            failed_segments = max(0, failed_segments - 1)

                    # Fail if too many consecutive segments failed
                    if failed_segments > _runtime.EDGE_SEGMENT_MAX_RETRIES:
                        last_error_text = (self.last_error or "").lower()
                        is_network_like = any(
                            token in last_error_text
                            for token in (
                                "ssl",
                                "clientconnector",
                                "connection",
                                "dns",
                                "timeout",
                                "network",
                            )
                        )
                        # DNS failures rarely recover quickly; abort immediately and let
                        # converter fallback to local engine.
                        if "clientconnectordnserror" in last_error_text and failed_segments >= 1:
                            self._log("❌ Edge TTS: DNS failure detected, aborting fast")
                            raise RuntimeError("edge_network_abort")
                        if is_network_like and failed_segments >= _runtime.EDGE_NETWORK_ABORT_AFTER_FAILS:
                            self._log(
                                f"❌ Edge TTS: consecutive network/SSL failures ({failed_segments}), aborting"
                            )
                            raise RuntimeError("edge_network_abort")
                        micro_segments = self._force_micro_segments(
                            voice, segment_text, micro_split_tracker
                        )
                        if micro_segments:
                            if self.verbose:
                                self._log(
                                    f"   ⚡ Forcing split into {len(micro_segments)} micro-segments"
                                )
                            segments_to_process[idx : idx + 1] = micro_segments
                            force_plain_segments = True
                            failed_segments = 0
                            continue
                        self._log(
                            f"❌ Edge TTS: too many consecutive failures ({failed_segments}), aborting"
                        )
                        return None

                    idx += 1
                    continue

                if use_chunk_files:
                    if chunk_callback:
                        try:
                            chunk_callback(idx, segment_output_path, segment_text)
                        except TypeError:
                            try:
                                chunk_callback(idx, segment_output_path)
                            except Exception:
                                pass
                    if not _append_chunk_file(segment_output_path, total_segments == 0):
                        return None
                    if temp_segment_path is not None:
                        with _runtime.suppress(OSError):
                            temp_segment_path.unlink(missing_ok=True)

                # Success!
                total_segments += 1
                if progress_callback:
                    progress_callback(segment_text, total_text_chars or 0)
                idx += 1
        except _runtime.asyncio.TimeoutError:
            self.last_error = "timeout"
            return None
        except Exception as exc:  # pragma: no cover - defensive logging
            self.last_error = f"{exc.__class__.__name__}: {exc}" if exc else exc.__class__.__name__
            return None

        if total_segments == 0 or not output_path.exists():
            self.last_error = "no_audio"
            return None

        # **EMPTY-OUTPUT GUARD**: A non-zero segment count but an empty/tiny
        # concatenated file means every appended chunk was corrupt. Fail clean
        # instead of returning a 0s MP3 that passes as "success".
        with _runtime.suppress(OSError):
            if output_path.stat().st_size < _runtime._MIN_VALID_CHUNK_BYTES:
                self.partial_failure_detected = True
                self.last_error = "empty_output_all_segments"
                output_path.unlink(missing_ok=True)
                return None

        expected_segments = total_segments + failed_segments
        self.last_segment_report = {
            "expected": expected_segments,
            "generated": total_segments,
            "failed": failed_segments,
        }

        # **FIXED**: Accept audio only if at least 95% of segments were generated successfully
        success_rate = total_segments / max(expected_segments, 1)

        if success_rate < 0.95:
            # Less than 95% of segments -> critical failure
            self.partial_failure_detected = True

            # Adaptive: reduce chunk size for next attempt
            new_chunk = _runtime._reduce_chunk_size(self._log if self.verbose else None)
            self._chunk_char_limit = new_chunk

            if failed_segments > 0:
                self._log(f"⚠️ Edge TTS: {failed_segments} segment(s) failed during synthesis")
                self._log(
                    f"   Processed: {total_segments}/{expected_segments} segments ({success_rate * 100:.0f}%)"
                )
                if self.verbose:
                    self._log("   Use --verbose for more details about failed segments")
            else:
                self._log(
                    f"⚠️ Edge TTS: only {total_segments}/{expected_segments} segments were generated (incomplete output)"
                )
            self.last_error = f"incomplete_segments:{total_segments}/{expected_segments}"
            with _runtime.suppress(OSError):
                output_path.unlink(missing_ok=True)
            return None
        elif failed_segments > 0 and success_rate < 1.0:
            # Between 95-100% of segments -> warn but accept the audio
            self._log(
                f"⚠️ Edge TTS: {failed_segments} segment(s) failed, but {success_rate * 100:.1f}% was generated successfully"
            )
            if self.verbose:
                self._log(f"   Processed: {total_segments}/{expected_segments} segments")

        return output_path
