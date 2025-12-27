# -*- coding: utf-8 -*-
"""Shared engine pool utilities for safe concurrent TTS usage."""

from __future__ import annotations

import asyncio
import contextlib
import os
import platform
from dataclasses import dataclass
from typing import Callable, Dict, Optional

from .config import ConversionConfig
from .hardware_detector import HardwareProfile


@dataclass(frozen=True)
class ResourceSnapshot:
    cpu_percent: float = 0.0
    cpu_idle: float = 0.0
    ram_gb: float = 0.0
    active_jobs: int = 1


class EngineInstancePool:
    """Async pool that hands out engine instances safely."""

    def __init__(
        self,
        engine_name: str,
        config: ConversionConfig,
        *,
        create_engine: Callable[[ConversionConfig], object],
        max_instances: int,
        edge_parallel_slots: int = 1,
    ) -> None:
        self.engine_name = (engine_name or "").lower()
        self.config = config
        self._create_engine = create_engine
        self._max_instances = max(1, int(max_instances or 1))
        self._edge_parallel_slots = max(1, int(edge_parallel_slots or 1))
        self._queue: asyncio.Queue = asyncio.Queue()
        self._created = 0
        self._lock = asyncio.Lock()

    def update_limits(self, *, max_instances: int, edge_parallel_slots: int) -> None:
        self._max_instances = max(1, int(max_instances or 1))
        self._edge_parallel_slots = max(1, int(edge_parallel_slots or 1))

    def _adjust_instance(self, engine_obj: object) -> None:
        if self.engine_name != "edge":
            return
        if not hasattr(engine_obj, "_enable_parallel") or not hasattr(
            engine_obj, "_parallel_slots"
        ):
            return
        if not bool(getattr(engine_obj, "_enable_parallel", False)):
            return
        try:
            original_slots = int(getattr(engine_obj, "_parallel_slots") or 1)
        except (TypeError, ValueError):
            original_slots = 1
        original_slots = max(1, original_slots)
        adjusted_slots = max(1, original_slots // max(1, self._edge_parallel_slots))
        if adjusted_slots >= original_slots:
            return
        if adjusted_slots <= 1:
            setattr(engine_obj, "_enable_parallel", False)
            setattr(engine_obj, "_parallel_slots", 1)
        else:
            setattr(engine_obj, "_parallel_slots", adjusted_slots)

    def seed(self, engine_obj: object) -> None:
        if engine_obj is None:
            return
        self._adjust_instance(engine_obj)
        self._created += 1
        self._queue.put_nowait(engine_obj)

    async def acquire(self) -> object:
        try:
            return self._queue.get_nowait()
        except asyncio.QueueEmpty:
            pass

        async with self._lock:
            try:
                return self._queue.get_nowait()
            except asyncio.QueueEmpty:
                if self._created < self._max_instances:
                    engine_obj = self._create_engine(self.config)
                    self._created += 1
                    self._adjust_instance(engine_obj)
                    return engine_obj

        return await self._queue.get()

    def release(self, engine_obj: object) -> None:
        if engine_obj is None:
            return
        self._adjust_instance(engine_obj)
        self._queue.put_nowait(engine_obj)


class JobEnginePool:
    """Manage per-engine pools and dynamic limits for a conversion run."""

    def __init__(
        self,
        *,
        create_engine: Callable[[ConversionConfig], object],
        parallel_slots: int,
        edge_cap: int = 0,
        hardware_profile: Optional[HardwareProfile] = None,
        stats_provider: Optional[Callable[[], ResourceSnapshot]] = None,
    ) -> None:
        self._create_engine = create_engine
        self._parallel_slots = max(1, int(parallel_slots or 1))
        self._edge_cap = max(0, int(edge_cap or 0))
        self._hardware_profile = hardware_profile
        self._stats_provider = stats_provider
        self._pools: Dict[str, EngineInstancePool] = {}

    def _snapshot_resources(self) -> ResourceSnapshot:
        snapshot = self._stats_provider() if self._stats_provider else None
        if snapshot is None:
            return ResourceSnapshot(active_jobs=1)
        return snapshot

    def _estimate_engine_capacity(self, engine_name: str) -> int:
        name = (engine_name or "").lower()
        snapshot = self._snapshot_resources()
        cpu_idle = max(0.0, float(snapshot.cpu_idle))
        ram_gb = max(0.0, float(snapshot.ram_gb))
        active_jobs = max(1, int(snapshot.active_jobs or 1))
        profile = self._hardware_profile
        cpu_physical = profile.cpu_physical if profile else 2
        has_gpu = bool(profile and profile.has_gpu)

        def _coqui_safe_mode() -> bool:
            raw = os.getenv("COQUI_SAFE_MODE")
            if raw is not None:
                normalized = str(raw).strip().lower()
                return normalized in {"1", "true", "yes", "on", "enabled"}
            if os.getenv("SPACE_ID"):
                return True
            try:
                return platform.system().lower() == "darwin"
            except Exception:
                return False

        if name == "edge":
            cap = self._parallel_slots
            if self._edge_cap > 0:
                cap = min(cap, self._edge_cap)
            return max(1, cap)

        if name == "coqui":
            if _coqui_safe_mode():
                return 1
            cap = 1
            if has_gpu and ram_gb >= 6 and cpu_idle > 10:
                cap = 2 if ram_gb >= 10 and cpu_idle > 20 else 1
            elif not has_gpu and cpu_physical >= 8 and ram_gb >= 8 and cpu_idle > 70:
                cap = 2
            cap = max(1, cap // active_jobs)
            return max(1, cap)

        if name == "piper":
            cap = 1
            if cpu_idle > 65 and ram_gb >= 3:
                cap = min(4, max(2, cpu_physical // 2))
            elif cpu_idle > 45 and ram_gb >= 2:
                cap = min(2, max(1, cpu_physical // 3))
            cap = max(1, cap // active_jobs)
            return max(1, cap)

        return 1

    def update_parallel_slots(self, parallel_slots: int) -> None:
        self._parallel_slots = max(1, int(parallel_slots or 1))
        for engine_name, pool in self._pools.items():
            pool.update_limits(
                max_instances=self._estimate_engine_capacity(engine_name),
                edge_parallel_slots=self._parallel_slots,
            )

    def register_engine(
        self,
        engine_name: str,
        config: ConversionConfig,
        engine_obj: Optional[object] = None,
    ) -> None:
        if not engine_name or not config:
            return
        name = engine_name.lower()
        pool = self._pools.get(name)
        if pool is None:
            pool = EngineInstancePool(
                name,
                config,
                create_engine=self._create_engine,
                max_instances=self._estimate_engine_capacity(name),
                edge_parallel_slots=self._parallel_slots,
            )
            self._pools[name] = pool
        else:
            pool.config = config
        if name == "coqui" and getattr(config, "coqui_safe_mode", None):
            pool.update_limits(
                max_instances=1,
                edge_parallel_slots=self._parallel_slots,
            )
        if engine_obj is not None:
            pool.seed(engine_obj)

    def has_engine(self, engine_name: str) -> bool:
        return (engine_name or "").lower() in self._pools

    async def acquire(self, engine_name: str) -> tuple[ConversionConfig, object]:
        name = (engine_name or "").lower()
        pool = self._pools.get(name)
        if pool is None:
            raise RuntimeError(f"Engine '{engine_name}' not available")
        engine_obj = await pool.acquire()
        return pool.config, engine_obj

    def release(self, engine_name: str, engine_obj: object) -> None:
        name = (engine_name or "").lower()
        pool = self._pools.get(name)
        if pool is None:
            return
        pool.release(engine_obj)

    @contextlib.asynccontextmanager
    async def use(self, engine_name: str) -> tuple[ConversionConfig, object]:
        config, engine_obj = await self.acquire(engine_name)
        try:
            yield config, engine_obj
        finally:
            self.release(engine_name, engine_obj)


__all__ = ["ResourceSnapshot", "EngineInstancePool", "JobEnginePool"]
