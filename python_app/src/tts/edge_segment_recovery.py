# -*- coding: utf-8 -*-
"""Failed-segment recovery and bounded request capacity."""

from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, List, Set, Tuple
from typing import Optional as Optional


class EdgeSegmentRecovery:
    """Own the failed-segment recovery and bounded request capacity."""

    def _segment_signature(self, voice: str, text: str) -> str:
        preview = (text or "").strip()
        return f"{voice}:{len(preview)}:{hash(preview[:160])}"

    def _split_failed_segment(
        self,
        voice: str,
        text: str,
        attempts: Dict[str, int],
    ) -> List[Tuple[str, str]] | None:
        """Try to split a problematic segment into smaller pieces for retry."""
        from . import edge_engine as _runtime
        if not text or len(text) < _runtime.MIN_SEGMENT_RETRY_CHARS:
            return None

        signature = self._segment_signature(voice, text)
        attempt = attempts.get(signature, 0)
        if attempt >= _runtime.MAX_SEGMENT_SPLIT_ATTEMPTS:
            return None

        divisor = 2 + attempt
        chunk_size = max(int(len(text) / divisor), _runtime.MIN_SEGMENT_RETRY_CHARS // 2)
        smaller_segments = self._chunk_text(voice, text, chunk_size=chunk_size)
        smaller_segments = [
            (seg_voice, seg_text)
            for seg_voice, seg_text in smaller_segments
            if seg_text and seg_text.strip()
        ]

        if len(smaller_segments) <= 1:
            return None

        attempts[signature] = attempt + 1
        return smaller_segments

    def _force_micro_segments(
        self,
        voice: str,
        text: str,
        tracker: Set[str],
    ) -> List[Tuple[str, str]] | None:
        """Force text into very small segments to salvage stubborn payloads."""
        if not text:
            return None

        signature = f"micro:{self._segment_signature(voice, text)}"
        if signature in tracker:
            return None

        tracker.add(signature)

        cleaned = text.strip()
        if not cleaned:
            return None

        max_seconds = min(self._max_segment_seconds * 0.5, 20.0)
        micro_chunks = self._split_text_by_duration(cleaned, max_seconds)

        if not micro_chunks:
            # Fall back to fixed-size word groups (~80 words ≈ 30s)
            words = [word for word in cleaned.split() if word]
            if not words:
                return None

            chunk_words = max(min(len(words) // 4, 80), 20)
            micro_chunks = []
            for start in range(0, len(words), chunk_words):
                segment_words = words[start : start + chunk_words]
                if segment_words:
                    micro_chunks.append(" ".join(segment_words))

        micro_chunks = [chunk.strip() for chunk in micro_chunks if chunk and chunk.strip()]
        if not micro_chunks:
            return None

        return [(voice, chunk) for chunk in micro_chunks]


    def _should_force_plain_text(self, text: str) -> bool:
        """Heuristic: detect heavy markup that often breaks Edge SSML."""
        if not text:
            return False
        stripped = text.strip()
        if len(stripped) < 400:
            return False

        fmt_markers = stripped.count("[[fmt:")
        lang_markers = stripped.lower().count("[[lang:")
        bold_markers = stripped.count("**")
        italic_markers = stripped.count("_")

        high_markup = fmt_markers + lang_markers >= 20
        dense_markup = (fmt_markers + lang_markers) >= 8 and len(stripped) / max(
            fmt_markers + lang_markers, 1
        ) < 200
        heavy_markdown = bold_markers >= 10 or italic_markers >= 30
        very_long = len(stripped) > 12000 and (fmt_markers + lang_markers) >= 5

        return high_markup or dense_markup or heavy_markdown or very_long

    def _resolve_parallel_capacity(self) -> int:
        """Return desired parallelism while clamping to a safe minimum."""
        from . import edge_engine as _runtime
        slots = self._parallel_slots if self._enable_parallel else 1
        if slots <= 0:
            slots = 1
        slots = min(slots, max(1, _runtime._edge_max_concurrency))
        return max(1, slots)

    def _determine_parallel_batch_size(self, total_segments: int) -> int:
        """Decide how many segments to launch per batch without hitting zero-step ranges."""
        capacity = self._resolve_parallel_capacity()
        total = max(1, total_segments)
        return max(1, min(capacity, total))

    async def _synthesize_segment(
        self,
        text: str,
        voice: str,
        output_path: Path,
        *,
        append: bool,
    ) -> bool:
        """Synthesize one segment and emit one failure-safe lifecycle metric."""
        from . import edge_engine as _runtime
        started = _runtime.asyncio.get_running_loop().time()
        metric_state: Dict[str, Any] = {
            "queue_wait_ms": 0.0,
            "request_start": started,
            "request_end": started,
            "retry_count": 0,
            "received_chunks": 0,
            "write_ms": 0.0,
            "active_requests": 0,
        }
        result = False
        cancelled = False
        error_text = ""
        try:
            result = await self._synthesize_segment_core(
                text,
                voice,
                output_path,
                append=append,
                _metric_state=metric_state,
            )
            return result
        except _runtime.asyncio.CancelledError:
            cancelled = True
            error_text = "cancelled"
            raise
        except Exception as exc:
            error_text = str(exc or exc.__class__.__name__)
            raise
        finally:
            finished = _runtime.asyncio.get_running_loop().time()
            metric_state["request_end"] = finished
            error_text = error_text or str(self.last_error or "")
            if cancelled:
                status = "cancelled"
                error_category = "cancelled"
            elif result:
                status = "success"
                error_category = ""
            else:
                status = "failed"
                error_category = _runtime.classify_error(error_text)
            request_start = float(metric_state.get("request_start", started) or started)
            request_end = float(metric_state.get("request_end", finished) or finished)
            self._emit_metric(
                {
                    "event": "edge_request",
                    "engine": "edge",
                    "status": status,
                    "error_category": error_category,
                    "segment_chars": len(text or ""),
                    "queue_wait_ms": round(
                        max(0.0, float(metric_state.get("queue_wait_ms", 0.0) or 0.0)), 3
                    ),
                    "request_ms": round(max(0.0, request_end - request_start) * 1000.0, 3),
                    "retry_count": int(metric_state.get("retry_count", 0) or 0),
                    "received_chunks": int(metric_state.get("received_chunks", 0) or 0),
                    "write_ms": round(
                        max(0.0, float(metric_state.get("write_ms", 0.0) or 0.0)) * 1000.0,
                        3,
                    ),
                    "validation_ms": 0.0,
                    "active_requests": int(metric_state.get("active_requests", 0) or 0),
                }
            )

    async def _recover_failed_segment(
        self,
        original_text: str,
        voice: str,
        output_path: Path,
    ) -> bool:
        """Last-resort recovery for a single Edge segment that came back empty.

        Strategy (in order, each step skipped if it succeeds):

        1. Aggressive Unicode cleanup (NFKC + strip invisible codepoints
           + collapse weird whitespace) and re-attempt the *whole*
           segment. The cleanup catches the common case where Edge
           rejected the payload because of a soft hyphen or zero-width
           joiner copy-pasted from the EPUB source.
        2. Sentence-level sub-division: split the cleaned text into
           sentences (force-split if any sentence is still too long)
           and synthesise each one as its own Edge call, appending into
           ``output_path``. A whole chapter never fails because of one
           toxic sentence — only that sentence is missing.

        Returns True if the recovery wrote audio to ``output_path``.
        Returns False (and the caller falls through to its normal failure
        path) if both attempts produced nothing.

        This method is called by the recovery branch in the parallel
        retry loop. It deliberately does NOT involve Piper or any
        non-Edge engine — listener feedback prefers a missing sentence
        over a different-quality voice in the middle of the audio.
        """
        from . import edge_engine as _runtime
        from ..text_sanitizer import (
            sanitize_for_edge_recovery,
            split_into_sentences,
        )

        cleaned = sanitize_for_edge_recovery(original_text or "")
        if not cleaned:
            return False

        # Step 1: re-attempt the whole segment with the cleaned payload.
        if cleaned != original_text:
            if self.verbose:
                self._log(
                    "   🧼 Recovery: retrying with sanitised text "
                    f"({len(original_text)}→{len(cleaned)} chars)"
                )
            try:
                if await self._synthesize_segment(cleaned, voice, output_path, append=False):
                    return True
            except Exception as exc:
                if self.verbose:
                    self._log(f"   🧼 Recovery whole-text retry crashed: {exc}")

        # Step 2: sub-divide into sentences and append each to output_path.
        sentences = split_into_sentences(cleaned)
        if not sentences:
            return False
        if self.verbose:
            self._log(
                "   ✂️  Recovery: sub-dividing into " f"{len(sentences)} sentence-sized fragments"
            )

        # Make sure the file starts empty before appending — we may have
        # left a partial write from step 1.
        with _runtime.suppress(OSError):
            output_path.unlink(missing_ok=True)

        any_success = False
        for idx, sentence in enumerate(sentences):
            try:
                ok = await self._synthesize_segment(sentence, voice, output_path, append=True)
            except Exception as exc:
                ok = False
                if self.verbose:
                    self._log(
                        f"   ✂️  Recovery fragment {idx + 1}/{len(sentences)} " f"crashed: {exc}"
                    )
            if ok:
                any_success = True
            elif self.verbose:
                self._log(
                    f"   ✂️  Recovery fragment {idx + 1}/{len(sentences)} "
                    "produced no audio (skipping)"
                )

        return any_success and output_path.exists() and output_path.stat().st_size > 0
