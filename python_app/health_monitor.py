#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Health Monitor - Sistema automático de monitoramento de performance e estabilidade
Roda em background e alerta sobre problemas automaticamente
"""

import gc
import json
import threading
import time
import traceback
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional


@dataclass
class HealthAlert:
    """Alerta de saúde do sistema."""

    timestamp: float
    severity: str  # 'info', 'warning', 'critical'
    category: str  # 'memory', 'gpu', 'cpu', 'disk', 'heap'
    message: str
    details: Dict[str, Any]


@dataclass
class HealthSnapshot:
    """Snapshot de saúde do sistema."""

    timestamp: float
    cpu_percent: float
    memory_percent: float
    memory_mb: float
    gpu_available: bool
    gpu_memory_used_mb: float
    gpu_memory_total_mb: float
    gpu_utilization: float
    heap_status: str  # 'healthy', 'warning', 'critical'
    gc_collections: Dict[str, int]
    thread_count: int
    alerts: List[HealthAlert]


class HealthMonitor:
    """
    Monitor de saúde automático que roda em background.

    Features:
    - Detecta heap corruption antes de crashar
    - Monitora uso de GPU em tempo real
    - Alerta sobre memory leaks
    - Tracking de performance degradation
    """

    def __init__(self, interval_seconds: float = 2.0):
        self.interval = interval_seconds
        self.running = False
        self._thread: Optional[threading.Thread] = None
        self._snapshots: List[HealthSnapshot] = []
        self._alerts: List[HealthAlert] = []
        self._max_snapshots = 1000  # Últimos ~30min com interval=2s
        self._max_alerts = 500
        self._start_time = time.time()
        self._last_leak_alert_ts: Optional[float] = None

        # Thresholds para alertas
        self.thresholds = {
            "memory_warning": 85.0,  # %
            "memory_critical": 95.0,
            "gpu_memory_warning": 85.0,
            "gpu_memory_critical": 95.0,
            "heap_growth_rate_mb_per_min": 2000.0,  # 2GB/min = leak suspeito (TTS carrega modelos grandes)
            # Ignora crescimento inicial enquanto modelos pesados carregam
            "leak_warmup_seconds": 180.0,
            # Evita flood de alerts repetidos enquanto investiga
            "leak_alert_cooldown_seconds": 120.0,
        }

        # Baseline inicial
        self._baseline_memory_mb: Optional[float] = None
        self._last_gc_collections = gc.get_count()

        # Lock para thread safety
        self._lock = threading.Lock()

    def start(self) -> None:
        """Inicia monitoramento em background."""
        if self.running:
            print("⚠️ [HealthMonitor] Já está rodando")
            return

        self.running = True
        self._thread = threading.Thread(
            target=self._monitor_loop, daemon=True, name="HealthMonitor"
        )
        self._thread.start()
        print(f"✅ [HealthMonitor] Iniciado (intervalo: {self.interval}s)")

    def stop(self) -> None:
        """Para monitoramento."""
        if not self.running:
            return

        self.running = False
        if self._thread:
            self._thread.join(timeout=5.0)
        print("🛑 [HealthMonitor] Parado")

    def _monitor_loop(self) -> None:
        """Loop principal de monitoramento."""
        try:
            while self.running:
                try:
                    snapshot = self._collect_snapshot()

                    with self._lock:
                        self._snapshots.append(snapshot)
                        if len(self._snapshots) > self._max_snapshots:
                            self._snapshots.pop(0)

                        # Adicionar alertas do snapshot
                        for alert in snapshot.alerts:
                            self._alerts.append(alert)
                            self._print_alert(alert)

                        if len(self._alerts) > self._max_alerts:
                            self._alerts = self._alerts[-self._max_alerts :]

                    time.sleep(self.interval)

                except Exception as e:
                    print(f"❌ [HealthMonitor] Erro no loop: {e}")
                    traceback.print_exc()
                    time.sleep(self.interval)

        except KeyboardInterrupt:
            pass

    def _collect_snapshot(self) -> HealthSnapshot:
        """Coleta snapshot de saúde atual."""
        alerts: List[HealthAlert] = []

        # CPU e Memory básicos
        try:
            import psutil

            process = psutil.Process()

            cpu_percent = process.cpu_percent(interval=0.1)
            mem_info = process.memory_info()
            memory_mb = mem_info.rss / (1024 * 1024)
            memory_percent = process.memory_percent()

            # Baseline
            if self._baseline_memory_mb is None:
                self._baseline_memory_mb = memory_mb

        except ImportError:
            cpu_percent = 0.0
            memory_mb = 0.0
            memory_percent = 0.0

        # GPU Status
        gpu_available = False
        gpu_memory_used_mb = 0.0
        gpu_memory_total_mb = 0.0
        gpu_utilization = 0.0

        try:
            import torch

            if torch.cuda.is_available():
                gpu_available = True
                gpu_memory_used_mb = torch.cuda.memory_allocated(0) / (1024 * 1024)
                gpu_memory_total_mb = torch.cuda.get_device_properties(0).total_memory / (
                    1024 * 1024
                )

                if gpu_memory_total_mb > 0:
                    gpu_utilization = (gpu_memory_used_mb / gpu_memory_total_mb) * 100

                    # Alertas GPU
                    if gpu_utilization > self.thresholds["gpu_memory_critical"]:
                        alerts.append(
                            HealthAlert(
                                timestamp=time.time(),
                                severity="critical",
                                category="gpu",
                                message=f"GPU memory crítica: {gpu_utilization:.1f}%",
                                details={
                                    "used_mb": gpu_memory_used_mb,
                                    "total_mb": gpu_memory_total_mb,
                                },
                            )
                        )
                    elif gpu_utilization > self.thresholds["gpu_memory_warning"]:
                        alerts.append(
                            HealthAlert(
                                timestamp=time.time(),
                                severity="warning",
                                category="gpu",
                                message=f"GPU memory alta: {gpu_utilization:.1f}%",
                                details={
                                    "used_mb": gpu_memory_used_mb,
                                    "total_mb": gpu_memory_total_mb,
                                },
                            )
                        )
        except ImportError:
            pass

        # Heap Status
        heap_status = "healthy"
        gc_collections = {f"gen{i}": count for i, count in enumerate(gc.get_count())}

        # Detectar heap corruption ou memory leak
        if memory_percent > self.thresholds["memory_critical"]:
            heap_status = "critical"
            alerts.append(
                HealthAlert(
                    timestamp=time.time(),
                    severity="critical",
                    category="heap",
                    message=f"HEAP CRÍTICO: {memory_percent:.1f}% memória usada",
                    details={"memory_mb": memory_mb, "memory_percent": memory_percent},
                )
            )
        elif memory_percent > self.thresholds["memory_warning"]:
            heap_status = "warning"
            alerts.append(
                HealthAlert(
                    timestamp=time.time(),
                    severity="warning",
                    category="memory",
                    message=f"Memória alta: {memory_percent:.1f}%",
                    details={"memory_mb": memory_mb},
                )
            )

        # Detectar memory leak (crescimento rápido)
        if (
            self._baseline_memory_mb
            and len(self._snapshots) > 30
            and (time.time() - self._start_time) > self.thresholds["leak_warmup_seconds"]
        ):
            # Últimos 60s (30 snapshots * 2s)
            recent_snapshots = self._snapshots[-30:]
            if recent_snapshots:
                old_memory = recent_snapshots[0].memory_mb
                growth_mb = memory_mb - old_memory
                time_diff_min = (len(recent_snapshots) * self.interval) / 60.0

                if time_diff_min > 0:
                    growth_rate = growth_mb / time_diff_min

                    if growth_rate > self.thresholds["heap_growth_rate_mb_per_min"]:
                        now = time.time()
                        last_alert = self._last_leak_alert_ts
                        if (
                            last_alert is None
                            or (now - last_alert) > self.thresholds["leak_alert_cooldown_seconds"]
                        ):
                            heap_status = "warning"
                            alerts.append(
                                HealthAlert(
                                    timestamp=now,
                                    severity="warning",
                                    category="heap",
                                    message=f"Memory leak detectado: +{growth_rate:.1f} MB/min",
                                    details={
                                        "growth_mb": growth_mb,
                                        "growth_rate_mb_per_min": growth_rate,
                                        "current_mb": memory_mb,
                                    },
                                )
                            )
                            self._last_leak_alert_ts = now

        # Thread count
        thread_count = threading.active_count()

        return HealthSnapshot(
            timestamp=time.time(),
            cpu_percent=cpu_percent,
            memory_percent=memory_percent,
            memory_mb=memory_mb,
            gpu_available=gpu_available,
            gpu_memory_used_mb=gpu_memory_used_mb,
            gpu_memory_total_mb=gpu_memory_total_mb,
            gpu_utilization=gpu_utilization,
            heap_status=heap_status,
            gc_collections=gc_collections,
            thread_count=thread_count,
            alerts=alerts,
        )

    def _print_alert(self, alert: HealthAlert) -> None:
        """Imprime alerta com formatação."""
        timestamp = datetime.fromtimestamp(alert.timestamp).strftime("%H:%M:%S")

        severity_icons = {"info": "ℹ️", "warning": "⚠️", "critical": "🚨"}

        icon = severity_icons.get(alert.severity, "❓")

        print(f"{icon} [{timestamp}] [{alert.category.upper()}] {alert.message}")

        if alert.severity == "critical":
            print(f"   Detalhes: {json.dumps(alert.details, indent=2)}")

    def get_latest_snapshot(self) -> Optional[HealthSnapshot]:
        """Retorna snapshot mais recente."""
        with self._lock:
            return self._snapshots[-1] if self._snapshots else None

    def get_recent_alerts(self, max_count: int = 10) -> List[HealthAlert]:
        """Retorna alertas recentes."""
        with self._lock:
            return self._alerts[-max_count:]

    def get_stats_summary(self) -> Dict[str, Any]:
        """Retorna sumário de estatísticas."""
        with self._lock:
            if not self._snapshots:
                return {}

            latest = self._snapshots[-1]

            # Médias dos últimos 30 snapshots
            recent = self._snapshots[-30:]
            avg_cpu = sum(s.cpu_percent for s in recent) / len(recent)
            avg_memory = sum(s.memory_mb for s in recent) / len(recent)

            return {
                "timestamp": latest.timestamp,
                "uptime_seconds": time.time() - self._snapshots[0].timestamp
                if self._snapshots
                else 0,
                "current": {
                    "cpu_percent": latest.cpu_percent,
                    "memory_mb": latest.memory_mb,
                    "memory_percent": latest.memory_percent,
                    "gpu_utilization": latest.gpu_utilization if latest.gpu_available else None,
                    "heap_status": latest.heap_status,
                    "thread_count": latest.thread_count,
                },
                "averages_last_60s": {
                    "cpu_percent": avg_cpu,
                    "memory_mb": avg_memory,
                },
                "total_alerts": len(self._alerts),
                "critical_alerts": sum(1 for a in self._alerts if a.severity == "critical"),
                "warning_alerts": sum(1 for a in self._alerts if a.severity == "warning"),
            }

    def export_report(self, output_path: Path) -> None:
        """Exporta relatório completo para arquivo."""
        with self._lock:
            report = {
                "generated_at": datetime.now().isoformat(),
                "summary": self.get_stats_summary(),
                "recent_alerts": [
                    {
                        "timestamp": datetime.fromtimestamp(a.timestamp).isoformat(),
                        "severity": a.severity,
                        "category": a.category,
                        "message": a.message,
                        "details": a.details,
                    }
                    for a in self._alerts[-100:]
                ],
                "snapshots_count": len(self._snapshots),
            }

        output_path.write_text(json.dumps(report, indent=2))
        print(f"📊 [HealthMonitor] Relatório exportado: {output_path}")


# Global monitor instance
_global_monitor: Optional[HealthMonitor] = None


def get_health_monitor() -> HealthMonitor:
    """Retorna instância global do monitor."""
    global _global_monitor
    if _global_monitor is None:
        _global_monitor = HealthMonitor()
    return _global_monitor


def start_monitoring() -> HealthMonitor:
    """Inicia monitoramento automático."""
    monitor = get_health_monitor()
    monitor.start()
    return monitor


if __name__ == "__main__":
    # Teste standalone
    print("🚀 Iniciando Health Monitor em modo teste...")
    monitor = start_monitoring()

    try:
        print("Monitor rodando. Pressione Ctrl+C para parar.")
        print("Dashboard: http://localhost:8000/api/health/dashboard")

        while True:
            time.sleep(10)
            summary = monitor.get_stats_summary()
            print(f"\n{'=' * 80}")
            print(f"📊 RESUMO ({datetime.now().strftime('%H:%M:%S')})")
            print(f"{'=' * 80}")
            print(json.dumps(summary, indent=2))

    except KeyboardInterrupt:
        print("\n🛑 Parando monitor...")
        monitor.stop()

        # Exportar relatório final
        report_path = Path("health_report.json")
        monitor.export_report(report_path)
        print(f"✅ Relatório salvo em: {report_path}")


# Compatibility adapter for server.py
class SystemMonitorAdapter:
    """Adapter to make HealthMonitor compatible with old system_monitor API."""

    def __init__(self, health_monitor):
        self._health_monitor = health_monitor

    def latest(self):
        """Compatibility method that returns snapshot in old format."""
        snapshot = self._health_monitor.get_latest_snapshot()
        if not snapshot:
            return {}

        # Convert to old format
        return {
            "cpu": {
                "percent": snapshot.cpu_percent,
                "count": snapshot.cpu_count,
            },
            "memory": {
                "percent": snapshot.memory_percent,
                "available": snapshot.memory_available_gb * 1024 * 1024 * 1024,  # Convert to bytes
                "total": snapshot.memory_total_gb * 1024 * 1024 * 1024,
            },
            "disk": {
                "percent": getattr(snapshot, "disk_percent", 0),
            },
        }

    def start(self):
        """Start monitoring."""
        self._health_monitor.start()


def get_system_monitor_adapter():
    """Get adapter for backwards compatibility."""
    return SystemMonitorAdapter(get_health_monitor())
