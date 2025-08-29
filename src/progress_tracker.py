# -*- coding: utf-8 -*-
"""
Progress tracker para conversões
"""

import time
from typing import Optional


class ProgressTracker:
    """Rastreamento de progresso com ETA"""
    
    def __init__(self, total_items: int, description: str = "Processando"):
        self.total_items = total_items
        self.description = description
        self.current_item = 0
        self.start_time = time.time()
        self.last_update = self.start_time
    
    def update(self, current_item: int, status_message: str = ""):
        """Atualiza progresso atual"""
        self.current_item = current_item
        self.last_update = time.time()
        
        # Calcula ETA
        elapsed = self.last_update - self.start_time
        if current_item > 0:
            eta = (elapsed / current_item) * (self.total_items - current_item)
            eta_str = self._format_time(eta)
        else:
            eta_str = "calculando..."
        
        # Calcula porcentagem
        progress_pct = (current_item / self.total_items) * 100
        
        # Barra de progresso visual
        bar_width = 30
        filled = int(bar_width * progress_pct / 100)
        bar = "█" * filled + "░" * (bar_width - filled)
        
        print(f"\r{self.description}: [{bar}] {progress_pct:.1f}% ({current_item}/{self.total_items}) ETA: {eta_str} - {status_message}", end="", flush=True)
    
    def finish(self, final_message: str = "Concluído"):
        """Finaliza progresso"""
        elapsed = time.time() - self.start_time
        elapsed_str = self._format_time(elapsed)
        print(f"\n✅ {final_message} em {elapsed_str}")
    
    def _format_time(self, seconds: float) -> str:
        """Formata tempo em string legível"""
        if seconds < 60:
            return f"{seconds:.0f}s"
        elif seconds < 3600:
            return f"{seconds/60:.0f}m {seconds%60:.0f}s"
        else:
            hours = int(seconds // 3600)
            minutes = int((seconds % 3600) // 60)
            return f"{hours}h {minutes}m"