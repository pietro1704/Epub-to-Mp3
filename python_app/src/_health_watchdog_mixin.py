"""Health watchdog and final report mixin for AudioConverter."""

from __future__ import annotations

import asyncio
import contextlib
import time
from pathlib import Path
from typing import List, Optional

from .ebook_reader import Chapter


class _HealthWatchdogMixin:
    def _start_health_watchdog(self, total_chapters: int) -> None:
        """Launch watchdog to observe stalled conversions."""
        if total_chapters <= 0:
            return
        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:
            return
        state = {
            "active": True,
            "total": max(total_chapters, 0),
            "completed": 0,
            "last_progress": time.time(),
            "warn_emitted": False,
            "action_emitted": False,
        }
        self._health_state = state
        if self._health_watchdog:
            self._health_watchdog.cancel()
        self._health_watchdog = loop.create_task(self._watch_conversion_health())

    async def _stop_health_watchdog(self) -> None:
        """Stop watchdog task."""
        state = getattr(self, "_health_state", None)
        if isinstance(state, dict):
            state["active"] = False
        task = self._health_watchdog
        self._health_watchdog = None
        if task:
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await task

    def _mark_health_progress(
        self,
        chapter_index: int,
        success: bool,
        elapsed: float,
        error: Optional[str] = None,
    ) -> None:
        """Update watchdog state after each chapter."""
        state = getattr(self, "_health_state", None)
        if not isinstance(state, dict) or not state.get("active"):
            return
        state["last_progress"] = time.time()
        state["completed"] = min(state.get("completed", 0) + 1, state.get("total", 0))
        state["last_chapter"] = chapter_index
        state["last_success"] = bool(success)
        state["last_elapsed"] = float(elapsed or 0.0)
        state["last_error"] = error or ""
        state["warn_emitted"] = False
        state["action_emitted"] = False

    def _mark_health_activity(self, chapter_index: int, status: str = "") -> None:
        """Update watchdog state for in-flight activity."""
        state = getattr(self, "_health_state", None)
        if not isinstance(state, dict) or not state.get("active"):
            return
        state["last_progress"] = time.time()
        state["last_chapter"] = chapter_index
        state["last_activity"] = status
        state["warn_emitted"] = False
        state["action_emitted"] = False

    async def _watch_chapter_stall(
        self,
        chapter_index: int,
        task: asyncio.Task,
        stall_seconds: float,
        stall_event: asyncio.Event,
        probe_dir: Optional[Path] = None,
    ) -> None:
        """Cancel synthesis task if no progress is detected for too long."""
        if stall_seconds <= 0:
            return
        last_probe_mtime = 0.0
        probe_patterns = ("piper_chunk*.wav", "chunk_*.wav", "chunk_*.mp3")
        check_interval = max(5.0, min(15.0, stall_seconds / 3))
        while not task.done():
            await asyncio.sleep(check_interval)
            if task.done():
                return
            if probe_dir and probe_dir.exists():
                newest = 0.0
                try:
                    for pattern in probe_patterns:
                        for fp in probe_dir.glob(pattern):
                            try:
                                newest = max(newest, float(fp.stat().st_mtime))
                            except Exception:
                                continue
                except Exception:
                    newest = 0.0
                if newest > 0.0 and newest > last_probe_mtime:
                    last_probe_mtime = newest
                    with contextlib.suppress(Exception):
                        self.progress.mark_activity()
            if self.progress.seconds_since_activity() >= stall_seconds:
                stall_event.set()
                print(
                    f"\n🛟 Watchdog: chapter {chapter_index} no progress for {int(stall_seconds)}s"
                )
                self.progress.tick(
                    f"🛟 No progress for {int(stall_seconds)}s - restarting chapter..."
                )
                task.cancel()
                return

    async def _watch_conversion_health(self) -> None:
        """Background loop that watches for long stalls."""
        warning_threshold = 90.0
        action_threshold = 150.0
        check_interval = 15.0
        while True:
            await asyncio.sleep(check_interval)
            state = getattr(self, "_health_state", None)
            if not isinstance(state, dict) or not state.get("active"):
                break
            total = state.get("total", 0)
            completed = state.get("completed", 0)
            if total and completed >= total:
                break
            last_progress = state.get("last_progress") or time.time()
            stalled = time.time() - last_progress
            if stalled >= action_threshold and not state.get("action_emitted"):
                state["action_emitted"] = True
                last_chapter = state.get("last_chapter")
                info = f"{int(stalled)}s sem concluir chapters"
                if last_chapter:
                    info += f" (last chapter #{last_chapter})"
                print(f"\n🩺 Watchdog: {info} – investigating bottleneck")
                if not self._apply_watchdog_backpressure():
                    print(
                        "   Suggestion: check connection ou allow offline fallback (Coqui/Piper)."
                    )
            elif stalled >= warning_threshold and not state.get("warn_emitted"):
                state["warn_emitted"] = True
                print(
                    f"\n⚠️ Watchdog: No chapters completed for {int(stalled)}s – awaiting progress..."
                )

    def _apply_watchdog_backpressure(self) -> bool:
        """Reduce parallelism when stalling to regain stability."""
        state = self._parallel_state or {}
        current = int(state.get("current") or 1)
        ceiling = int(state.get("ceiling") or current)
        if current > 1:
            new_value = max(1, current - 1)
            state["current"] = new_value
            state["ceiling"] = max(1, min(new_value, ceiling))
            self._parallel_state = state
            print(f"   🧠 Watchdog: reducing concurrent chapters {current} → {new_value}")
            return True
        return False

    def _print_final_validation_report(
        self,
        chapters: List[Chapter],
        converted_files: List[Path],
        errors: List[str],
        output_dir: Path,
        verbose: bool = False,
    ) -> None:
        """Print comprehensive validation report comparing EPUB chapters with audio output.

        Args:
            chapters: List of chapters from the original EPUB
            converted_files: List of successfully converted audio files
            errors: List of conversion errors
            output_dir: Output directory containing audio files
            verbose: Print detailed information
        """
        if not chapters:
            return

        print("\n" + "=" * 60)
        print("📊 Integrity Validation Report")
        print("=" * 60)

        # Count chapters
        total_chapters = len(chapters)
        successful_chapters = len(converted_files)
        failed_chapters = len(errors)
        missing_chapters = total_chapters - successful_chapters

        # Basic stats
        print(f"\n📚 Original EPUB chapters: {total_chapters}")
        print(f"✅ Successfully generated: {successful_chapters} chapter(s)")

        if missing_chapters > 0:
            print(f"❌ Missing chapters: {missing_chapters}")

        if failed_chapters > 0:
            print(f"⚠️ Conversion errors: {failed_chapters}")

        # Check for duplicates by comparing file names
        file_names = [f.name for f in converted_files]
        unique_names = set(file_names)
        duplicate_count = len(file_names) - len(unique_names)

        if duplicate_count > 0:
            print(f"🔄 Duplicate files detected: {duplicate_count}")
            if verbose:
                # Find and print duplicate names
                seen = set()
                duplicates = []
                for name in file_names:
                    if name in seen:
                        duplicates.append(name)
                    seen.add(name)
                if duplicates:
                    print("   Duplicates:")
                    for dup in duplicates[:5]:  # Show first 5
                        print(f"   - {dup}")
                    if len(duplicates) > 5:
                        print(f"   ... and {len(duplicates) - 5} more")

        # Check for missing chapters by comparing titles
        if missing_chapters > 0 and verbose:
            print("\n⚠️ Potentially missing chapters:")
            converted_titles = {self._normalize_title_match(f.stem) for f in converted_files}
            for idx, chapter in enumerate(chapters, start=1):
                chapter_title = getattr(chapter, "name", f"Chapter {idx}")
                normalized_title = self._normalize_title_match(chapter_title)
                # Check if any converted file matches this chapter
                found = any(normalized_title in title for title in converted_titles)
                if not found:
                    print(f"   - Chapter {idx}: {chapter_title[:60]}")

        # Overall validation status
        print("\n" + "─" * 60)
        if successful_chapters == total_chapters and duplicate_count == 0:
            print("✅ VALIDATION: COMPLETE AND INTACT")
            print("   All chapters from the original EPUB were successfully converted.")
        elif successful_chapters == total_chapters:
            print("✅ VALIDATION: COMPLETE (with warnings)")
            print("   All chapters were converted, but there are duplicates.")
        elif missing_chapters > 0:
            print("⚠️ VALIDATION: INCOMPLETE")
            print(f"   {missing_chapters} chapter(s) were not converted or failed.")
            if errors:
                print("   Check the error logs above for more details.")
        print("=" * 60 + "\n")
