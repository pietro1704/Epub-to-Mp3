# -*- coding: utf-8 -*-
"""
Simplified Progress Tracker - SOLID principles applied
New focused module for progress tracking following SRP
"""

import time
from typing import Optional


class ProgressTracker:
    """Tracks conversion progress and prints a live ETA/percentage bar."""

    def __init__(self, total_chapters: int = 0, description: str = "Convertendo capítulos"):
        self.description = description
        self.total_chapters = max(int(total_chapters), 0)
        self.completed_chapters = 0
        self.current_chapter: Optional[str] = None
        self.current_index: Optional[int] = None
        self.start_time = time.time()
        self._last_status: str = ""
        self._last_render_len: int = 0
        self._last_render: str = ""

    def start(self, total_chapters: int, description: Optional[str] = None) -> None:
        """Reset tracker for a new run."""
        self.total_chapters = max(int(total_chapters), 0)
        if description:
            self.description = description
        self.completed_chapters = 0
        self.current_chapter = None
        self.current_index = None
        self.start_time = time.time()
        self._last_status = ""
        self._last_render_len = 0
        self._last_render = ""
        if self.total_chapters == 0:
            self._render("Nenhum capítulo disponível", force=True)

    def start_chapter(self, chapter_name: str, index: int) -> None:
        """Announce a new chapter conversion."""
        self.current_chapter = chapter_name
        self.current_index = index
        print(f"\n🎧 [{index}/{max(self.total_chapters, 1)}] {chapter_name}")

    def complete_chapter(self, status: str = "") -> None:
        """Mark chapter completion and refresh the progress bar."""
        if self.total_chapters:
            self.completed_chapters = min(self.completed_chapters + 1, self.total_chapters)
        else:
            self.completed_chapters += 1
        self._render(status)

    def tick(self, status: str = "") -> None:
        """Refresh the progress bar without changing counters."""
        self._render(status or self._last_status, force=True)

    def finish(self) -> None:
        """Print final summary and release the line."""
        elapsed = time.time() - self.start_time
        # Ensure bar shows as completed
        if self.total_chapters and self.completed_chapters < self.total_chapters:
            self.completed_chapters = self.total_chapters
            self._render("Finalizando")
        print(f"\n✅ Conversão concluída em {self._format_time(elapsed)}")

    def _render(self, status: str = "", force: bool = False) -> None:
        progress_pct = self._progress_percentage()
        elapsed = time.time() - self.start_time
        eta_seconds = self._eta_seconds(elapsed)
        eta_str = self._format_time(eta_seconds) if eta_seconds > 0 else "--"
        bar = self._generate_progress_bar(progress_pct)

        status = status.strip()
        if len(status) > 80:
            status = status[:77] + "..."
        self._last_status = status

        total_display = self.total_chapters if self.total_chapters else max(self.completed_chapters, 1)
        message = (
            f"{self.description}: [{bar}] {progress_pct:.1f}% "
            f"({self.completed_chapters}/{total_display}) "
            f"tempo restante: {eta_str}"
        )
        if status:
            message += f" | {status}"

        rendered = message
        if self._last_render_len > len(message):
            rendered += " " * (self._last_render_len - len(message))

        if not force and rendered == self._last_render:
            return

        print(f"\r{rendered}", end="", flush=True)
        self._last_render_len = len(rendered)
        self._last_render = rendered
        if force:
            print("", end="", flush=True)

    def _progress_percentage(self) -> float:
        if self.total_chapters <= 0:
            return 100.0 if self.completed_chapters else 0.0
        return (self.completed_chapters / self.total_chapters) * 100

    def _eta_seconds(self, elapsed: float) -> float:
        if self.total_chapters <= 0 or self.completed_chapters == 0:
            return 0.0
        remaining = self.total_chapters - self.completed_chapters
        if remaining <= 0:
            return 0.0
        avg_per_chapter = elapsed / self.completed_chapters
        return max(avg_per_chapter * remaining, 0.0)

    def _generate_progress_bar(self, progress_pct: float, bar_width: int = 30) -> str:
        filled = int(bar_width * progress_pct / 100)
        return "█" * filled + "░" * (bar_width - filled)

    def _format_time(self, seconds: float) -> str:
        seconds = int(max(seconds, 0))
        mins, secs = divmod(seconds, 60)
        hours, mins = divmod(mins, 60)
        if hours:
            return f"{hours}h {mins}m"
        if mins:
            return f"{mins}m {secs}s"
        return f"{secs}s"
