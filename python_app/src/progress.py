# -*- coding: utf-8 -*-
"""
Simplified Progress Tracker - SOLID principles applied
New focused module for progress tracking following SRP
"""

import os
import sys
import time
from typing import Optional

from .utils import TimeFormatter


class ProgressTracker:
    """Tracks conversion progress and prints a live ETA/percentage bar."""

    def __init__(self, total_chapters: int = 0, description: str = "Converting chapters"):
        self.description = description
        self.total_chapters = max(int(total_chapters), 0)
        self.completed_chapters = 0
        self.current_chapter: Optional[str] = None
        self.current_index: Optional[int] = None
        self.start_time = time.time()
        self._chapter_start_time: float = time.time()
        self._phase_start_time: float = self._chapter_start_time
        self._last_status: str = ""
        self._last_render_len: int = 0
        self._last_render: str = ""
        force_static = os.getenv("FORCE_STATIC_PROGRESS", "1").strip().lower() in {
            "1",
            "true",
            "yes",
            "on",
        }
        self._supports_overwrite = (not force_static) and sys.stdout.isatty()
        self._last_print_time: float = 0.0
        self._spinner_frames: tuple[str, ...] = ("-", "\\", "|", "/")
        self._spinner_index: int = 0
        self._last_progress_pct: float = -1.0
        self._last_activity_time: float = time.time()
        self._last_real_progress_time: float = self._last_activity_time
        self._eta_remaining_chars_hint: int = 0
        self._eta_chars_per_sec_hint: float = 0.0
        self._eta_hint_updated_at: float = 0.0
        self._eta_hint_max_age_seconds: float = float(
            os.getenv("ETA_HINT_MAX_AGE_SECONDS", "45") or "45"
        )

        # **NEW**: Character/sentence tracking for granular progress display
        self.total_chars: int = 0
        self.processed_chars: int = 0
        self.current_sentence: str = ""
        self.sentences_processed: int = 0
        # **NEW**: Track chunk-level progress (useful for streaming)
        self.total_chunks: int = 0
        self.processed_chunks: int = 0
        self._chunks_confident: bool = False
        # Parallel chapter tracking: index → short label
        self._active_chapters: dict[int, str] = {}
        self._active_engine: str = ""

    def start(self, total_chapters: int, description: Optional[str] = None) -> None:
        """Reset tracker for a new run."""
        self.total_chapters = max(int(total_chapters), 0)
        if description:
            self.description = description
        self.completed_chapters = 0
        self.current_chapter = None
        self.current_index = None
        self.start_time = time.time()
        self._chapter_start_time = self.start_time
        self._phase_start_time = self._chapter_start_time
        self._last_status = ""
        self._last_render_len = 0
        self._last_render = ""
        self._last_print_time = 0.0
        force_static = os.getenv("FORCE_STATIC_PROGRESS", "1").strip().lower() in {
            "1",
            "true",
            "yes",
            "on",
        }
        self._supports_overwrite = (not force_static) and sys.stdout.isatty()
        self._spinner_index = 0
        self._last_progress_pct = -1.0
        self._last_activity_time = time.time()
        self._last_real_progress_time = self._last_activity_time
        self._eta_remaining_chars_hint = 0
        self._eta_chars_per_sec_hint = 0.0
        self._eta_hint_updated_at = 0.0
        if self.total_chapters == 0:
            self._render("No chapters available", force=True)

    def start_chapter(self, chapter_name: str, index: int) -> None:
        """Announce a new chapter conversion."""
        self.current_chapter = chapter_name
        self.current_index = index
        self._chapter_start_time = time.time()
        self._phase_start_time = self._chapter_start_time
        self._last_real_progress_time = self._chapter_start_time

        # **NEW**: Reset character counters for new chapter
        self.processed_chars = 0
        self.total_chars = 0
        self.current_sentence = ""
        self.sentences_processed = 0
        self.total_chunks = 0
        self.processed_chunks = 0
        self._chunks_confident = False
        self._active_chapters[index] = chapter_name
        self._active_engine = ""

        print(f"\n🎧 [{index}/{max(self.total_chapters, 1)}] {chapter_name}")

    def update_eta_hint(self, *, remaining_chars: int, chars_per_second: float) -> None:
        """Inject a chapter-size-aware ETA hint from converter telemetry."""
        self._eta_remaining_chars_hint = max(0, int(remaining_chars or 0))
        self._eta_chars_per_sec_hint = max(0.0, float(chars_per_second or 0.0))
        self._eta_hint_updated_at = time.time()

    def set_active_engine(self, engine: str) -> None:
        """Record the TTS engine currently in use (for display in progress bar)."""
        self._active_engine = (engine or "").lower().strip()

    def complete_chapter(self, status: str = "") -> None:
        """Mark chapter completion and refresh the progress bar."""
        if self.total_chapters:
            self.completed_chapters = min(self.completed_chapters + 1, self.total_chapters)
        else:
            self.completed_chapters += 1
        # Remove completed chapter from active set (remove by current index)
        if self.current_index is not None:
            self._active_chapters.pop(self.current_index, None)
        self._last_real_progress_time = time.time()
        self._render(status)

    def update_chars_progress(self, text: str, total_chars: int = 0) -> None:
        """
        **NEW**: Update progress based on characters/sentences being processed.
        Shows that the system is not stuck.

        Args:
            text: Current text/sentence being processed
            total_chars: Total characters in the chapter (optional)
        """
        if total_chars > 0:
            self.total_chars = total_chars

        if self.total_chapters and self.completed_chapters >= self.total_chapters:
            return

        if self.total_chars > 0:
            self.processed_chars = min(self.processed_chars + len(text), self.total_chars)
        else:
            self.processed_chars += len(text)
        self.sentences_processed += 1
        self._last_real_progress_time = time.time()

        # **THROTTLE**: Only update every 0.5s to avoid overhead
        now = time.time()
        if now - self._last_print_time < 0.5:
            return
        self._last_print_time = now

        # Truncate sentence for display
        self.current_sentence = text[:60] + "..." if len(text) > 60 else text

        # Calculate current chapter progress
        chapter_progress = ""
        if self.total_chars > 0:
            char_percent = (self.processed_chars / self.total_chars) * 100
            chapter_progress = f" [{char_percent:.1f}% of ch]"

        # Update status
        status = f'🔊 Processing: "{self.current_sentence}"{chapter_progress}'
        self._render(status)

    def set_total_chunks(self, total: int) -> None:
        """Set the expected chunk count when known by the engine."""
        if total > 0:
            self.total_chunks = total
            self._chunks_confident = True

    def update_chunk_progress(self, chunk_index: int) -> None:
        """
        Update progress based on completed audio chunks.
        Uses chunk count as a more accurate signal that text was synthesized.
        """
        # chunk_index is zero-based
        self.processed_chunks = max(self.processed_chunks, chunk_index + 1)
        self.total_chunks = max(self.total_chunks, chunk_index + 1)
        self._last_real_progress_time = time.time()
        if self.total_chars > 0:
            # Conservative estimate when total chunk count is unknown.
            # This avoids "ETA 1m" illusions on long chapters where chunks keep growing.
            if self._chunks_confident and self.total_chunks > 0:
                denom = max(self.total_chunks + 2, 1)
            else:
                # Rough baseline: ~2500 chars/chunk for local engines, plus safety headroom.
                guessed_total = max(
                    self.processed_chunks + 8,
                    int(max(self.total_chars, 1) / 2500),
                    12,
                )
                denom = guessed_total
            estimated_fraction = min(0.90, self.processed_chunks / max(denom, 1))
            self.processed_chars = max(
                self.processed_chars, int(self.total_chars * estimated_fraction)
            )

        # Render immediately to reflect chunk completion
        status = f"🎧 Chunk {self.processed_chunks}/{self.total_chunks} ready"
        self._render(status, force=True)

    def tick(self, status: str = "") -> None:
        """Refresh the progress bar without changing counters."""
        # Don't show heartbeat ticks after all chapters completed (race condition fix)
        if self.total_chapters and self.completed_chapters >= self.total_chapters:
            return
        self._render(status or self._last_status, force=True)

    def mark_activity(self) -> None:
        """Mark real progress/activity to reset stall timers between retries/engine switches."""
        self._last_real_progress_time = time.time()

    def finish(self) -> None:
        """Print final summary and release the line."""
        elapsed = time.time() - self.start_time
        # Ensure bar shows as completed
        if self.total_chapters and self.completed_chapters < self.total_chapters:
            self.completed_chapters = self.total_chapters
            self._render("Finishing")
        formatted_time = TimeFormatter.format_time(elapsed)
        print(f"\n✅ Conversion completed in {formatted_time}")

    def mark_phase_start(self) -> None:
        """Reset the timer for the active phase (after waiting slots)."""
        self._phase_start_time = time.time()

    def _render(self, status: str = "", force: bool = False) -> None:
        previous_status = self._last_status
        now = time.time()
        status = (status or "").strip()
        if len(status) > 80:
            status = status[:77] + "..."

        if status and status != previous_status:
            self._phase_start_time = now

        progress_pct = self._progress_percentage()
        if self.total_chapters > 0 and self.completed_chapters == 0 and progress_pct <= 0.0:
            progress_pct = 0.01
        elapsed = now - self.start_time
        eta_seconds = self._eta_seconds(elapsed)
        eta_str = TimeFormatter.format_eta(eta_seconds) if eta_seconds > 0 else "--"
        bar = self._generate_progress_bar(progress_pct)

        spinner = ""
        if status.startswith("⏳") or status.startswith("🔊"):
            if status != previous_status:
                self._spinner_index = 0
            spinner = f" {self._spinner_frames[self._spinner_index]}"
            self._spinner_index = (self._spinner_index + 1) % len(self._spinner_frames)
        display_status = f"{status}{spinner}" if status else ""

        total_display = (
            self.total_chapters if self.total_chapters else max(self.completed_chapters, 1)
        )
        # Build compact "active chapter" label for display in the progress bar.
        # When multiple chapters run in parallel show the most recently started one + count.
        active_label = ""
        if self._active_chapters:
            # Most recently started = highest index key
            latest_idx = max(self._active_chapters)
            latest_name = self._active_chapters[latest_idx]
            abbrev = latest_name[:28] + "…" if len(latest_name) > 28 else latest_name
            extra = len(self._active_chapters) - 1
            active_label = f" 📖 {abbrev}" + (f" +{extra}" if extra > 0 else "")
            if self._active_engine:
                active_label += f" [{self._active_engine}]"

        message = (
            f"{self.description}: [{bar}] {progress_pct:.2f}% "
            f"({self.completed_chapters}/{total_display}) "
            f"time remaining: {eta_str}{active_label}"
        )
        if display_status:
            chapter_elapsed = TimeFormatter.format_time(now - self._chapter_start_time)
            phase_elapsed = TimeFormatter.format_time(now - self._phase_start_time)
            if status.startswith("⌛"):
                wait_elapsed = TimeFormatter.format_time(now - self._chapter_start_time)
                message += f" | {display_status} (wait: {wait_elapsed})"
            else:
                message += (
                    f" | {display_status} (phase: {phase_elapsed} | chapter: {chapter_elapsed})"
                )
        self._last_status = status
        self._last_activity_time = now

        rendered = message
        if self._supports_overwrite:
            if self._last_render_len > len(message):
                rendered += " " * (self._last_render_len - len(message))
            if not force and rendered == self._last_render:
                return
            print(f"\r{rendered}", end="", flush=True)
            self._last_render_len = len(rendered)
            self._last_render = rendered
            if force:
                print("", end="", flush=True)
        else:
            progress_delta = progress_pct - (
                self._last_progress_pct if self._last_progress_pct >= 0 else progress_pct
            )
            if not force:
                if rendered == self._last_render:
                    return
                if status == previous_status and progress_delta < 1.0:
                    return
            print(rendered, flush=True)
            self._last_render_len = len(rendered)
            self._last_render = rendered
            self._last_progress_pct = progress_pct

    def _progress_percentage(self) -> float:
        if self.total_chapters <= 0:
            return 100.0 if self.completed_chapters else 0.0
        base = float(self.completed_chapters)
        partial = 0.0
        # Prioritize completed chunks (more faithful to generated audio), then fallback to characters
        if self.completed_chapters < self.total_chapters and self.current_index is not None:
            if self.total_chunks > 0 and (
                self._chunks_confident or self.processed_chunks < self.total_chunks
            ):
                partial = min(0.99, max(0.0, self.processed_chunks / self.total_chunks))
            elif self.total_chars > 0:
                partial = min(0.99, max(0.0, self.processed_chars / self.total_chars))
        progress = ((base + partial) / self.total_chapters) * 100
        if self.completed_chapters < self.total_chapters:
            return min(99.99, max(0.0, progress))
        return min(100.0, max(0.0, progress))

    def seconds_since_activity(self) -> float:
        return max(0.0, time.time() - self._last_real_progress_time)

    def _eta_seconds(self, elapsed: float) -> float:
        if self.total_chapters <= 0:
            return 0.0

        # Prefer explicit telemetry ETA when converter can estimate remaining chars.
        hint_age = time.time() - (self._eta_hint_updated_at or 0.0)
        if (
            self._eta_remaining_chars_hint > 0
            and self._eta_chars_per_sec_hint > 1.0
            and hint_age <= self._eta_hint_max_age_seconds
        ):
            return self._eta_remaining_chars_hint / self._eta_chars_per_sec_hint

        # If we have no real progress for a while, suppress misleading short ETA.
        if self.seconds_since_activity() >= 60.0:
            return 0.0

        # Use fractional progress (including current chapter) to avoid ETA explosion early on.
        partial = 0.0
        if self.completed_chapters < self.total_chapters and self.current_index is not None:
            if self.total_chunks > 0 and (
                self._chunks_confident or self.processed_chunks < self.total_chunks
            ):
                partial = min(0.99, max(0.0, self.processed_chunks / self.total_chunks))
            elif self.total_chars > 0:
                partial = min(0.99, max(0.0, self.processed_chars / self.total_chars))

        progress_fraction = (self.completed_chapters + partial) / max(self.total_chapters, 1)
        progress_fraction = min(max(progress_fraction, 0.001), 0.999)

        remaining_fraction = 1.0 - progress_fraction
        raw_eta = max(elapsed * (remaining_fraction / progress_fraction), 0.0)

        # Cap ETA when we have no real progress data yet (prevents absurd estimates)
        # If no chunks/chars have been processed, we're just guessing — show "--" equivalent
        has_progress_data = (
            self.completed_chapters > 0 or self.processed_chunks > 0 or self.processed_chars > 0
        )
        if not has_progress_data:
            # No data yet: don't guess, just show elapsed as a rough placeholder
            return elapsed * 2  # Conservative: assume we're ~halfway through setup

        return raw_eta

    def _generate_progress_bar(self, progress_pct: float, bar_width: int = 30) -> str:
        filled = int(bar_width * progress_pct / 100)
        return "█" * filled + "░" * (bar_width - filled)
