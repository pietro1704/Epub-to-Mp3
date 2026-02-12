# -*- coding: utf-8 -*-
"""
Unified progress tracker for conversions
"""

import time

from .utils import TimeFormatter


class ProgressTracker:
    """Unified progress tracking for conversions"""

    def __init__(self, total_items: int, description: str = "Processing"):
        self.total_items = total_items
        self.description = description
        self.current_item = 0
        self.start_time = time.time()

    def update(self, current_item: int, status_message: str = ""):
        """Update current progress"""
        self.current_item = current_item
        elapsed = time.time() - self.start_time
        eta = (
            (elapsed / current_item) * (self.total_items - current_item) if current_item > 0 else 0
        )
        progress_pct = (current_item / self.total_items) * 100
        bar = self._generate_progress_bar(progress_pct)
        print(
            f"\r{self.description}: [{bar}] {progress_pct:.1f}% ({current_item}/{self.total_items}) ETA: {self._format_time(eta)} - {status_message}",
            end="",
            flush=True,
        )

    def finish(self):
        """Mark progress as completed"""
        elapsed = time.time() - self.start_time
        print(f"\n✅ Completed in {self._format_time(elapsed)}")

    def _generate_progress_bar(self, progress_pct: float, bar_width: int = 30) -> str:
        filled = int(bar_width * progress_pct / 100)
        return "█" * filled + "░" * (bar_width - filled)

    def _format_time(self, seconds: float) -> str:
        return TimeFormatter.format_time(seconds)
