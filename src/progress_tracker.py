"""
src/progress_tracker.py

Classe para rastreamento de progresso com ETA preciso e estatísticas em tempo real.
"""

import time
from datetime import datetime, timedelta
from typing import List, Optional


class ProgressTracker:
    """Rastreia progresso com ETA preciso e múltiplas métricas."""
    
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
        
        # Listas para histórico
        self.speeds: List[float] = []  # chars/segundo
        self.item_times: List[float] = []  # tempo por item
        self.completion_times: List[float] = []  # timestamps de conclusão
        
        # Métricas avançadas
        self.fastest_speed = 0.0
        self.slowest_speed = float('inf')
        self.current_speed = 0.0
        
    def start_item(self) -> None:
        """Marca início de processamento de um item."""
        self.item_start_time = time.time()
        
    def complete_item(self, char_count: int) -> None:
        """
        Marca conclusão de um item com métricas detalhadas.
        
        Args:
            char_count: Número de caracteres processados neste item
        """
        current_time = time.time()
        
        if self.item_start_time:
            elapsed = current_time - self.item_start_time
            self.item_times.append(elapsed)
            
            if elapsed > 0 and char_count > 0:
                speed = char_count / elapsed
                self.speeds.append(speed)
                self.current_speed = speed
                
                # Atualiza métricas de velocidade
                self.fastest_speed = max(self.fastest_speed, speed)
                if speed > 0:  # Evita divisão por zero
                    self.slowest_speed = min(self.slowest_speed, speed)
                
                # Mantém apenas últimas 10 velocidades para média móvel
                if len(self.speeds) > 10:
                    self.speeds.pop(0)
        
        self.completed_items += 1
        self.completed_chars += char_count
        self.completion_times.append(current_time)
        
        # Limpa timestamp do item
        self.item_start_time = None
    
    def get_eta_by_items(self) -> str:
        """
        Calcula ETA baseado em items processados.
        
        Returns:
            String formatada com o ETA (HH:MM:SS)
        """
        if self.completed_items == 0:
            return "Calculando..."
        
        elapsed = time.time() - self.start_time
        avg_time_per_item = elapsed / self.completed_items
        remaining_items = self.total_items - self.completed_items
        
        if remaining_items <= 0:
            return "Concluído"
        
        seconds_remaining = remaining_items * avg_time_per_item
        eta = datetime.now() + timedelta(seconds=seconds_remaining)
        return eta.strftime("%H:%M:%S")
    
    def get_eta_by_chars(self, remaining_chars: Optional[int] = None) -> str:
        """
        Calcula ETA baseado em caracteres (mais preciso).
        
        Args:
            remaining_chars: Caracteres restantes específicos
            
        Returns:
            String formatada com o ETA
        """
        if not self.speeds:
            return "Calculando..."
        
        # Usa média ponderada das últimas velocidades (mais peso para recentes)
        if len(self.speeds) >= 3:
            weights = [1, 2, 3][-len(self.speeds):]
            weighted_avg = sum(s * w for s, w in zip(self.speeds, weights)) / sum(weights)
        else:
            weighted_avg = sum(self.speeds) / len(self.speeds)
        
        if remaining_chars is None:
            remaining_chars = self.total_chars - self.completed_chars
        
        if remaining_chars <= 0:
            return "Concluído"
        
        seconds_remaining = remaining_chars / weighted_avg if weighted_avg > 0 else 0
        
        if seconds_remaining > 86400:  # Mais de 1 dia
            days = int(seconds_remaining // 86400)
            hours = int((seconds_remaining % 86400) // 3600)
            return f"{days}d {hours}h"
        
        eta = datetime.now() + timedelta(seconds=seconds_remaining)
        return eta.strftime("%H:%M:%S")
    
    def get_best_eta(self, remaining_chars: Optional[int] = None) -> str:
        """
        Retorna o melhor ETA disponível.
        
        Args:
            remaining_chars: Caracteres restantes específicos
            
        Returns:
            ETA mais preciso baseado nos dados disponíveis
        """
        if self.speeds and len(self.speeds) >= 2:
            return self.get_eta_by_chars(remaining_chars)
        else:
            return self.get_eta_by_items()
    
    def get_current_speed(self) -> str:
        """
        Retorna velocidade atual formatada.
        
        Returns:
            String com velocidade atual
        """
        if not self.speeds:
            return "---"
        
        return f"{self.current_speed:.0f} chars/s"
    
    def get_average_speed(self) -> str:
        """
        Retorna velocidade média formatada.
        
        Returns:
            String com velocidade média
        """
        if not self.speeds:
            return "---"
        
        avg_speed = sum(self.speeds) / len(self.speeds)
        return f"{avg_speed:.0f} chars/s"
    
    def get_speed_range(self) -> str:
        """
        Retorna faixa de velocidade (min-max).
        
        Returns:
            String com velocidades mínima e máxima
        """
        if not self.speeds or len(self.speeds) < 2:
            return "---"
        
        if self.slowest_speed == float('inf'):
            self.slowest_speed = min(self.speeds)
        
        return f"{self.slowest_speed:.0f}-{self.fastest_speed:.0f} chars/s"
    
    def get_elapsed(self) -> str:
        """
        Retorna tempo decorrido formatado.
        
        Returns:
            String com tempo decorrido (Xh Ym Zs)
        """
        elapsed = time.time() - self.start_time
        
        if elapsed >= 3600:  # 1+ hora
            hours = int(elapsed // 3600)
            minutes = int((elapsed % 3600) // 60)
            seconds = int(elapsed % 60)
            return f"{hours}h {minutes}m {seconds}s"
        elif elapsed >= 60:  # 1+ minuto
            minutes = int(elapsed // 60)
            seconds = int(elapsed % 60)
            return f"{minutes}m {seconds}s"
        else:
            return f"{int(elapsed)}s"
    
    def get_progress_percentage(self) -> float:
        """
        Retorna porcentagem de progresso baseada em itens completados.
        
        Returns:
            Porcentagem de 0.0 a 100.0
        """
        if self.total_items == 0:
            return 0.0
        return (self.completed_items / self.total_items) * 100.0
    
    def get_char_progress_percentage(self) -> float:
        """
        Retorna porcentagem de progresso baseada em caracteres.
        
        Returns:
            Porcentagem de 0.0 a 100.0
        """
        if self.total_chars == 0:
            return 0.0
        return (self.completed_chars / self.total_chars) * 100.0
    
    def get_throughput_stats(self) -> dict:
        """
        Retorna estatísticas detalhadas de throughput.
        
        Returns:
            Dicionário com estatísticas completas
        """
        elapsed = time.time() - self.start_time
        
        stats = {
            "items_completed": self.completed_items,
            "total_items": self.total_items,
            "chars_completed": self.completed_chars,
            "total_chars": self.total_chars,
            "elapsed_seconds": elapsed,
            "elapsed_formatted": self.get_elapsed(),
            "progress_pct": self.get_progress_percentage(),
            "char_progress_pct": self.get_char_progress_percentage(),
            "current_speed": self.current_speed,
            "average_speed": sum(self.speeds) / len(self.speeds) if self.speeds else 0,
            "fastest_speed": self.fastest_speed,
            "slowest_speed": self.slowest_speed if self.slowest_speed != float('inf') else 0,
            "eta_items": self.get_eta_by_items(),
            "eta_chars": self.get_eta_by_chars(),
            "eta_best": self.get_best_eta()
        }
        
        # Estatísticas adicionais
        if self.item_times:
            stats["avg_time_per_item"] = sum(self.item_times) / len(self.item_times)
            stats["fastest_item"] = min(self.item_times)
            stats["slowest_item"] = max(self.item_times)
        
        if elapsed > 0:
            stats["items_per_hour"] = (self.completed_items / elapsed) * 3600
            stats["chars_per_hour"] = (self.completed_chars / elapsed) * 3600
        
        return stats
    
    def get_efficiency_metrics(self) -> dict:
        """
        Calcula métricas de eficiência do processamento.
        
        Returns:
            Dicionário com métricas de eficiência
        """
        if not self.speeds or not self.item_times:
            return {}
        
        # Variabilidade da velocidade
        avg_speed = sum(self.speeds) / len(self.speeds)
        speed_variance = sum((s - avg_speed) ** 2 for s in self.speeds) / len(self.speeds)
        speed_std_dev = speed_variance ** 0.5
        
        # Consistência (menor desvio = mais consistente)
        consistency = max(0, 100 - (speed_std_dev / avg_speed * 100)) if avg_speed > 0 else 0
        
        # Tendência de velocidade (melhorando/piorando)
        if len(self.speeds) >= 3:
            recent_avg = sum(self.speeds[-3:]) / 3
            early_avg = sum(self.speeds[:3]) / 3
            trend = ((recent_avg - early_avg) / early_avg * 100) if early_avg > 0 else 0
        else:
            trend = 0
        
        return {
            "consistency_pct": consistency,
            "speed_variance": speed_variance,
            "speed_trend_pct": trend,
            "avg_speed": avg_speed,
            "speed_stability": "Alta" if consistency > 80 else "Média" if consistency > 60 else "Baixa"
        }
    
    def reset(self) -> None:
        """Reseta o tracker para um novo processamento."""
        self.completed_items = 0
        self.completed_chars = 0
        self.start_time = time.time()
        self.item_start_time = None
        self.speeds.clear()
        self.item_times.clear()
        self.completion_times.clear()
        self.fastest_speed = 0.0
        self.slowest_speed = float('inf')
        self.current_speed = 0.0
    
    def pause(self) -> None:
        """Pausa o tracking (para pausas manuais)."""
        if self.item_start_time:
            # Salva tempo parcial do item atual
            elapsed = time.time() - self.item_start_time
            self.item_start_time = None
    
    def resume(self) -> None:
        """Resume o tracking após uma pausa."""
        if not self.item_start_time:
            self.item_start_time = time.time()
    
    def print_progress_bar(self, width: int = 40) -> None:
        """
        Imprime uma barra de progresso visual.
        
        Args:
            width: Largura da barra em caracteres
        """
        progress = self.get_progress_percentage()
        filled = int(width * progress / 100)
        bar = "█" * filled + "░" * (width - filled)
        print(f"[{bar}] {progress:.1f}%")
    
    def get_summary_line(self) -> str:
        """
        Retorna linha de resumo concisa para exibição contínua.
        
        Returns:
            String com resumo do progresso
        """
        pct = self.get_progress_percentage()
        elapsed = self.get_elapsed()
        eta = self.get_best_eta()
        speed = self.get_average_speed()
        
        return f"📊 {self.completed_items}/{self.total_items} ({pct:.1f}%) | ⏱️ {elapsed} | 🎯 ETA: {eta} | ⚡ {speed}"