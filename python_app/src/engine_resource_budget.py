"""Apply per-engine resource shares and thermal/power limits."""

from __future__ import annotations

import os
import platform
import re
import subprocess
import time
from typing import Dict, Optional

from ._env_utils import env_float as _env_float
from .engine_pool import JobEnginePool, ResourceSnapshot


class EngineResourceBudget:
    def _apply_engine_resource_budget(
        self,
        *,
        engine_label: str,
        snapshot: ResourceSnapshot,
        engine_pool: Optional[JobEnginePool] = None,
    ) -> None:
        if not self._resource_budget_enabled:
            return
        engine = (engine_label or "unknown").lower()
        ceiling = max(1, int(self._parallel_state.get("ceiling") or 1))
        current = max(1, int(self._parallel_state.get("current") or 1))
        budget = self._engine_resource_budget.setdefault(
            engine,
            {"cap": ceiling, "pressure_streak": 0, "free_streak": 0},
        )
        cap = max(1, min(ceiling, int(budget.get("cap", ceiling) or ceiling)))
        pressure_ram_gb = _env_float("RESOURCE_PRESSURE_RAM_GB", 0.65)
        recovery_ram_gb = max(
            pressure_ram_gb,
            _env_float("RESOURCE_RECOVERY_RAM_GB", 1.4),
        )
        pressure_cpu_percent = _env_float("RESOURCE_PRESSURE_CPU_PERCENT", 94.0)
        recovery_cpu_percent = _env_float("RESOURCE_RECOVERY_CPU_PERCENT", 72.0)
        override_source = str(os.getenv("CHAPTER_PARALLEL_COUNT_SOURCE", "") or "").strip()
        requested_parallel = str(os.getenv("CHAPTER_PARALLEL_COUNT", "") or "").strip()
        explicit_override = override_source == "explicit" or (
            not override_source and bool(requested_parallel and requested_parallel != "0")
        )
        transition_reason: Optional[str] = None
        engine_cps = self._segment_adaptive_state.get("engine_cps", {})
        if isinstance(engine_cps, dict) and engine_cps:
            averages: Dict[str, float] = {}
            for name, values in engine_cps.items():
                try:
                    seq = [float(v) for v in (values or []) if float(v) > 0]
                except Exception:
                    seq = []
                if seq:
                    averages[str(name).lower()] = sum(seq) / len(seq)
            if averages and engine in averages:
                top = max(averages.values()) or 1.0
                ratio = max(self._resource_budget_min_share, min(1.0, averages[engine] / top))
                perf_cap = max(1, int(round(ceiling * ratio)))
                cap = min(cap, perf_cap)
                if cap < current:
                    transition_reason = "engine_share"

        ram_pressure = snapshot.ram_gb < pressure_ram_gb
        cpu_pressure = snapshot.cpu_percent > pressure_cpu_percent
        if ram_pressure or cpu_pressure:
            budget["pressure_streak"] = int(budget.get("pressure_streak", 0) or 0) + 1
            budget["free_streak"] = 0
            if budget["pressure_streak"] >= 2:
                cap = max(1, cap - 1)
                budget["pressure_streak"] = 0
                if ram_pressure and cpu_pressure:
                    transition_reason = "ram_available_and_cpu_saturation"
                elif ram_pressure:
                    transition_reason = "ram_available"
                else:
                    transition_reason = "cpu_saturation"
        elif snapshot.cpu_percent < recovery_cpu_percent and snapshot.ram_gb > recovery_ram_gb:
            budget["free_streak"] = int(budget.get("free_streak", 0) or 0) + 1
            budget["pressure_streak"] = 0
            if budget["free_streak"] >= 3:
                if engine == "edge" and snapshot.cpu_percent < 40 and cap >= ceiling:
                    hard_ceiling = max(
                        ceiling, int(budget.get("ceiling_override", ceiling) or ceiling)
                    )
                    hard_ceiling = min(hard_ceiling + 1, ceiling * 3, 32)
                    budget["ceiling_override"] = hard_ceiling
                    self._parallel_state["ceiling"] = hard_ceiling
                    ceiling = hard_ceiling
                cap = min(ceiling, cap + 1)
                budget["free_streak"] = 0
                transition_reason = "ram_recovered_and_cpu_available"
        else:
            budget["pressure_streak"] = 0
            budget["free_streak"] = 0

        budget["cap"] = cap
        if current != cap:
            self._parallel_state["current"] = cap
            if engine_pool is not None:
                engine_pool.update_parallel_slots(cap)
            self._append_runtime_metric(
                {
                    "event": "resource_budget_cap",
                    "engine": engine,
                    "from_parallel": current,
                    "to_parallel": cap,
                    "cpu_percent": round(float(snapshot.cpu_percent), 2),
                    "ram_gb": round(float(snapshot.ram_gb), 3),
                    "reason": transition_reason or "engine_share",
                    "override_bypassed_guard": explicit_override
                    and bool(ram_pressure or cpu_pressure),
                    "pressure_ram_threshold_gb": round(float(pressure_ram_gb), 3),
                    "recovery_ram_threshold_gb": round(float(recovery_ram_gb), 3),
                }
            )
            if self.verbose:
                direction = "↑" if cap > current else "↓"
                print(f"⚖️ Resource budget {direction} for {engine}: {current}→{cap}")

    def _detect_macos_thermal_power_cap(self, ceiling: int) -> tuple[int, str]:
        """Return runtime parallel cap based on macOS power/thermal pressure."""
        if platform.system().lower() != "darwin":
            return ceiling, "normal"
        cap = int(max(1, ceiling))
        mode = "normal"
        try:
            batt = subprocess.run(
                ["pmset", "-g", "batt"],
                capture_output=True,
                text=True,
                timeout=2,
            )
            batt_out = str(batt.stdout or "").lower()
            on_battery = "battery power" in batt_out
            if on_battery:
                mode = "battery"
                cap = max(1, min(cap, int(round(ceiling * 0.7))))
        except Exception:
            pass
        try:
            therm = subprocess.run(
                ["pmset", "-g", "therm"],
                capture_output=True,
                text=True,
                timeout=2,
            )
            therm_out = str(therm.stdout or "")
            speed_limit = None
            match = re.search(r"CPU_Speed_Limit\\s*=\\s*(\\d+)", therm_out, flags=re.IGNORECASE)
            if match:
                speed_limit = int(match.group(1))
            if speed_limit is not None:
                if speed_limit < 75:
                    mode = "thermal_hot"
                    cap = max(1, min(cap, int(round(ceiling * 0.5))))
                elif speed_limit < 90:
                    if mode == "normal":
                        mode = "thermal_warm"
                    cap = max(1, min(cap, int(round(ceiling * 0.75))))
        except Exception:
            pass
        return max(1, cap), mode

    def _apply_thermal_power_guard(self, engine_pool: Optional[JobEnginePool] = None) -> None:
        """Continuously cap parallelism under thermal/power pressure."""
        state = self._thermal_guard_state
        now = time.time()
        poll_interval = float(state.get("poll_interval", 20.0) or 20.0)
        cached_cap = state.get("cap")
        mode = str(state.get("mode", "normal") or "normal")
        ceiling = max(1, int(self._parallel_state.get("ceiling") or 1))

        if (now - float(state.get("last_poll", 0.0) or 0.0)) >= poll_interval or cached_cap is None:
            cap, mode = self._detect_macos_thermal_power_cap(ceiling)
            state["last_poll"] = now
            state["cap"] = cap
            state["mode"] = mode
            cached_cap = cap

        if cached_cap is None:
            return
        cap_int = max(1, min(ceiling, int(cached_cap)))
        current = max(1, int(self._parallel_state.get("current") or 1))
        if current > cap_int:
            self._parallel_state["current"] = cap_int
            if engine_pool is not None:
                engine_pool.update_parallel_slots(cap_int)
            self._append_runtime_metric(
                {
                    "event": "thermal_guard_cap",
                    "mode": mode,
                    "from_parallel": current,
                    "to_parallel": cap_int,
                }
            )
            if self.verbose:
                print(f"🌡️ Thermal/power guard ({mode}): {current}→{cap_int}")
