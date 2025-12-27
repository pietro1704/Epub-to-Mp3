import json
import os
import shutil
import subprocess
import threading
import time
from typing import Any, Dict, List, Optional

import psutil


def _read_first(output: Optional[str]) -> Optional[str]:
    if not output:
        return None
    return output.strip().splitlines()[0] if output.strip() else None


class SystemMonitor:
    """Collects CPU, memory, disk, network and GPU usage."""

    def __init__(self, interval_seconds: float = 2.0) -> None:
        self.interval = max(0.2, interval_seconds)
        self._stop_event = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self._lock = threading.Lock()
        self._latest: Optional[Dict[str, Any]] = None
        # Prime psutil to avoid initial 0% readings
        try:
            psutil.cpu_percent(interval=None)
        except Exception:
            pass

    def start(self) -> None:
        if self._thread and self._thread.is_alive():
            return
        self._stop_event.clear()
        self._thread = threading.Thread(target=self._run, name="system-monitor", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop_event.set()
        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=1.5)
        self._thread = None

    def latest(self) -> Optional[Dict[str, Any]]:
        with self._lock:
            if not self._latest:
                return None
            # Return a shallow copy to avoid accidental mutation
            return json.loads(json.dumps(self._latest))

    def _run(self) -> None:
        while not self._stop_event.is_set():
            try:
                snapshot = self._collect()
                with self._lock:
                    self._latest = snapshot
            except Exception:
                # Keep the monitor alive even if psutil fails once
                pass
            self._stop_event.wait(self.interval)

    def _collect(self) -> Dict[str, Any]:
        timestamp = time.time()
        boot_time = psutil.boot_time()
        cpu_percent = psutil.cpu_percent(interval=None)
        cpu_per_core = psutil.cpu_percent(interval=None, percpu=True)
        freq = psutil.cpu_freq()
        virtual_mem = psutil.virtual_memory()
        swap_mem = psutil.swap_memory()
        disk = psutil.disk_io_counters()
        net = psutil.net_io_counters()
        load_avg = None
        try:
            load_avg = os.getloadavg()
        except (AttributeError, OSError):
            load_avg = None
        gpu_stats = self._collect_gpu()
        return {
            "timestamp": timestamp,
            "uptimeSeconds": max(0.0, timestamp - boot_time),
            "cpu": {
                "percent": cpu_percent,
                "perCore": cpu_per_core,
                "logical": psutil.cpu_count(logical=True),
                "physical": psutil.cpu_count(logical=False),
                "frequencyMHz": freq.current if freq else None,
                "loadAverage": list(load_avg) if load_avg else None,
            },
            "memory": {
                "total": virtual_mem.total,
                "available": virtual_mem.available,
                "used": virtual_mem.used,
                "percent": virtual_mem.percent,
            },
            "swap": {
                "total": swap_mem.total,
                "used": swap_mem.used,
                "percent": swap_mem.percent,
            },
            "disk": {
                "readBytes": disk.read_bytes if disk else None,
                "writeBytes": disk.write_bytes if disk else None,
            },
            "network": {
                "sentBytes": net.bytes_sent if net else None,
                "receivedBytes": net.bytes_recv if net else None,
            },
            "gpus": gpu_stats,
        }

    def _collect_gpu(self) -> List[Dict[str, Any]]:
        binary = shutil.which("nvidia-smi")
        if not binary:
            return []
        try:
            cmd = [
                binary,
                "--query-gpu=name,memory.total,memory.used,utilization.gpu,temperature.gpu",
                "--format=csv,noheader,nounits",
            ]
            raw = subprocess.check_output(cmd, stderr=subprocess.DEVNULL, text=True, timeout=1.5)
        except Exception:
            return []
        gpus: List[Dict[str, Any]] = []
        for line in raw.strip().splitlines():
            parts = [part.strip() for part in line.split(",")]
            if len(parts) < 4:
                continue
            try:
                gpus.append(
                    {
                        "name": parts[0],
                        "memoryTotalMB": float(parts[1]),
                        "memoryUsedMB": float(parts[2]),
                        "utilizationPercent": float(parts[3]),
                        "temperatureC": float(parts[4]) if len(parts) > 4 else None,
                    }
                )
            except ValueError:
                continue
        return gpus
