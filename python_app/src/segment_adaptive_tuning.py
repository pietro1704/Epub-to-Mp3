"""Use segment telemetry and pre-flight resource checks to tune chapter concurrency."""

from __future__ import annotations

import asyncio
import contextlib
import os
import random
import time
from typing import Optional

import psutil

from .config import ConversionConfig
from .engine_pool import JobEnginePool, ResourceSnapshot


class SegmentAdaptiveTuning:
    def _record_segment_success(
        self,
        *,
        engine_label: str,
        chapter_index: int,
        segment_chars: int,
        engine_pool: Optional[JobEnginePool] = None,
        config: Optional[ConversionConfig] = None,
    ) -> None:
        """Adapt runtime parameters using successful segment/chunk telemetry."""
        engine = (engine_label or "").lower()
        if segment_chars <= 0:
            return

        state = self._segment_adaptive_state
        now = time.time()
        chapter_key = f"{engine}:{chapter_index}"
        chapter_times = state.setdefault("last_event_by_chapter", {})
        prev_ts = chapter_times.get(chapter_key)
        chapter_times[chapter_key] = now
        if prev_ts is None:
            return

        elapsed = max(now - float(prev_ts), 0.001)
        cps = float(segment_chars) / elapsed
        engine_cps = state.setdefault("engine_cps", {})
        history = engine_cps.setdefault(engine, [])
        history.append(cps)
        if len(history) > 16:
            del history[0 : len(history) - 16]
        avg_cps = sum(history) / len(history)
        snapshot = self._resource_snapshot()
        self._apply_thermal_power_guard(engine_pool=engine_pool)
        self._append_segment_metric(
            {
                "event": "segment_success",
                "engine": engine,
                "chapter": chapter_index,
                "segment_chars": int(segment_chars),
                "elapsed_s": round(float(elapsed), 4),
                "cps": round(float(cps), 3),
                "avg_cps": round(float(avg_cps), 3),
                "cpu_percent": round(float(snapshot.cpu_percent), 2),
                "ram_gb": round(float(snapshot.ram_gb), 3),
                "parallel": int(self._parallel_state.get("current") or 1),
            }
        )
        self._apply_engine_resource_budget(
            engine_label=engine,
            snapshot=snapshot,
            engine_pool=engine_pool,
        )

        # Reduce health-check overhead after sustained stability; restore immediately when unstable.
        base_interval = max(1, int(state.get("pre_check_base_interval", 1) or 1))
        max_interval = max(base_interval, int(state.get("pre_check_max_interval", 4) or 4))
        promote_streak = max(2, int(state.get("pre_check_promote_streak", 6) or 6))
        interval_by_engine = state.setdefault("pre_check_interval_by_engine", {})
        stable_by_engine = state.setdefault("pre_check_stable_streak_by_engine", {})
        current_interval = max(
            base_interval, int(interval_by_engine.get(engine, base_interval) or 1)
        )
        stable_streak = int(stable_by_engine.get(engine, 0) or 0)

        is_unstable = snapshot.cpu_percent > 95 or snapshot.ram_gb < 0.6 or avg_cps < 80
        if is_unstable:
            stable_by_engine[engine] = 0
            if current_interval != base_interval:
                interval_by_engine[engine] = base_interval
                if self.verbose:
                    print(
                        f"🩺 Pre-check interval reset for {engine}: {current_interval}→{base_interval}"
                    )
        else:
            stable_streak += 1
            if stable_streak >= promote_streak and current_interval < max_interval:
                interval_by_engine[engine] = min(max_interval, current_interval + 1)
                stable_by_engine[engine] = 0
                if self.verbose:
                    print(
                        f"⚡ Pre-check interval promoted for {engine}: "
                        f"{current_interval}→{interval_by_engine[engine]}"
                    )
            else:
                stable_by_engine[engine] = stable_streak

        cooldown = float(state.get("cooldown_seconds", 10.0) or 10.0)
        last_adjustment = float(state.get("last_adjustment", 0.0) or 0.0)
        if (now - last_adjustment) < cooldown:
            return

        current_parallel = max(1, int(self._parallel_state.get("current") or 1))
        ceiling_parallel = max(
            current_parallel, int(self._parallel_state.get("ceiling") or current_parallel)
        )
        new_parallel = current_parallel
        reason = None

        if snapshot.ram_gb < 0.45 and current_parallel > 1:
            state["down_streak"] = int(state.get("down_streak", 0) or 0) + 1
            state["up_streak"] = 0
            if state["down_streak"] >= 2:
                new_parallel = current_parallel - 1
                reason = f"segment telemetry: low RAM ({snapshot.ram_gb:.1f} GB)"
        elif snapshot.cpu_percent > 95 and avg_cps < 100 and current_parallel > 1:
            state["down_streak"] = int(state.get("down_streak", 0) or 0) + 1
            state["up_streak"] = 0
            if state["down_streak"] >= 2:
                new_parallel = current_parallel - 1
                reason = (
                    f"segment telemetry: CPU saturation ({int(snapshot.cpu_percent)}%) with low cps"
                )
        elif (
            snapshot.cpu_percent < 75
            and snapshot.ram_gb > 1.0
            and avg_cps > 170
            and current_parallel < ceiling_parallel
        ):
            state["up_streak"] = int(state.get("up_streak", 0) or 0) + 1
            state["down_streak"] = 0
            if state["up_streak"] >= 3:
                new_parallel = current_parallel + 1
                reason = f"segment telemetry: stable throughput (~{int(avg_cps)} chars/s)"
        else:
            state["up_streak"] = 0
            state["down_streak"] = 0

        new_parallel = max(1, min(ceiling_parallel, new_parallel))
        if new_parallel != current_parallel:
            self._parallel_state["current"] = new_parallel
            if engine_pool is not None:
                engine_pool.update_parallel_slots(new_parallel)
            state["last_adjustment"] = now
            state["up_streak"] = 0
            state["down_streak"] = 0
            if self.verbose and reason:
                print(f"⚙️ {reason} → {new_parallel} chapter(s) in parallel")
            return

        if not config:
            return

        tuned = False
        if engine == "piper":
            chunk_chars = int(os.getenv("PIPER_CHUNK_CHARS", "3000") or "3000")
            new_chunk = chunk_chars
            if avg_cps > 200 and snapshot.cpu_percent < 85:
                new_chunk = min(6000, chunk_chars + 300)
            elif avg_cps < 120 or snapshot.cpu_percent > 95:
                new_chunk = max(1800, chunk_chars - 300)
            if new_chunk != chunk_chars:
                os.environ["PIPER_CHUNK_CHARS"] = str(new_chunk)
                tuned = True
                if self.verbose:
                    print(f"⚙️ Piper adaptive chunk: {chunk_chars} → {new_chunk} (seg ok)")
            workers = int(
                getattr(config, "piper_max_procs", 0) or os.getenv("PIPER_MAX_PROCS", "2") or "2"
            )
            new_workers = workers
            if snapshot.cpu_percent > 95 or snapshot.ram_gb < 0.8:
                new_workers = max(1, workers - 1)
            elif avg_cps > 170 and snapshot.cpu_percent < 82 and snapshot.ram_gb > 1.4:
                new_workers = min(8, workers + 1)
            if new_workers != workers:
                os.environ["PIPER_MAX_PROCS"] = str(new_workers)
                config.piper_max_procs = new_workers
                tuned = True
                if self.verbose:
                    print(f"⚙️ Piper adaptive workers: {workers} → {new_workers} (seg ok)")
        elif engine == "edge":
            edge_chunk = int(os.getenv("EDGE_CHUNK_CHARS", "12000") or "12000")
            new_chunk = edge_chunk
            if avg_cps > 240 and snapshot.cpu_percent < 85:
                new_chunk = min(24000, edge_chunk + 500)
            elif avg_cps < 140 or snapshot.cpu_percent > 95:
                new_chunk = max(4000, edge_chunk - 500)
            if new_chunk != edge_chunk:
                os.environ["EDGE_CHUNK_CHARS"] = str(new_chunk)
                if config is not None:
                    config.edge_chunk_chars = new_chunk
                tuned = True
                if self.verbose:
                    print(f"⚙️ Edge adaptive chunk: {edge_chunk} → {new_chunk} (seg ok)")

        if tuned:
            state["last_adjustment"] = now

    def _pre_segment_health_check(
        self,
        *,
        engine_label: str,
        segment_chars: int,
        engine_pool: Optional[JobEnginePool] = None,
        config: Optional[ConversionConfig] = None,
        engine_obj: Optional[object] = None,
    ) -> None:
        """Run health checks before each segment and proactively adjust parameters."""
        engine = (engine_label or "").lower()
        if segment_chars <= 0:
            return
        state = self._segment_adaptive_state
        base_interval = max(1, int(state.get("pre_check_base_interval", 1) or 1))
        interval_by_engine = state.setdefault("pre_check_interval_by_engine", {})
        counter_by_engine = state.setdefault("pre_check_counter_by_engine", {})
        interval = max(base_interval, int(interval_by_engine.get(engine, base_interval) or 1))
        counter = int(counter_by_engine.get(engine, 0) or 0) + 1
        counter_by_engine[engine] = counter
        if interval > 1 and (counter % interval) != 1:
            return

        snapshot = self._resource_snapshot()
        self._apply_thermal_power_guard(engine_pool=engine_pool)
        self._append_segment_metric(
            {
                "event": "pre_segment_check",
                "engine": engine,
                "segment_chars": int(segment_chars),
                "cpu_percent": round(float(snapshot.cpu_percent), 2),
                "ram_gb": round(float(snapshot.ram_gb), 3),
                "parallel": int(self._parallel_state.get("current") or 1),
            }
        )
        self._apply_engine_resource_budget(
            engine_label=engine,
            snapshot=snapshot,
            engine_pool=engine_pool,
        )
        current_parallel = max(1, int(self._parallel_state.get("current") or 1))
        ceiling_parallel = max(
            current_parallel, int(self._parallel_state.get("ceiling") or current_parallel)
        )

        reduced_parallel = current_parallel
        if snapshot.ram_gb < 0.4 and current_parallel > 1:
            state["pre_reduce_streak"] = int(state.get("pre_reduce_streak", 0) or 0) + 1
            state["pre_hold_streak"] = 0
            if state["pre_reduce_streak"] >= 2:
                reduced_parallel = current_parallel - 1
        elif snapshot.cpu_percent > 97 and current_parallel > 1:
            state["pre_reduce_streak"] = int(state.get("pre_reduce_streak", 0) or 0) + 1
            state["pre_hold_streak"] = 0
            if state["pre_reduce_streak"] >= 2:
                reduced_parallel = current_parallel - 1
        else:
            state["pre_hold_streak"] = int(state.get("pre_hold_streak", 0) or 0) + 1
            if state["pre_hold_streak"] >= 2:
                state["pre_reduce_streak"] = 0

        reduced_parallel = max(1, min(ceiling_parallel, reduced_parallel))
        if reduced_parallel != current_parallel:
            self._parallel_state["current"] = reduced_parallel
            if engine_pool is not None:
                engine_pool.update_parallel_slots(reduced_parallel)
            state = self._segment_adaptive_state
            state["pre_reduce_streak"] = 0
            state["pre_hold_streak"] = 0
            if self.verbose:
                print(
                    f"🩺 Pre-segment check: reducing parallelism {current_parallel}→{reduced_parallel}"
                )

        if engine == "edge":
            if config is not None:
                chunk_chars = int(getattr(config, "edge_chunk_chars", 12000) or 12000)
                if snapshot.cpu_percent > 95 and segment_chars > 8000:
                    chunk_chars = max(4000, chunk_chars - 1000)
                elif snapshot.cpu_percent < 75 and segment_chars > 12000:
                    chunk_chars = min(24000, chunk_chars + 500)
                config.edge_chunk_chars = chunk_chars
                os.environ["EDGE_CHUNK_CHARS"] = str(chunk_chars)
            if engine_obj is not None and hasattr(engine_obj, "apply_speed_profile"):
                with contextlib.suppress(Exception):
                    engine_obj.apply_speed_profile(
                        chunk_char_limit=max(4000, int(getattr(config, "edge_chunk_chars", 12000))),
                    )
        elif engine == "piper":
            chunk_chars = int(os.getenv("PIPER_CHUNK_CHARS", "3000") or "3000")
            workers = int(
                getattr(config, "piper_max_procs", 0)
                if config is not None
                else 0 or os.getenv("PIPER_MAX_PROCS", "2") or "2"
            )
            if snapshot.cpu_percent > 95:
                chunk_chars = max(1800, chunk_chars - 300)
                workers = max(1, workers - 1)
            elif snapshot.cpu_percent < 75 and segment_chars > 6000:
                chunk_chars = min(6000, chunk_chars + 200)
                workers = min(8, workers + 1)
            os.environ["PIPER_CHUNK_CHARS"] = str(chunk_chars)
            os.environ["PIPER_MAX_PROCS"] = str(workers)
            if config is not None:
                config.piper_max_procs = workers
            if engine_obj is not None:
                with contextlib.suppress(Exception):
                    setattr(engine_obj, "_chunk_char_limit", chunk_chars)
                with contextlib.suppress(Exception):
                    setattr(engine_obj, "_semaphore", asyncio.Semaphore(max(1, workers)))

    def _resource_snapshot(self) -> ResourceSnapshot:
        """Return a best-effort resource snapshot for tuning."""
        cpu_pct = 0.0
        ram_gb = 0.0
        with contextlib.suppress(Exception):
            cpu_pct = float(psutil.cpu_percent(interval=None))
        with contextlib.suppress(Exception):
            mem = psutil.virtual_memory()
            ram_gb = float(mem.available / (1024**3))
        cpu_idle = max(0.0, 100.0 - cpu_pct)
        return ResourceSnapshot(
            cpu_percent=cpu_pct,
            cpu_idle=cpu_idle,
            ram_gb=ram_gb,
            active_jobs=1,
        )

    @staticmethod
    def _jittered_auto_tune_thresholds() -> tuple[float, float]:
        """Return (down, up) multipliers with ±10% jitter around 0.78 / 1.18.

        Factored out for testability; inline in ``_auto_tune_parallelism``
        callers so concurrent conversions don't pick identical thresholds.
        """
        down = 0.78 + random.uniform(-0.08, 0.08)
        up = 1.18 + random.uniform(-0.12, 0.12)
        return down, up

    def _auto_tune_parallelism(
        self,
        *,
        throughput: Optional[float],
        batch_errors: int,
    ) -> tuple[int, Optional[str]]:
        """Decide the next chapter parallelism level based on telemetry."""
        state = self._parallel_state or {}
        ceiling = max(1, int(state.get("ceiling") or 1))
        thermal_cap = self._thermal_guard_state.get("cap")
        if thermal_cap is not None:
            try:
                ceiling = max(1, min(ceiling, int(thermal_cap)))
            except (TypeError, ValueError):
                pass
        current = max(1, min(ceiling, int(state.get("current") or 1)))
        best = float(state.get("best_throughput") or 0.0)
        last = state.get("last_throughput")
        degrade_runs = int(state.get("degrade_runs") or 0)
        snapshot = self._resource_snapshot()
        cpu_pct = snapshot.cpu_percent
        ram_gb = snapshot.ram_gb
        reason: Optional[str] = None
        new_value = current

        if batch_errors > 0:
            new_value = max(1, current - 1)
            state["degrade_runs"] = min(3, degrade_runs + 1)
            reason = (
                f"reducing to {new_value} chapter(s) simultaneous after {batch_errors} error(s)"
            )
        else:
            state["degrade_runs"] = max(0, degrade_runs - 1)
            if throughput:
                if throughput > best:
                    state["best_throughput"] = throughput
                # ±10% jitter on the decision thresholds so concurrent
                # conversions don't all step up/down in lockstep (avoids
                # thundering-herd CPU spikes on HF Spaces).
                down_threshold, up_threshold = self._jittered_auto_tune_thresholds()
                if last and throughput < last * down_threshold and current > 1:
                    new_value = current - 1
                    reason = (
                        f"throughput caiu de ~{int(last)} para ~{int(throughput)} chars/s → "
                        f"{new_value} chapter(s)"
                    )
                elif last and throughput >= last * up_threshold and current < ceiling:
                    new_value = current + 1
                    reason = (
                        f"throughput atingiu ~{int(throughput)} chars/s → "
                        f"testando {new_value} chapter(s)"
                    )
                elif not last and current < ceiling and throughput >= max(best, 1.0):
                    new_value = current + 1
                    reason = (
                        f"fast initial batch (~{int(throughput)} chars/s) → {new_value} chapter(s)"
                    )

            if not reason:
                if ram_gb < 0.45 and new_value > 1:
                    new_value = new_value - 1
                    reason = f"RAM livre baixa ({ram_gb:.1f} GB) → limitando a {new_value}"
                elif cpu_pct < 55.0 and new_value < ceiling:
                    new_value = new_value + 1
                    reason = f"CPU em {int(cpu_pct)}% → liberando {new_value} chapter(s)"
                elif cpu_pct > 94.0 and throughput and throughput < best * 0.85 and new_value > 1:
                    new_value = new_value - 1
                    reason = f"CPU saturada ({int(cpu_pct)}%) sem ganho → {new_value} chapter(s)"

        # When the Edge auto-tuner has shrunk chunks below ~6K, every chapter
        # generates many more requests. Running 15+ chapters in parallel under
        # that condition saturates outbound bandwidth and creates head-of-line
        # blocking on Edge's per-IP slots. Cap chapter parallelism to match.
        chunk_cap = self._chapter_cap_from_edge_chunk()
        if chunk_cap is not None and new_value > chunk_cap:
            chunk_reason = f"Edge chunk reduzido → limitando capítulos paralelos a {chunk_cap}"
            new_value = chunk_cap
            reason = chunk_reason if not reason else f"{reason}; {chunk_reason}"
        # v0.3.28: explicit recovery nudge. After a degrade cycle, the
        # only path back up was the +1 step on a positive throughput
        # delta — slow when chapters are short. If the system has fully
        # stabilised (no errors, no degrade backlog, no chunk cap, room
        # to grow), bump current_value by one to probe the headroom even
        # without a clear throughput signal. This shaves multiple
        # tuning cycles off recovery after a transient slowdown.
        elif (
            chunk_cap is None
            and batch_errors == 0
            and state.get("degrade_runs") == 0
            and current < ceiling
            and new_value == current
            and reason is None
        ):
            new_value = current + 1
            reason = f"recovery nudge → testando {new_value} chapter(s)"

        new_value = max(1, min(ceiling, new_value))
        if throughput:
            state["last_throughput"] = throughput
        elif "last_throughput" not in state:
            state["last_throughput"] = None
        state["current"] = new_value
        self._parallel_state = state
        return new_value, reason
