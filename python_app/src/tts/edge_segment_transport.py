# -*- coding: utf-8 -*-
"""Edge segment transport, streaming and retries."""

from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, Optional


class EdgeSegmentTransport:
    """Own the edge segment transport, streaming and retries."""

    async def _synthesize_segment_core(
        self,
        text: str,
        voice: str,
        output_path: Path,
        *,
        append: bool,
        _metric_state: Optional[Dict[str, Any]] = None,
    ) -> bool:
        # Validate inputs
        from . import edge_engine as _runtime
        if text is None:
            self.last_error = "text_is_none"
            return False

        if voice is None:
            voice = self.voice or "en-US-GuyNeural"

        # **RATE LIMIT CHECK**: Wait if we recently hit a 403
        waited = await _runtime._wait_if_rate_limited()
        if waited and self.verbose:
            self._log("   ⏸️ Aguardou cooldown de rate limit")

        log_callback = self._log if (self.verbose or self.log_callback) else None

        # Use per-instance + global rate limiter to prevent resource contention
        loop = _runtime.asyncio.get_running_loop()
        waiting_start = loop.time()
        if self._global_rate_limiter_loop is not loop:
            self._global_rate_limiter = _runtime._get_global_edge_limiter(loop)
            self._global_rate_limiter_loop = loop
        global_limiter = self._global_rate_limiter
        slots_available = self._rate_limiter._value
        global_slots_available = (
            global_limiter._value
            if global_limiter and global_limiter is not self._rate_limiter
            else None
        )

        if slots_available == 0 or (global_slots_available == 0):
            waiters = getattr(self._rate_limiter, "_waiters", [])
            if global_slots_available == 0 and global_limiter is not None:
                waiters = getattr(global_limiter, "_waiters", waiters)
            waiters_count = len(waiters) if waiters is not None else 0
            if self.verbose:
                self._log(f"   ⏳ Waiting for free slot (queue: {waiters_count})")

        async with _runtime.AsyncExitStack() as stack:
            if global_limiter and global_limiter is not self._rate_limiter:
                await stack.enter_async_context(global_limiter)
            await stack.enter_async_context(self._rate_limiter)
            wait_time = loop.time() - waiting_start
            if _metric_state is not None:
                _metric_state["queue_wait_ms"] = max(0.0, wait_time * 1000.0)
                _metric_state["active_requests"] = max(
                    1, int(self._parallel_slots) - int(self._rate_limiter._value)
                )
            if self.verbose and wait_time > 1:
                self._log(f"   🚀 Slot acquired after {wait_time:.1f}s")

            now = loop.time()
            if now < self._noaudio_backoff_until:
                remaining = int(self._noaudio_backoff_until - now)
                self.last_error = f"service_unavailable (cooldown {remaining}s)"
                if self.verbose:
                    self._log(f"   ⏸️ Cooldown: {remaining}s remaining")
                return False
            try:
                # SSL bypass already applied at the top of the module via monkeypatch
                if _metric_state is not None:
                    _metric_state["request_start"] = loop.time()
                communicator = self._edge_tts.Communicate(text, voice)

            except Exception as exc:  # pragma: no cover - defensive logging
                if _runtime._is_rate_limit_error(exc):
                    self.last_error = f"rate_limit: {exc}" if exc else "rate_limit"
                    await _runtime._handle_rate_limit(log_callback)
                else:
                    self.last_error = (
                        f"{exc.__class__.__name__}: {exc}" if exc else exc.__class__.__name__
                    )
                if self.verbose:
                    self._log(f"   ❌ Error creating Communicate: {self.last_error}")
                return False

            mode = "ab" if append else "wb"
            received_audio = False
            timeout = self._calculate_timeout(text)

            try:
                stream_candidate = communicator.stream()
            except Exception as exc:  # pragma: no cover - defensive logging
                if _runtime._is_rate_limit_error(exc):
                    self.last_error = f"rate_limit: {exc}" if exc else "rate_limit"
                    await _runtime._handle_rate_limit(log_callback)
                else:
                    self.last_error = (
                        f"{exc.__class__.__name__}: {exc}" if exc else exc.__class__.__name__
                    )
                if self.verbose:
                    self._log(f"   ❌ Error obtaining stream: {self.last_error}")
                return False

            try:
                stream = (
                    await stream_candidate
                    if _runtime.inspect.isawaitable(stream_candidate)
                    else stream_candidate
                )
            except _runtime.asyncio.TimeoutError:
                self.last_error = "timeout"
                if self.verbose:
                    self._log("   ⏱️ Timeout ao inicializar stream")
                return False
            except Exception as exc:  # pragma: no cover - defensive logging
                if _runtime._is_rate_limit_error(exc):
                    self.last_error = f"rate_limit: {exc}" if exc else "rate_limit"
                    await _runtime._handle_rate_limit(log_callback)
                else:
                    self.last_error = (
                        f"{exc.__class__.__name__}: {exc}" if exc else exc.__class__.__name__
                    )
                if self.verbose:
                    self._log(f"   ❌ Error initializing stream: {self.last_error}")
                return False

            if not hasattr(stream, "__aiter__"):
                self.last_error = "invalid_stream"
                if self.verbose:
                    self._log("   ❌ Invalid stream (not async)")
                return False
            chunks_received = 0
            write_seconds = 0.0

            async def _consume_stream(out_file) -> None:
                nonlocal received_audio, chunks_received, write_seconds
                try:
                    async for chunk in stream:
                        chunks_received += 1
                        if _metric_state is not None:
                            _metric_state["received_chunks"] = chunks_received
                        if chunk["type"] == "audio":
                            write_started = loop.time()
                            out_file.write(chunk["data"])
                            write_seconds += max(0.0, loop.time() - write_started)
                            received_audio = True
                finally:
                    with _runtime.suppress(Exception):
                        await stream.aclose()

            synthesis_start = _runtime.asyncio.get_event_loop().time()
            max_retries = _runtime.EDGE_STREAM_MAX_RETRIES
            retry_count = 0

            try:
                while retry_count < max_retries:
                    try:
                        heartbeat_task = None
                        if self.verbose:

                            async def _segment_heartbeat() -> None:
                                while True:
                                    await _runtime.asyncio.sleep(10)
                                    elapsed = _runtime.asyncio.get_event_loop().time() - synthesis_start
                                    status = "receiving" if received_audio else "waiting"
                                    self._log(f"   ... {status} ({elapsed:.0f}s)")

                            heartbeat_task = _runtime.asyncio.create_task(_segment_heartbeat())

                        try:
                            with output_path.open(mode) as out_file:
                                await _runtime.asyncio.wait_for(_consume_stream(out_file), timeout=timeout)
                        finally:
                            if heartbeat_task is not None:
                                heartbeat_task.cancel()
                                with _runtime.suppress(_runtime.asyncio.CancelledError):
                                    await heartbeat_task

                        if self.verbose and received_audio:
                            elapsed = _runtime.asyncio.get_event_loop().time() - synthesis_start
                            self._log(
                                f"   ✅ Completed in {elapsed:.1f}s ({chunks_received} chunks)"
                            )

                        break  # Success - exit retry loop

                    except _runtime.asyncio.TimeoutError:
                        synthesis_time = _runtime.asyncio.get_event_loop().time() - synthesis_start
                        self.last_error = "timeout"
                        if self.verbose:
                            self._log(
                                f"   ⏱️ Timeout after {synthesis_time:.1f}s (limit: {timeout}s)"
                            )
                        # Record timeout to network tuner
                        self._record_network_result(
                            success=False,
                            latency=synthesis_time,
                            is_timeout=True,
                            error_msg="timeout",
                        )
                        return False

                    except _runtime.asyncio.CancelledError:
                        synthesis_time = _runtime.asyncio.get_event_loop().time() - synthesis_start
                        self.last_error = "cancelled"
                        if self.verbose:
                            self._log(f"   🚫 Cancelled after {synthesis_time:.1f}s")
                        raise

                    except Exception as exc:
                        synthesis_time = _runtime.asyncio.get_event_loop().time() - synthesis_start
                        exc_text = str(exc or "").lower()

                        if self.verbose:
                            self._log(
                                f"   ⚠️ Exception ({exc.__class__.__name__}) after {synthesis_time:.1f}s: {exc}"
                            )
                        if "clientconnectordnserror" in exc_text or (
                            "nodename nor servname provided" in exc_text
                        ):
                            # DNS outage won't recover with immediate retries; fail fast
                            # so converter can switch engine quickly.
                            self.last_error = f"{exc.__class__.__name__}: {exc}"
                            self._log("   ❌ DNS resolution failure - aborting fast")
                            return False

                        is_rate_limit = _runtime._is_rate_limit_error(exc)
                        is_cert_error = (
                            (
                                _runtime.ClientConnectorCertificateError
                                and isinstance(exc, _runtime.ClientConnectorCertificateError)
                            )
                            or (_runtime.ClientConnectorError and isinstance(exc, _runtime.ClientConnectorError))
                            or ("certificate" in str(exc).lower() or "ssl" in str(exc).lower())
                        )

                        is_no_audio = (
                            "noaudio" in str(exc).lower()
                            or exc.__class__.__name__.lower() == "noaudioreceived"
                        )
                        is_transient = (
                            is_cert_error
                            or is_no_audio
                            or "timeout" in str(exc).lower()
                            or "connection" in str(exc).lower()
                        )

                        # If *nothing* was received (0 chunks), first check if service is reachable.
                        allow_retry = True
                        health_ok = True
                        if is_no_audio and chunks_received == 0 and not received_audio:
                            allow_retry = retry_count < 1  # only one retry for no-audio
                            health_ok = await self._probe_edge_health(voice)

                        if is_rate_limit:
                            self.last_error = f"rate_limit: {exc}" if exc else "rate_limit"
                            self._rate_limit_streak += 1
                            # Record rate limit to network tuner
                            self._record_network_result(
                                success=False,
                                latency=synthesis_time,
                                is_rate_limit=True,
                                error_msg=str(exc),
                            )
                            backoff_time = await _runtime._handle_rate_limit(log_callback)
                            self._parallel_slots = min(self._parallel_slots, _runtime._edge_max_concurrency)
                            if retry_count < max_retries - 1:
                                retry_count += 1
                                if _metric_state is not None:
                                    _metric_state["retry_count"] = retry_count
                                await _runtime.asyncio.sleep(backoff_time)
                                try:
                                    voice = self._rotate_retry_voice(voice)
                                    communicator = self._edge_tts.Communicate(text, voice)
                                    stream_candidate = communicator.stream()
                                    stream = (
                                        await stream_candidate
                                        if _runtime.inspect.isawaitable(stream_candidate)
                                        else stream_candidate
                                    )
                                    chunks_received = 0
                                    received_audio = False
                                    continue
                                except Exception as retry_exc:
                                    self.last_error = f"retry_failed: {retry_exc}"
                                    if self.verbose:
                                        self._log(f"   ❌ Retry failed: {retry_exc}")
                                    return False
                            return False

                        if is_transient and allow_retry and retry_count < max_retries - 1:
                            retry_count += 1
                            if _metric_state is not None:
                                _metric_state["retry_count"] = retry_count
                            backoff_time = 2**retry_count  # 2s, 4s, 8s

                            # Detailed SSL error logging
                            if is_cert_error:
                                self._log(f"   🔒 SSL error: {exc.__class__.__name__}")
                            elif is_no_audio:
                                self._log(
                                    f"   🔇 No audio ({exc.__class__.__name__}); retry {retry_count}/{max_retries - 1} in {backoff_time}s"
                                )
                            else:
                                self._log(
                                    f"   🔄 Transient error ({exc.__class__.__name__}); retry {retry_count}/{max_retries - 1} in {backoff_time}s"
                                )

                            await _runtime.asyncio.sleep(backoff_time)

                            # Recreate communicator and stream for retry
                            try:
                                # SSL bypass already applied at the top of the module via monkeypatch
                                communicator = self._edge_tts.Communicate(text, voice)
                                stream_candidate = communicator.stream()
                                stream = (
                                    await stream_candidate
                                    if _runtime.inspect.isawaitable(stream_candidate)
                                    else stream_candidate
                                )
                                chunks_received = 0
                                received_audio = False
                                continue  # Retry
                            except Exception as retry_exc:
                                self.last_error = f"retry_failed: {retry_exc}"
                                if self.verbose:
                                    self._log(f"   ❌ Retry failed: {retry_exc}")
                                return False
                        else:
                            # Not a cert error or max retries reached
                            self.last_error = (
                                f"{exc.__class__.__name__}: {exc}"
                                if exc
                                else exc.__class__.__name__
                            )
                            if is_no_audio and chunks_received == 0 and not received_audio:
                                if not health_ok:
                                    # Open cooldown to avoid hammering the service when it's not responding with audio.
                                    self._noaudio_backoff_until = (
                                        _runtime.asyncio.get_event_loop().time()
                                        + max(5.0, _runtime.EDGE_NOAUDIO_COOLDOWN_SECONDS)
                                    )
                                    self.last_error = f"service_unavailable (cooldown {int(_runtime.EDGE_NOAUDIO_COOLDOWN_SECONDS)}s)"
                                    if self.verbose:
                                        self._log(
                                            f"   ⛔ Service unavailable - cooldown {int(_runtime.EDGE_NOAUDIO_COOLDOWN_SECONDS)}s"
                                        )
                                else:
                                    # Likely payload issue; do not open global cooldown
                                    self.last_error = "no_audio_payload"
                                    if self.verbose:
                                        self._log("   ⚠️ No audio (likely content issue)")
                            if is_cert_error:
                                self._log("   ❌ Persistent SSL error")
                            return False
            finally:
                with _runtime.suppress(Exception):
                    connector = getattr(communicator, "connector", None)
                    if connector:
                        maybe_close = getattr(connector, "close", None)
                        if callable(maybe_close):
                            result = maybe_close()
                            if _runtime.asyncio.iscoroutine(result):
                                await result

            # Record timing for adaptive tuning
            synthesis_end = _runtime.asyncio.get_event_loop().time()
            segment_duration = synthesis_end - synthesis_start
            text_chars = len(text) if text else 0
            if _metric_state is not None:
                _metric_state["received_chunks"] = chunks_received
                _metric_state["write_ms"] = max(0.0, write_seconds * 1000.0)

            # **EMPTY-SEGMENT GUARD**: Even when the stream reported audio, the
            # file on disk may be empty or a truncated fragment (Edge can flush a
            # single sub-1KB frame then drop the connection). An empty/tiny chunk
            # concatenated into the chapter output produces an undecodable MP3
            # that later fails coverage validation as "0.3% of text". Treat it as
            # a hard segment failure so the caller re-synthesises instead of
            # persisting a corrupt chunk on disk.
            if received_audio:
                try:
                    written_bytes = output_path.stat().st_size if output_path.exists() else 0
                except OSError:
                    written_bytes = 0
                if written_bytes < _runtime._MIN_VALID_CHUNK_BYTES:
                    received_audio = False
                    self.last_error = "empty_audio_written"
                    if self.verbose:
                        self._log(
                            f"   ⚠️ Segment reported audio but wrote only "
                            f"{written_bytes} bytes (<{_runtime._MIN_VALID_CHUNK_BYTES}); treating as failure"
                        )
                    # Never leave a 0-byte/tiny chunk on disk when we own the
                    # file (append=False). In append mode we cannot safely
                    # truncate the caller's accumulating output, so we leave it
                    # and rely on the caller's size guard before concatenation.
                    if not append:
                        with _runtime.suppress(OSError):
                            output_path.unlink(missing_ok=True)

            if received_audio:
                with _runtime.suppress(Exception):
                    await _runtime._record_success()
                self._rate_limit_streak = 0
                # Record successful segment timing for auto-tuning
                self._record_segment_timing(text_chars, segment_duration, success=True)
                # Record success to network tuner for adaptive speed recovery
                self._record_network_result(
                    success=True,
                    latency=segment_duration,
                )
            else:
                if not self.last_error:
                    self.last_error = "no_audio"
                # Record failed segment timing
                self._record_segment_timing(text_chars, segment_duration, success=False)
                # Record failure to network tuner for automatic adjustment
                self._record_network_result(
                    success=False,
                    latency=segment_duration,
                    error_msg="no_audio",
                )
                # Never leave a truncated 0-byte file behind when we own it
                # (append=False). The 'wb' open above truncates output_path even
                # when no audio arrives; a stray 0-byte chunk would be reused by
                # the resume path or corrupt the concatenated chapter.
                if not append:
                    with _runtime.suppress(OSError):
                        if (
                            output_path.exists()
                            and output_path.stat().st_size < _runtime._MIN_VALID_CHUNK_BYTES
                        ):
                            output_path.unlink(missing_ok=True)

            return received_audio
