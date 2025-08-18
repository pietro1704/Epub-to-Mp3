"""
src/progress_tracker.py

Classe para rastreamento de progresso e cálculo de ETA.
"""

import time
from datetime import datetime, timedelta
from typing import List


class ProgressTracker:
    """Rastreia progresso e calcula ETA para conversão de capítulos."""
    
    def __init__(self, total_items: int, total_chars: int = 0):
        """
        Inicializa o tracker de progresso.
        
        Args:
            total_items: Número total de itens para processar
            total_chars: Número total de caracteres (opcional)
        """
        self.total_items = total_items
        self.total_chars = total_chars
        self.completed_items = 0
        self.completed_chars = 0
        self.start_time = time.time()
        self.item_start_time = None
        self.speeds: List[float] = []  # Lista de velocidades (chars/segundo)
        
    def start_item(self) -> None:
        """Marca início de processamento de um item."""
        self.item_start_time = time.time()
        
    def complete_item(self, char_count: int) -> None:
        """
        Marca conclusão de um item.
        
        Args:
            char_count: Número de caracteres processados neste item
        """
        if self.item_start_time:
            elapsed = time.time() - self.item_start_time
            if elapsed > 0:
                speed = char_count / elapsed
                self.speeds.append(speed)
                # Mantém apenas últimas 5 velocidades para média móvel
                if len(self.speeds) > 5:
                    self.speeds.pop(0)
        
        self.completed_items += 1
        self.completed_chars += char_count
        
    def get_eta(self, remaining_chars: int = 0) -> str:
        """
        Calcula ETA baseado na velocidade média.
        
        Args:
            remaining_chars: Caracteres restantes para processamento mais preciso
            
        Returns:
            String formatada com o ETA (HH:MM:SS)
        """
        if not self.speeds:
            return "Calculando..."
        
        avg_speed = sum(self.speeds) / len(self.speeds)
        
        if remaining_chars > 0:
            # Usa caracteres restantes para cálculo mais preciso
            seconds_remaining = remaining_chars / avg_speed
        else:
            # Usa items restantes
            remaining_items = self.total_items - self.completed_items
            if self.completed_items > 0:
                avg_time_per_item = (time.time() - self.start_time) / self.completed_items
                seconds_remaining = remaining_items * avg_time_per_item
            else:
                return "Calculando..."
        
        eta = datetime.now() + timedelta(seconds=seconds_remaining)
        return eta.strftime("%H:%M:%S")
    
    def get_speed(self) -> str:
        """
        Retorna velocidade média formatada.
        
        Returns:
            String com velocidade em chars/s
        """
        if not self.speeds:
            return "---"
        
        avg_speed = sum(self.speeds) / len(self.speeds)
        return f"{avg_speed:.0f} chars/s"
    
    def get_elapsed(self) -> str:
        """
        Retorna tempo decorrido formatado.
        
        Returns:
            String com tempo decorrido (Xh Ym Zs)
        """
        elapsed = time.time() - self.start_time
        hours = int(elapsed // 3600)
        minutes = int((elapsed % 3600) // 60)
        seconds = int(elapsed % 60)
        
        if hours > 0:
            return f"{hours}h {minutes}m {seconds}s"
        elif minutes > 0:
            return f"{minutes}m {seconds}s"
        else:
            return f"{seconds}s"
    
    def get_progress_percentage(self) -> float:
        """
        Retorna porcentagem de progresso baseada em itens completados.
        
        Returns:
            Porcentagem de 0.0 a 100.0
        """
        if self.total_items == 0:
            return 0.0
        return (self.completed_items / self.total_items) * 100.0
    
    def get_stats(self) -> dict:
        """
        Retorna estatísticas completas do progresso.
        
        Returns:
            Dicionário com todas as estatísticas
        """
        return {
            "completed_items": self.completed_items,
            "total_items": self.total_items,
            "completed_chars": self.completed_chars,
            "total_chars": self.total_chars,
            "progress_percentage": self.get_progress_percentage(),
            "elapsed_time": self.get_elapsed(),
            "current_speed": self.get_speed(),
            "eta": self.get_eta(),
            "avg_speed": sum(self.speeds) / len(self.speeds) if self.speeds else 0
        }
    
    def reset(self) -> None:
        """Reseta o tracker para um novo processamento."""
        self.completed_items = 0
        self.completed_chars = 0
        self.start_time = time.time()
        self.item_start_time = None
        self.speeds.clear()