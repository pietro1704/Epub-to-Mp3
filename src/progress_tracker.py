"""
src/progress_tracker.py

Classe para rastreamento de progresso com barra visual e ETA preciso.
"""

import time
import sys
from datetime import datetime, timedelta
from typing import List


class ProgressTracker:
    """Rastreia progresso e calcula ETA com barra visual para conversão de capítulos."""
    
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
        self.item_times: List[float] = []  # Tempos por item
        
    def start_item(self) -> None:
        """Marca início de processamento de um item."""
        self.item_start_time = time.time()
        
    def complete_item(self, char_count: int) -> None:
        """
        Marca conclusão de um item e atualiza barra de progresso.
        
        Args:
            char_count: Número de caracteres processados neste item
        """
        if self.item_start_time:
            elapsed = time.time() - self.item_start_time
            if elapsed > 0:
                speed = char_count / elapsed
                self.speeds.append(speed)
                self.item_times.append(elapsed)
                # Mantém apenas últimas 5 velocidades para média móvel
                if len(self.speeds) > 5:
                    self.speeds.pop(0)
                if len(self.item_times) > 5:
                    self.item_times.pop(0)
        
        self.completed_items += 1
        self.completed_chars += char_count
        
        # Atualiza barra de progresso
        self.update_progress_bar()
        
    def update_progress_bar(self) -> None:
        """Atualiza barra de progresso visual em tempo real."""
        percentage = (self.completed_items / self.total_items) * 100
        
        # Barra de progresso visual
        bar_length = 30
        filled_length = int(bar_length * self.completed_items // self.total_items)
        bar = '█' * filled_length + '░' * (bar_length - filled_length)
        
        # Informações de progresso
        elapsed = self.get_elapsed()
        eta = self.get_eta()
        speed = self.get_speed()
        
        # Linha de progresso completa
        progress_line = (
            f"\r📊 [{bar}] {percentage:5.1f}% "
            f"({self.completed_items}/{self.total_items}) | "
            f"⏱️ {elapsed} | ETA: {eta} | {speed}"
        )
        
        # Escreve linha sem quebra
        sys.stdout.write(progress_line)
        sys.stdout.flush()
        
        # Se completou, adiciona quebra de linha
        if self.completed_items >= self.total_items:
            print()  # Nova linha após completar
    
    def get_eta(self, remaining_chars: int = 0) -> str:
        """
        Calcula ETA baseado na velocidade média.
        
        Args:
            remaining_chars: Caracteres restantes para processamento mais preciso
            
        Returns:
            String formatada com o ETA (HH:MM:SS)
        """
        if not self.item_times:
            return "Calculando..."
        
        # Usa média das últimas execuções para ETA mais preciso
        avg_time_per_item = sum(self.item_times) / len(self.item_times)
        remaining_items = self.total_items - self.completed_items
        
        if remaining_items <= 0:
            return "00:00:00"
        
        seconds_remaining = remaining_items * avg_time_per_item
        
        # Se temos chars restantes, usa velocidade também
        if remaining_chars > 0 and self.speeds:
            avg_speed = sum(self.speeds) / len(self.speeds)
            seconds_by_chars = remaining_chars / avg_speed
            # Média ponderada entre os dois métodos
            seconds_remaining = (seconds_remaining + seconds_by_chars) / 2
        
        eta = datetime.now() + timedelta(seconds=seconds_remaining)
        return eta.strftime("%H:%M:%S")
    
    def get_speed(self) -> str:
        """
        Retorna velocidade média formatada.
        
        Returns:
            String com velocidade em chars/s
        """
        if not self.speeds:
            return "--- chars/s"
        
        avg_speed = sum(self.speeds) / len(self.speeds)
        if avg_speed >= 1000:
            return f"{avg_speed/1000:.1f}k chars/s"
        else:
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
            return f"{hours}h{minutes:02d}m{seconds:02d}s"
        elif minutes > 0:
            return f"{minutes}m{seconds:02d}s"
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
    
    def get_detailed_stats(self) -> dict:
        """
        Retorna estatísticas detalhadas do progresso.
        
        Returns:
            Dicionário com todas as estatísticas
        """
        remaining_chars = sum(
            len(ch[1]) for ch in getattr(self, 'chapters', [])
            if hasattr(self, 'chapters')
        ) if hasattr(self, 'chapters') else 0
        
        return {
            "completed_items": self.completed_items,
            "total_items": self.total_items,
            "completed_chars": self.completed_chars,
            "total_chars": self.total_chars,
            "progress_percentage": self.get_progress_percentage(),
            "elapsed_time": self.get_elapsed(),
            "current_speed": self.get_speed(),
            "eta": self.get_eta(remaining_chars),
            "avg_speed": sum(self.speeds) / len(self.speeds) if self.speeds else 0,
            "estimated_total_time": self._estimate_total_time()
        }
    
    def _estimate_total_time(self) -> str:
        """Estima tempo total baseado no progresso atual."""
        if self.completed_items == 0:
            return "Calculando..."
        
        elapsed = time.time() - self.start_time
        estimated_total = elapsed * (self.total_items / self.completed_items)
        
        hours = int(estimated_total // 3600)
        minutes = int((estimated_total % 3600) // 60)
        seconds = int(estimated_total % 60)
        
        if hours > 0:
            return f"{hours}h{minutes:02d}m{seconds:02d}s"
        elif minutes > 0:
            return f"{minutes}m{seconds:02d}s"
        else:
            return f"{seconds}s"
    
    def show_final_summary(self) -> None:
        """Mostra resumo final detalhado."""
        print(f"\n🎯 RESUMO FINAL:")
        print(f"   ✅ Concluído: {self.completed_items}/{self.total_items} capítulos")
        print(f"   ⏱️ Tempo total: {self.get_elapsed()}")
        print(f"   📊 Caracteres processados: {self.completed_chars:,}")
        
        if self.speeds:
            avg_speed = sum(self.speeds) / len(self.speeds)
            print(f"   ⚡ Velocidade média: {avg_speed:.0f} chars/s")
        
        if self.item_times:
            avg_time = sum(self.item_times) / len(self.item_times)
            print(f"   📈 Tempo médio por capítulo: {avg_time:.1f}s")
    
    def reset(self) -> None:
        """Reseta o tracker para um novo processamento."""
        self.completed_items = 0
        self.completed_chars = 0
        self.start_time = time.time()
        self.item_start_time = None
        self.speeds.clear()
        self.item_times.clear()
        
    def print_chapter_start(self, idx: int, title: str, char_count: int) -> None:
        """
        Imprime informações do início do capítulo com estimativas.
        
        Args:
            idx: Índice do capítulo
            title: Título do capítulo
            char_count: Número de caracteres
        """
        display_title = title[:40] + ('...' if len(title) > 40 else '')
        
        print(f"\n🎙️ [{idx:03d}/{self.total_items}] {display_title}")
        print(f"    📝 {char_count:,} caracteres", end="")
        
        # Estima tempo baseado em histórico
        if self.item_times:
            avg_time = sum(self.item_times) / len(self.item_times)
            estimated_time = char_count / (sum(self.speeds) / len(self.speeds)) if self.speeds else avg_time
            print(f" | ~{estimated_time:.0f}s estimado")
        else:
            print(" | primeira execução")
        
        # Mostra progresso geral se não for o primeiro
        if self.completed_items > 0:
            self.update_progress_bar()