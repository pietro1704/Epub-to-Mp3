"""Translate native health snapshots to the legacy server monitor response."""


class SystemMonitorAdapter:
    """Adapter to make HealthMonitor compatible with old system_monitor API."""

    def __init__(self, health_monitor):
        self._health_monitor = health_monitor

    def latest(self):
        """Compatibility method that returns snapshot in old format."""
        snapshot = self._health_monitor.get_latest_snapshot()
        if not snapshot:
            return {}

        import os

        # Calculate memory values from snapshot
        # memory_mb is used memory, memory_percent is percentage used
        # So: memory_total = memory_mb / (memory_percent / 100)
        if snapshot.memory_percent > 0:
            memory_total_mb = snapshot.memory_mb / (snapshot.memory_percent / 100)
            memory_available_mb = memory_total_mb - snapshot.memory_mb
        else:
            memory_total_mb = 0
            memory_available_mb = 0

        # Convert to old format
        return {
            "cpu": {
                "percent": snapshot.cpu_percent,
                "count": os.cpu_count() or 4,
            },
            "memory": {
                "percent": snapshot.memory_percent,
                "available": memory_available_mb * 1024 * 1024,  # MB to bytes
                "total": memory_total_mb * 1024 * 1024,  # MB to bytes
            },
            "disk": {
                "percent": 0,  # Not available in HealthSnapshot
            },
        }

    def start(self):
        """Start monitoring."""
        self._health_monitor.start()

    def stop(self):
        """Stop monitoring."""
        self._health_monitor.stop()
