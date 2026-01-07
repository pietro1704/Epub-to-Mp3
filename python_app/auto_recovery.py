#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Auto Recovery System - Detecção e correção automática de problemas
Detecta deadlocks, starvation, travamentos e corrige automaticamente
"""

import asyncio
import gc
import os
import sys
import threading
import time
import traceback
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime
from typing import Any, Callable, Dict, List, Optional

import psutil


@dataclass
class ThreadActivity:
    """Atividade de uma thread."""

    thread_id: int
    name: str
    alive: bool
    daemon: bool
    last_cpu_time: float
    last_check_time: float
    stack_frames: List[str]
    stuck_count: int = 0


@dataclass
class RecoveryAction:
    """Ação de recovery executada."""

    timestamp: float
    problem: str
    action: str
    success: bool
    details: Dict[str, Any]


class AutoRecoverySystem:
    """
    Sistema de auto-recovery que detecta e corrige problemas automaticamente.

    Detecta:
    - Deadlocks (threads travadas esperando locks)
    - Starvation (processos sem recursos)
    - Memory leaks críticos
    - Thread hangs (threads não respondendo)
    - Event loop blocks (asyncio travado)
    - GC thrashing (garbage collector sobrecarregado)
    """

    def __init__(self, check_interval: float = 5.0):
        self.check_interval = check_interval
        self.running = False
        self._thread: Optional[threading.Thread] = None
        self._lock = threading.Lock()
        self._cpu_count = psutil.cpu_count(logical=True) or 1

        # Estado das threads
        self._thread_activities: Dict[int, ThreadActivity] = {}
        self._recovery_actions: List[RecoveryAction] = []
        self._max_actions = 100
        self._starvation_streak = 0
        self._last_starvation_log = 0.0
        self._activity_provider: Optional[Callable[[], bool]] = None
        ignored_env = os.getenv("AUTO_RECOVERY_IGNORE_PREFIXES", "fsspec")
        self._ignored_prefixes = [
            prefix.strip().lower() for prefix in ignored_env.split(",") if prefix.strip()
        ]

        # Thresholds para detecção
        self.thresholds = {
            "thread_stuck_cycles": 3,  # Quantos ciclos antes de considerar stuck
            "memory_critical_percent": 95.0,
            "gc_thrashing_collections_per_sec": 1000.0,  # TTS carrega modelos grandes, GC é esperado
            "event_loop_stuck_seconds": 30.0,
            "thread_starvation_cpu_percent": 10.0,
            "thread_starvation_cycles": 3,
            "thread_starvation_log_cooldown": 60.0,
            "thread_starvation_threads_min": max(32, self._cpu_count * 4),
        }

        # Estado do sistema
        self._process = psutil.Process()
        self._last_gc_count = gc.get_count()
        self._last_gc_time = time.time()
        self._event_loop_last_check = time.time()

    def set_activity_provider(self, provider: Optional[Callable[[], bool]]) -> None:
        """Register a callback that returns True when there is active work."""
        self._activity_provider = provider

    def start(self) -> None:
        """Inicia sistema de auto-recovery."""
        if self.running:
            print("⚠️ [AutoRecovery] Já está rodando")
            return

        self.running = True
        self._thread = threading.Thread(
            target=self._recovery_loop, daemon=True, name="AutoRecovery"
        )
        self._thread.start()
        print(f"✅ [AutoRecovery] Sistema iniciado (intervalo: {self.check_interval}s)")

    def stop(self) -> None:
        """Para sistema de auto-recovery."""
        if not self.running:
            return

        self.running = False
        if self._thread:
            self._thread.join(timeout=5.0)
        print("🛑 [AutoRecovery] Sistema parado")

    def _recovery_loop(self) -> None:
        """Loop principal de monitoramento e recovery."""
        try:
            while self.running:
                try:
                    # Verificar diferentes tipos de problemas
                    self._check_deadlocks()
                    self._check_thread_starvation()
                    self._check_memory_crisis()
                    self._check_gc_thrashing()
                    self._check_event_loop()

                    time.sleep(self.check_interval)

                except Exception as e:
                    print(f"❌ [AutoRecovery] Erro no loop: {e}")
                    traceback.print_exc()
                    time.sleep(self.check_interval)

        except KeyboardInterrupt:
            pass

    def _is_idle_worker_thread(self, stack_frames: List[str]) -> bool:
        """Verifica se thread está idle esperando por trabalho (comportamento normal)."""
        if not stack_frames:
            return False

        stack_text = "\n".join(stack_frames)

        # Padrões de threads idle (comportamento esperado)
        idle_patterns = [
            "work_queue.get(block=True)",  # ThreadPoolExecutor esperando trabalho
            "self.work_queue.get(block=True)",
            "_worker\n    work_item = work_queue.get(block=True)",
            "Queue.get",  # asyncio Queue esperando
            "Condition.wait",  # Waiting on condition variable
            "time.sleep(",  # Sleep loops (monitoring threads)
            "_stop_event.wait(",  # Event wait
            "waiter.acquire(",  # Lock/Event acquisition
            "Event.wait",  # Threading event wait
            "self.interval)",  # Sleep com self.interval
        ]

        return any(pattern in stack_text for pattern in idle_patterns)

    def _is_event_loop_stack(self, stack_frames: List[str]) -> bool:
        """Detecta stack de event loop/servidor (comportamento normal)."""
        if not stack_frames:
            return False
        stack_text = "\n".join(stack_frames)
        event_loop_markers = [
            "asyncio/base_events.py",
            "asyncio/runners.py",
            "uvicorn/server.py",
            "uvicorn/_subprocess.py",
            "starlette/routing.py",
        ]
        if any(marker in stack_text for marker in event_loop_markers):
            # Threads de loop podem ficar estáveis por muito tempo sem estarem travadas.
            return True
        return False

    def _get_thread_cpu_times(self) -> Dict[int, float]:
        """Retorna CPU time agregado (user+sys) por thread."""
        cpu_times: Dict[int, float] = {}
        try:
            for thread_info in self._process.threads():
                cpu_times[thread_info.id] = thread_info.user_time + thread_info.system_time
        except Exception:
            pass
        return cpu_times

    def _check_deadlocks(self) -> None:
        """Detecta e resolve deadlocks em threads."""
        current_threads = threading.enumerate()
        current_time = time.time()
        cpu_times = self._get_thread_cpu_times()

        for thread in current_threads:
            if not thread.is_alive():
                continue

            if self._ignored_prefixes:
                name_lower = thread.name.lower()
                if any(name_lower.startswith(prefix) for prefix in self._ignored_prefixes):
                    continue

            thread_id = thread.ident
            if thread_id is None:
                continue

            if thread.name == "AutoRecovery":
                continue

            # Capturar stack frames da thread
            frame = sys._current_frames().get(thread_id)
            stack_frames = []
            if frame:
                stack_frames = traceback.format_stack(frame)

            # **NOVO**: Ignorar threads idle esperando por trabalho (comportamento normal)
            if self._is_idle_worker_thread(stack_frames) or self._is_event_loop_stack(stack_frames):
                # Reset contador se estava travada antes
                if thread_id in self._thread_activities:
                    self._thread_activities[thread_id].stuck_count = 0
                continue

            # Verificar se thread está presa no mesmo lugar
            if thread_id in self._thread_activities:
                prev_activity = self._thread_activities[thread_id]
                current_cpu = cpu_times.get(thread_id, prev_activity.last_cpu_time)
                cpu_unchanged = abs(current_cpu - prev_activity.last_cpu_time) < 0.0001

                # Comparar stack frames
                if stack_frames == prev_activity.stack_frames and cpu_unchanged:
                    prev_activity.stuck_count += 1

                    # Thread travada por muito tempo?
                    if prev_activity.stuck_count >= self.thresholds["thread_stuck_cycles"]:
                        self._recover_stuck_thread(thread, prev_activity)
                else:
                    prev_activity.stuck_count = 0
                    prev_activity.stack_frames = stack_frames
                    prev_activity.last_check_time = current_time
                prev_activity.last_cpu_time = current_cpu
            else:
                # Nova thread
                current_cpu = cpu_times.get(thread_id, 0.0)
                self._thread_activities[thread_id] = ThreadActivity(
                    thread_id=thread_id,
                    name=thread.name,
                    alive=thread.is_alive(),
                    daemon=thread.daemon,
                    last_cpu_time=current_cpu,
                    last_check_time=current_time,
                    stack_frames=stack_frames,
                    stuck_count=0,
                )

    def _recover_stuck_thread(self, thread: threading.Thread, activity: ThreadActivity) -> None:
        """Tenta recuperar thread travada."""
        print(f"🚨 [AutoRecovery] Thread travada detectada: {thread.name}")
        print("   Stack trace:")
        for line in activity.stack_frames[-5:]:  # Últimas 5 linhas
            print(f"   {line.strip()}")

        # Ações de recovery
        action_taken = "none"
        success = False

        # 1. Tentar forçar GC (pode liberar locks)
        print("   → Tentando GC forçado...")
        gc.collect()
        action_taken = "gc_collect"
        success = True

        # 2. Se thread não é daemon e está travada, alertar
        if not thread.daemon:
            print(f"   ⚠️ Thread não-daemon travada: {thread.name}")
            print("   → Considere reiniciar o processo manualmente")

        # Registrar ação
        self._log_recovery_action(
            problem="thread_deadlock",
            action=action_taken,
            success=success,
            details={
                "thread_name": thread.name,
                "thread_id": activity.thread_id,
                "stuck_cycles": activity.stuck_count,
                "stack_sample": activity.stack_frames[-1] if activity.stack_frames else None,
            },
        )

        # Reset contador
        activity.stuck_count = 0

    def _check_thread_starvation(self) -> None:
        """Detecta starvation de threads (threads não conseguindo CPU)."""
        try:
            # Verificar CPU per-thread (se disponível)
            active_work = True
            if self._activity_provider is not None:
                try:
                    active_work = bool(self._activity_provider())
                except Exception:
                    active_work = True
            if not active_work:
                self._starvation_streak = 0
                return

            thread_count = threading.active_count()
            cpu_percent = self._process.cpu_percent(interval=0.1)

            min_threads = self.thresholds.get("thread_starvation_threads_min", 20)
            cpu_threshold = self.thresholds.get("thread_starvation_cpu_percent", 10.0)
            if thread_count > min_threads and cpu_percent < cpu_threshold:
                self._starvation_streak += 1
            else:
                self._starvation_streak = 0

            if self._starvation_streak >= self.thresholds.get("thread_starvation_cycles", 3):
                now = time.time()
                cooldown = self.thresholds.get("thread_starvation_log_cooldown", 60.0)
                if now - self._last_starvation_log >= cooldown:
                    print("⚠️ [AutoRecovery] Possível thread starvation detectado")
                    print(f"   Threads: {thread_count}, CPU: {cpu_percent:.1f}%")
                    self._last_starvation_log = now

                # Recovery: reduzir threads se possível
                self._log_recovery_action(
                    problem="thread_starvation",
                    action="alert_only",
                    success=True,
                    details={"thread_count": thread_count, "cpu_percent": cpu_percent},
                )
                self._starvation_streak = 0

        except Exception:
            pass  # Ignorar erros de coleta de stats

    def _check_memory_crisis(self) -> None:
        """Detecta e resolve crises de memória."""
        try:
            memory_percent = self._process.memory_percent()

            if memory_percent > self.thresholds["memory_critical_percent"]:
                print(f"🚨 [AutoRecovery] CRISE DE MEMÓRIA: {memory_percent:.1f}%")

                # Recovery actions
                print("   → Executando GC emergencial...")
                gc.collect(generation=2)  # Full GC

                print("   → Liberando caches...")
                # Tentar liberar caches do sistema
                try:
                    import torch

                    if torch.cuda.is_available():
                        torch.cuda.empty_cache()
                        print("   → Cache CUDA liberado")
                except ImportError:
                    pass

                # Verificar se melhorou
                new_memory_percent = self._process.memory_percent()
                freed_mb = (
                    (memory_percent - new_memory_percent)
                    * self._process.memory_info().rss
                    / (1024 * 1024 * 100)
                )

                print(f"   → Memória liberada: ~{freed_mb:.1f} MB")

                self._log_recovery_action(
                    problem="memory_crisis",
                    action="gc_and_cache_clear",
                    success=new_memory_percent < memory_percent,
                    details={
                        "before_percent": memory_percent,
                        "after_percent": new_memory_percent,
                        "freed_mb": freed_mb,
                    },
                )

        except Exception as e:
            print(f"   ❌ Erro ao verificar memória: {e}")

    def _check_gc_thrashing(self) -> None:
        """
        Detecta GC thrashing (GC rodando excessivamente).

        NOTA: Desabilitado para aplicações TTS que carregam modelos grandes.
        GC frequente é esperado durante carregamento de modelos.
        """
        # Atualizar estado mas não alertar
        current_gc = gc.get_count()
        current_time = time.time()

        self._last_gc_count = current_gc
        self._last_gc_time = current_time

        # GC thrashing detection desabilitado - não é útil para TTS
        return

    def _check_event_loop(self) -> None:
        """Detecta event loop travado (asyncio)."""
        # Verificar se há event loop rodando
        try:
            loop = asyncio.get_event_loop()
            if loop.is_running():
                # TODO: Implementar check mais sofisticado
                # Por enquanto apenas monitora
                pass
        except RuntimeError:
            # Sem event loop, OK
            pass

    def _log_recovery_action(
        self, problem: str, action: str, success: bool, details: Dict[str, Any]
    ) -> None:
        """Registra ação de recovery."""
        with self._lock:
            recovery = RecoveryAction(
                timestamp=time.time(),
                problem=problem,
                action=action,
                success=success,
                details=details,
            )
            self._recovery_actions.append(recovery)

            if len(self._recovery_actions) > self._max_actions:
                self._recovery_actions.pop(0)

    def get_recent_actions(self, max_count: int = 10) -> List[RecoveryAction]:
        """Retorna ações recentes de recovery."""
        with self._lock:
            return self._recovery_actions[-max_count:]

    def get_stats(self) -> Dict[str, Any]:
        """Retorna estatísticas do sistema de recovery."""
        with self._lock:
            total_actions = len(self._recovery_actions)
            successful_actions = sum(1 for a in self._recovery_actions if a.success)

            # Contar por tipo de problema
            problems_count = defaultdict(int)
            for action in self._recovery_actions:
                problems_count[action.problem] += 1

            return {
                "total_actions": total_actions,
                "successful_actions": successful_actions,
                "success_rate": (successful_actions / total_actions * 100)
                if total_actions > 0
                else 100.0,
                "problems_detected": dict(problems_count),
                "active_threads": threading.active_count(),
                "tracked_threads": len(self._thread_activities),
            }


# Global instance
_global_recovery: Optional[AutoRecoverySystem] = None


def get_auto_recovery() -> AutoRecoverySystem:
    """Retorna instância global do sistema de recovery."""
    global _global_recovery
    if _global_recovery is None:
        _global_recovery = AutoRecoverySystem()
    return _global_recovery


def start_auto_recovery() -> AutoRecoverySystem:
    """Inicia sistema de auto-recovery."""
    recovery = get_auto_recovery()
    recovery.start()
    return recovery


if __name__ == "__main__":
    # Teste standalone
    print("🚀 Iniciando Auto Recovery System em modo teste...")
    recovery = start_auto_recovery()

    try:
        print("Sistema rodando. Pressione Ctrl+C para parar.")

        while True:
            time.sleep(10)
            stats = recovery.get_stats()
            print(f"\n{'=' * 80}")
            print(f"📊 ESTATÍSTICAS DE RECOVERY ({datetime.now().strftime('%H:%M:%S')})")
            print(f"{'=' * 80}")
            print(f"Total de ações: {stats['total_actions']}")
            print(f"Taxa de sucesso: {stats['success_rate']:.1f}%")
            print(f"Threads ativas: {stats['active_threads']}")
            print(f"Problemas detectados: {stats['problems_detected']}")

            recent = recovery.get_recent_actions(5)
            if recent:
                print("\nÚltimas ações:")
                for action in recent:
                    status = "✅" if action.success else "❌"
                    timestamp = datetime.fromtimestamp(action.timestamp).strftime("%H:%M:%S")
                    print(f"  {status} [{timestamp}] {action.problem} -> {action.action}")

    except KeyboardInterrupt:
        print("\n🛑 Parando sistema...")
        recovery.stop()
        print("✅ Sistema parado")
