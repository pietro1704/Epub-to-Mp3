# -*- coding: utf-8 -*-
"""
Progress tracker unificado para conversões
"""

import time


class ProgressTracker:
    """Rastreamento de progresso unificado para conversões"""

    def __init__(self, total_items: int, description: str = "Processando"):
        self.total_items = total_items
        self.description = description
        self.current_item = 0
        self.start_time = time.time()

    def update(self, current_item: int, status_message: str = ""):
        """Atualiza progresso atual"""
        self.current_item = current_item
        elapsed = time.time() - self.start_time
        eta = (elapsed / current_item) * (self.total_items - current_item) if current_item > 0 else 0
        progress_pct = (current_item / self.total_items) * 100
        bar = self._generate_progress_bar(progress_pct)
        print(f"\r{self.description}: [{bar}] {progress_pct:.1f}% ({current_item}/{self.total_items}) ETA: {self._format_time(eta)} - {status_message}", end="", flush=True)

    def finish(self):
        """Marca o progresso como concluído"""
        elapsed = time.time() - self.start_time
        print(f"\n✅ Concluído em {self._format_time(elapsed)}")

    def _generate_progress_bar(self, progress_pct: float, bar_width: int = 30) -> str:
        filled = int(bar_width * progress_pct / 100)
        return "█" * filled + "░" * (bar_width - filled)

    def _format_time(self, seconds: float) -> str:
        mins, secs = divmod(int(seconds), 60)
        return f"{mins}m {secs}s" if mins > 0 else f"{secs}s"