"""Health watchdog and final report mixin for AudioConverter."""

from __future__ import annotations

import asyncio
import contextlib
import time
from pathlib import Path
from typing import Any, List, Optional

from .ebook_reader import Chapter


async def _safe_cancel_task(
    task: Optional[asyncio.Task],
    grace: float = 10.0,
) -> bool:
    """Cancel a task and wait up to ``grace`` seconds for it to unwind.

    If the task does not honor cancellation within the grace window the
    reference is dropped and we return ``False`` — this trades a potential
    resource leak for the guarantee that the caller never blocks indefinitely
    on a non-cooperative coroutine (e.g. an HTTP stream stuck in a C-level
    wait).  Without this guard the outer ``asyncio.wait_for`` could hang
    forever, silently stalling the whole job.
    """
    if task is None or task.done():
        return True
    task.cancel()
    with contextlib.suppress(BaseException):
        await asyncio.wait({task}, timeout=max(0.1, float(grace)))
    return task.done()


async def _await_task_with_deadline(
    task: asyncio.Task,
    timeout: float,
    *,
    grace: float = 15.0,
) -> Any:
    """Await ``task`` under an outer deadline that cannot deadlock.

    Unlike ``asyncio.wait_for`` — which awaits the cancelled coroutine after
    the deadline and can therefore block forever if the coroutine swallows
    cancellation — this helper gives the task a bounded grace period and
    then detaches, raising ``asyncio.TimeoutError``.
    """
    if task is None:
        raise asyncio.TimeoutError()
    try:
        done, _ = await asyncio.wait({task}, timeout=max(0.1, float(timeout)))
    except asyncio.CancelledError:
        await _safe_cancel_task(task, grace=grace)
        raise
    if task in done:
        return task.result()
    await _safe_cancel_task(task, grace=grace)
    raise asyncio.TimeoutError()


async def _run_with_hard_deadline(
    factory,
    timeout: float,
    *,
    grace: float = 15.0,
) -> Any:
    """Run ``factory()`` under a deadline with the same guarantees as
    :func:`_await_task_with_deadline`, creating the task for the caller."""
    coro = factory()
    task = asyncio.ensure_future(coro)
    return await _await_task_with_deadline(task, timeout, grace=grace)


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

    async def _watch_segment_idle(
        self,
        chapter_index: int,
        task: asyncio.Task,
        progress_state: dict,
        idle_seconds: float,
        *,
        check_interval: float = 10.0,
        stall_event: Optional[asyncio.Event] = None,
        label: str = "segment",
    ) -> None:
        """Cancel ``task`` if ``progress_state['hits']`` does not advance.

        This is a per-chapter watchdog that is immune to sibling-chapter
        activity (unlike :func:`_watch_chapter_stall`, which relies on the
        shared progress timer and can be reset by any parallel chapter).
        It is the last-line defence against silent stalls in the middle of
        a multi-segment synthesis — the scenario where the network drops a
        stream without raising and the inner ``wait_for`` has plenty of
        headroom left on its outer timeout.
        """
        try:
            idle_seconds = max(0.0, float(idle_seconds))
        except Exception:
            return
        if idle_seconds <= 0 or task is None or task.done():
            return
        check_interval = max(2.0, float(check_interval))
        try:
            last_hits = int(progress_state.get("hits", 0))
        except Exception:
            last_hits = 0
        last_advance = time.time()
        while not task.done():
            await asyncio.sleep(check_interval)
            if task.done():
                return
            try:
                current = int(progress_state.get("hits", 0))
            except Exception:
                current = last_hits
            if current != last_hits:
                last_hits = current
                last_advance = time.time()
                continue
            if (time.time() - last_advance) >= idle_seconds:
                print(
                    f"\n🛟 Idle watchdog: chapter {chapter_index} emitted no "
                    f"{label} for {int(idle_seconds)}s — aborting engine"
                )
                with contextlib.suppress(Exception):
                    from .session_logger import log_freeze

                    log_freeze(
                        source="segment_idle",
                        chapter_index=chapter_index,
                        stalled_seconds=time.time() - last_advance,
                        threshold_seconds=idle_seconds,
                        action=f"abort_engine ({label})",
                    )
                if stall_event is not None:
                    with contextlib.suppress(Exception):
                        stall_event.set()
                await _safe_cancel_task(task, grace=10.0)
                return

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
                with contextlib.suppress(Exception):
                    from .session_logger import log_freeze

                    log_freeze(
                        source="chapter_stall",
                        chapter_index=chapter_index,
                        stalled_seconds=self.progress.seconds_since_activity(),
                        threshold_seconds=stall_seconds,
                        action="cancel_and_restart_chapter",
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
                applied = self._apply_watchdog_backpressure()
                with contextlib.suppress(Exception):
                    from .session_logger import log_freeze

                    log_freeze(
                        source="health",
                        chapter_index=int(last_chapter or 0),
                        stalled_seconds=stalled,
                        threshold_seconds=action_threshold,
                        action="reduce_parallelism" if applied else "warn_only",
                    )
                if not applied:
                    print("   Suggestion: check connection ou allow offline fallback (Piper).")
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
