"""
src/progress_tracker.py

Classe para rastreamento de progresso com barra visual melhorada e ETA preciso.
"""

import time
import sys
import threading
from datetime import datetime, timedelta
from typing import List


class ProgressTracker:
    """Rastreia progresso e calcula ETA com barra visual avançada e atualização em tempo real."""
    
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
        self.speeds: List[float] = []  # chars/segundo
        self.item_times: List[float] = []  # tempo por item
        self.current_item_name = ""
        self.last_update_time = 0
        self._update_lock = threading.Lock()
        
        # Estado para animação
        self._spinner_chars = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
        self._spinner_index = 0
        
    def start_item(self, item_name: str = "") -> None:
        """Marca início de processamento de um item."""
        with self._update_lock:
            self.item_start_time = time.time()
            self.current_item_name = item_name
            self._show_processing_start()
        
    def complete_item(self, char_count: int) -> None:
        """
        Marca conclusão de um item e atualiza progresso.
        
        Args:
            char_count: Número de caracteres processados neste item
        """
        with self._update_lock:
            if self.item_start_time:
                elapsed = time.time() - self.item_start_time
                if elapsed > 0:
                    speed = char_count / elapsed
                    self.speeds.append(speed)
                    self.item_times.append(elapsed)
                    # Mantém apenas últimas 10 medições
                    if len(self.speeds) > 10:
                        self.speeds.pop(0)
                    if len(self.item_times) > 10:
                        self.item_times.pop(0)
            
            self.completed_items += 1
            self.completed_chars += char_count
            
            # Atualiza barra
            self.update_progress_bar()
    
    def _show_processing_start(self) -> None:
        """Mostra início do processamento de um item."""
        if self.current_item_name:
            display_name = self.current_item_name[:50]
            if len(self.current_item_name) > 50:
                display_name += "..."
            print(f"\n🎙️ [{self.completed_items + 1:03d}/{self.total_items}] {display_name}")
    
    def show_item_progress(self, current_chunk: int = 0, total_chunks: int = 0) -> None:
        """
        Mostra progresso dentro de um item (para chunks grandes).
        
        Args:
            current_chunk: Chunk atual sendo processado
            total_chunks: Total de chunks do item
        """
        if total_chunks > 1:
            chunk_progress = f" (parte {current_chunk}/{total_chunks})"
            spinner = self._spinner_chars[self._spinner_index % len(self._spinner_chars)]
            self._spinner_index += 1
            
            # Atualiza na mesma linha
            print(f"\r    {spinner} Processando{chunk_progress}...", end="", flush=True)
    
    def update_progress_bar(self) -> None:
        """Atualiza barra de progresso visual em tempo real."""
        current_time = time.time()
        
        # Evita atualizações muito frequentes
        if current_time - self.last_update_time < 0.1:
            return
        self.last_update_time = current_time
        
        percentage = (self.completed_items / self.total_items) * 100
        
        # Barra de progresso visual melhorada
        bar_length = 40
        filled_length = int(bar_length * self.completed_items // self.total_items)
        
        # Caracteres de progresso mais elegantes
        filled_char = "█"
        empty_char = "░"
        
        # Mostra posição atual se não completou
        if filled_length < bar_length:
            bar = (filled_char * filled_length + 
                   "▓" +  # Caractere para posição atual
                   empty_char * (bar_length - filled_length - 1))
        else:
            bar = filled_char * bar_length
        
        # Informações de progresso
        elapsed = self.get_elapsed()
        eta = self.get_eta()
        speed = self.get_speed()
        
        # Progresso de caracteres
        if self.total_chars > 0:
            char_progress = f"{self.completed_chars:,}/{self.total_chars:,} chars"
        else:
            char_progress = f"{self.completed_chars:,} chars"
        
        # Linha de progresso completa com cores ANSI
        progress_line = (
            f"\r\033[36m📊 [{bar}] {percentage:5.1f}%\033[0m "
            f"\033[32m({self.completed_items}/{self.total_items})\033[0m | "
            f"\033[33m⏱️ {elapsed}\033[0m | "
            f"\033[35mETA: {eta}\033[0m | "
            f"\033[34m{speed}\033[0m | "
            f"\033[37m{char_progress}\033[0m"
        )
        
        # Escreve linha sem quebra
        sys.stdout.write(progress_line)
        sys.stdout.flush()
        
        # Se completou, adiciona quebra de linha e resumo
        if self.completed_items >= self.total_items:
            print("\n\033[32m✅ Conversão concluída!\033[0m")
    
    def get_eta(self, remaining_chars: int = 0) -> str:
        """Calcula ETA baseado na velocidade média mais precisa."""
        if not self.item_times or self.completed_items == 0:
            return "Calculando..."
        
        remaining_items = self.total_items - self.completed_items
        if remaining_items <= 0:
            return "00:00:00"
        
        # Média ponderada: dá mais peso às medições recentes
        weights = [i + 1 for i in range(len(self.item_times))]
        weighted_avg = sum(t * w for t, w in zip(self.item_times, weights)) / sum(weights)
        
        seconds_remaining = remaining_items * weighted_avg
        
        # Se temos chars restantes e velocidades, usa método duplo
        if remaining_chars > 0 and self.speeds:
            weighted_speed = sum(s * w for s, w in zip(self.speeds, weights)) / sum(weights)
            if weighted_speed > 0:
                seconds_by_chars = remaining_chars / weighted_speed
                # Média dos dois métodos
                seconds_remaining = (seconds_remaining + seconds_by_chars) / 2
        
        # Formata tempo
        if seconds_remaining < 60:
            return f"{int(seconds_remaining)}s"
        elif seconds_remaining < 3600:
            mins = int(seconds_remaining // 60)
            secs = int(seconds_remaining % 60)
            return f"{mins}m{secs:02d}s"
        else:
            hours = int(seconds_remaining // 3600)
            mins = int((seconds_remaining % 3600) // 60)
            return f"{hours}h{mins:02d}m"
    
    def get_speed(self) -> str:
        """Retorna velocidade média formatada com suavização."""
        if not self.speeds:
            return "--- chars/s"
        
        # Média ponderada das velocidades recentes
        if len(self.speeds) > 3:
            recent_speeds = self.speeds[-5:]  # Últimas 5 medições
            avg_speed = sum(recent_speeds) / len(recent_speeds)
        else:
            avg_speed = sum(self.speeds) / len(self.speeds)
        
        if avg_speed >= 10000:
            return f"{avg_speed/1000:.1f}k chars/s"
        elif avg_speed >= 1000:
            return f"{avg_speed/1000:.2f}k chars/s"
        else:
            return f"{int(avg_speed)} chars/s"
    
    def get_elapsed(self) -> str:
        """Retorna tempo decorrido formatado."""
        elapsed = time.time() - self.start_time
        
        if elapsed < 60:
            return f"{int(elapsed)}s"
        elif elapsed < 3600:
            mins = int(elapsed // 60)
            secs = int(elapsed % 60)
            return f"{mins}m{secs:02d}s"
        else:
            hours = int(elapsed // 3600)
            mins = int((elapsed % 3600) // 60)
            return f"{hours}h{mins:02d}m"
    
    def get_detailed_stats(self) -> dict:
        """Retorna estatísticas detalhadas do progresso."""
        return {
            "completed_items": self.completed_items,
            "total_items": self.total_items,
            "completed_chars": self.completed_chars,
            "total_chars": self.total_chars,
            "progress_percentage": (self.completed_items / self.total_items) * 100,
            "elapsed_time": self.get_elapsed(),
            "current_speed": self.get_speed(),
            "eta": self.get_eta(),
            "avg_speed": sum(self.speeds) / len(self.speeds) if self.speeds else 0,
            "items_per_minute": len(self.item_times) / (time.time() - self.start_time) * 60 if self.item_times else 0
        }
    
    def show_chapter_summary(self, chapter_name: str, file_size_mb: float, 
                           duration_estimate: str, processing_time: float) -> None:
        """
        Mostra resumo após completar um capítulo.
        
        Args:
            chapter_name: Nome do capítulo
            file_size_mb: Tamanho do arquivo gerado em MB
            duration_estimate: Duração estimada do áudio
            processing_time: Tempo de processamento em segundos
        """
        print(f"\r    \033[32m✅ {chapter_name}\033[0m")
        print(f"    \033[37m📊 {file_size_mb:.1f}MB | ~{duration_estimate} | "
              f"processado em {processing_time:.1f}s\033[0m")
    
    def show_final_summary(self) -> None:
        """Mostra resumo final detalhado com estatísticas."""
        total_time = time.time() - self.start_time
        
        print(f"\n\033[36m{'='*60}\033[0m")
        print(f"\033[36m🎯 RESUMO FINAL DA CONVERSÃO\033[0m")
        print(f"\033[36m{'='*60}\033[0m")
        
        # Estatísticas básicas
        print(f"\033[32m✅ Capítulos concluídos: {self.completed_items}/{self.total_items}\033[0m")
        print(f"\033[33m⏱️ Tempo total: {self.get_elapsed()}\033[0m")
        print(f"\033[34m📊 Caracteres processados: {self.completed_chars:,}\033[0m")
        
        # Estatísticas de velocidade
        if self.speeds:
            avg_speed = sum(self.speeds) / len(self.speeds)
            max_speed = max(self.speeds)
            print(f"\033[35m⚡ Velocidade média: {int(avg_speed)} chars/s\033[0m")
            print(f"\033[35m🚀 Velocidade máxima: {int(max_speed)} chars/s\033[0m")
        
        if self.item_times:
            avg_time = sum(self.item_times) / len(self.item_times)
            print(f"\033[36m📈 Tempo médio por capítulo: {avg_time:.1f}s\033[0m")
            
            # Eficiência (tempo real de processamento vs tempo total)
            processing_time = sum(self.item_times)
            efficiency = (processing_time / total_time) * 100 if total_time > 0 else 0
            print(f"\033[37m💡 Eficiência: {efficiency:.1f}% (tempo ativo de processamento)\033[0m")
        
        print(f"\033[36m{'='*60}\033[0m")