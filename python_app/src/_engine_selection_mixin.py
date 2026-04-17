"""Engine selection, warm start, and auto engine mixin for AudioConverter."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import weakref
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Set

from .config import ConversionConfig
from .ebook_reader import Chapter


def _has_piper_support() -> bool:
    from . import converter as _conv

    return _conv._has_piper_support()


def _piper_fallback_disabled() -> bool:
    """Return True when the user has opted out of Piper fallback via env var."""
    return os.getenv("DISABLE_PIPER_FALLBACK", "").strip().lower() in ("1", "true", "yes")


def _warn_piper_fallback(chapter_chars: int = 0) -> None:
    """Print a prominent warning when falling back to Piper (slow local engine)."""
    # Rough estimates: Edge ~200 WPM → ~800 cpm; Piper ~25 WPM → ~100 cpm
    if chapter_chars > 0:
        edge_secs = max(1, chapter_chars // 800)
        piper_secs = max(1, chapter_chars // 100)
        time_note = (
            f" (~{piper_secs}s vs {edge_secs}s on Edge)"
            if piper_secs < 120
            else f" (~{piper_secs // 60}min vs {edge_secs}s on Edge)"
        )
    else:
        time_note = " (~10–50× slower than Edge)"
    print(
        f"\n⚠️  PIPER FALLBACK: switching to local ONNX engine{time_note}.\n"
        "   Set DISABLE_PIPER_FALLBACK=1 to skip Piper and retry Edge instead.\n"
    )


def _has_coqui_support() -> bool:
    from . import converter as _conv

    return _conv._has_coqui_support()


def _has_kokoro_support(language: Optional[str]) -> bool:
    from . import converter as _conv

    return _conv._has_kokoro_support(language)


def _env_bool(name: str, default: bool = False) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def _env_int(name: str, default: int) -> int:
    raw = os.getenv(name)
    if raw is None or raw == "":
        return default
    try:
        return int(raw)
    except (TypeError, ValueError):
        return default


def _env_float(name: str, default: float) -> float:
    raw = os.getenv(name)
    if raw is None or raw == "":
        return default
    try:
        return float(raw)
    except (TypeError, ValueError):
        return default


# Mirror of the same constants defined in converter.py
EDGE_MULTILINGUAL_RATE_CAP = _env_int("EDGE_MULTILINGUAL_RATE_CAP", 10)
EDGE_MONOLINGUAL_RATE_CAP = _env_int("EDGE_MONOLINGUAL_RATE_CAP", 16)
EDGE_PREDICTIVE_TIMEOUT_ENABLED = _env_bool("EDGE_PREDICTIVE_TIMEOUT_ENABLED", True)
EDGE_PREDICTIVE_TIMEOUT_SECONDS = _env_int("EDGE_PREDICTIVE_TIMEOUT_SECONDS", 900)
EDGE_PREDICTIVE_TIMEOUT_CHARS = _env_int("EDGE_PREDICTIVE_TIMEOUT_CHARS", 30_000)
EDGE_PREDICTIVE_MIN_EDGE_CPS = _env_float("EDGE_PREDICTIVE_MIN_EDGE_CPS", 85.0)


class _EngineSelectionMixin:
    @staticmethod
    def _warmup_output_path(base_dir: Path, engine: str) -> Path:
        ext = ".mp3" if (engine or "").lower() == "edge" else ".wav"
        return base_dir / f"{(engine or 'engine').lower()}-warmup{ext}"

    def _warm_start_key(self, cfg: Optional[ConversionConfig], engine_label: str) -> str:
        key = self._runtime_tuning_key(cfg, engine_label)
        return f"{key['engine']}|{key['voice']}|{key['language']}|{key.get('machine_signature', 'generic')}"

    def _load_warm_start_state(self) -> Dict[str, Any]:
        if not self._warm_start_enabled or not self._warm_start_path.exists():
            return {}
        try:
            payload = json.loads(self._warm_start_path.read_text(encoding="utf-8"))
            entries = payload.get("entries", {}) if isinstance(payload, dict) else {}
            if not isinstance(entries, dict):
                return {}
            now = time.time()
            ttl = max(60.0, float(payload.get("ttl_seconds", self._warm_start_ttl_seconds) or 0.0))
            cleaned: Dict[str, Any] = {}
            changed = False
            for key, raw in entries.items():
                if not isinstance(raw, dict):
                    changed = True
                    continue
                ts = float(raw.get("ts", 0.0) or 0.0)
                if ts <= 0 or (now - ts) > ttl:
                    changed = True
                    continue
                cleaned[str(key)] = {"ts": ts}
            if changed:
                self._save_warm_start_state(cleaned)
            return cleaned
        except Exception:
            return {}

    def _save_warm_start_state(self, entries: Dict[str, Any]) -> None:
        if not self._warm_start_enabled:
            return
        try:
            self._warm_start_path.parent.mkdir(parents=True, exist_ok=True)
            payload = {
                "updated_at": time.time(),
                "ttl_seconds": self._warm_start_ttl_seconds,
                "entries": entries,
            }
            self._warm_start_path.write_text(
                json.dumps(payload, ensure_ascii=False, indent=2),
                encoding="utf-8",
            )
        except Exception:
            return

    def _is_warm_start_fresh(self, cfg: Optional[ConversionConfig], engine_label: str) -> bool:
        entries = self._load_warm_start_state()
        if not entries:
            return False
        key = self._warm_start_key(cfg, engine_label)
        raw = entries.get(key)
        if not isinstance(raw, dict):
            return False
        ts = float(raw.get("ts", 0.0) or 0.0)
        if ts <= 0:
            return False
        return (time.time() - ts) <= self._warm_start_ttl_seconds

    @staticmethod
    def _percentile(values: List[float], q: float) -> float:
        seq = sorted(float(v) for v in (values or []) if float(v) >= 0.0)
        if not seq:
            return 0.0
        if q <= 0:
            return float(seq[0])
        if q >= 1:
            return float(seq[-1])
        idx = (len(seq) - 1) * q
        lo = int(idx)
        hi = min(len(seq) - 1, lo + 1)
        frac = idx - lo
        return float(seq[lo] * (1.0 - frac) + seq[hi] * frac)

    def _mark_warm_start_ready(self, cfg: Optional[ConversionConfig], engine_label: str) -> None:
        entries = self._load_warm_start_state()
        key = self._warm_start_key(cfg, engine_label)
        entries[key] = {"ts": time.time()}
        if len(entries) > 300:
            sorted_keys = sorted(
                entries.keys(),
                key=lambda item: float((entries.get(item) or {}).get("ts", 0.0) or 0.0),
                reverse=True,
            )
            entries = {name: entries[name] for name in sorted_keys[:200]}
        self._save_warm_start_state(entries)

    def _create_optimized_thread_pool(self, max_workers: int) -> ThreadPoolExecutor:
        """
        Create a thread pool with optimized settings.

        Args:
            max_workers: Maximum number of worker threads

        Returns:
            Optimized ThreadPoolExecutor
        """
        # Limit max workers based on available resources
        cpu_count = os.cpu_count() or 4
        max_workers = min(max_workers, cpu_count * 2)  # Don't exceed 2x CPU count

        # Create thread pool with smaller stack size for memory efficiency
        executor = ThreadPoolExecutor(
            max_workers=max_workers, thread_name_prefix="converter_worker"
        )

        # Track thread pool for cleanup
        self._thread_pools.append(weakref.ref(executor))

        return executor

    def _auto_engine_candidates(self, base_config: ConversionConfig) -> List[str]:
        """Return preferred auto-mode engine order.

        Considers network quality, book size, and chapter stats to decide
        whether a local engine (Piper) should be tried before Edge.
        """
        # Product decision: in auto mode, always try Edge first.
        # Offline engines are fallback-only for failures/timeouts.
        candidates: List[str] = ["edge"]

        piper_voice = None
        try:
            piper_voice = self.tts_factory.voice_provider.get_voice(
                "piper", base_config.primary_language
            )
        except Exception:
            piper_voice = None
        has_piper = _has_piper_support() and bool(piper_voice)

        if has_piper:
            candidates.append("piper")
        if _has_coqui_support():
            candidates.append("coqui")
        ordered: List[str] = []
        seen: Set[str] = set()
        for name in candidates:
            if name and name not in seen:
                ordered.append(name)
                seen.add(name)
        return ordered

    def _resolve_offline_fallback_engine(
        self, available: Optional[Set[str]] = None
    ) -> Optional[str]:
        available_set = {str(item).lower() for item in (available or set())}
        if _has_piper_support() and (not available_set or "piper" in available_set):
            if _piper_fallback_disabled():
                print("\nℹ️  DISABLE_PIPER_FALLBACK=1: skipping Piper, will retry Edge.\n")
                return None
            _warn_piper_fallback()
            return "piper"
        if _has_coqui_support() and (not available_set or "coqui" in available_set):
            return "coqui"
        return None

    def _predict_edge_runtime_seconds(self, chapter_chars: int) -> float:
        if chapter_chars <= 0:
            return 0.0
        state = self._segment_adaptive_state or {}
        engine_cps = state.get("engine_cps", {}) if isinstance(state, dict) else {}
        edge_samples = []
        if isinstance(engine_cps, dict):
            raw = engine_cps.get("edge", [])
            try:
                edge_samples = [float(v) for v in (raw or []) if float(v) > 0]
            except Exception:
                edge_samples = []
        if edge_samples:
            observed_cps = sum(edge_samples[-12:]) / max(1, len(edge_samples[-12:]))
        else:
            observed_cps = float(EDGE_PREDICTIVE_MIN_EDGE_CPS)
        safe_cps = max(35.0, min(observed_cps, 220.0))
        return float(chapter_chars) / safe_cps

    def _should_preempt_edge_timeout(
        self, chapter_chars: int, estimated_seconds: float
    ) -> Optional[str]:
        """Return reason when Edge is likely to timeout or be too slow for this chapter."""
        if not EDGE_PREDICTIVE_TIMEOUT_ENABLED:
            return None
        if chapter_chars < max(1, EDGE_PREDICTIVE_TIMEOUT_CHARS):
            return None

        predicted_runtime = self._predict_edge_runtime_seconds(chapter_chars)
        threshold_s = max(120, int(EDGE_PREDICTIVE_TIMEOUT_SECONDS))
        if predicted_runtime >= threshold_s:
            return (
                f"predicted Edge runtime {int(predicted_runtime)}s for {chapter_chars:,} chars "
                f"(threshold {threshold_s}s)"
            )

        # Also treat very long narration as risky even with optimistic CPS.
        if estimated_seconds >= threshold_s:
            return (
                f"estimated narration {int(estimated_seconds)}s for {chapter_chars:,} chars "
                f"(threshold {threshold_s}s)"
            )
        return None

    def _apply_edge_rate_caps(self, configs: Iterable[ConversionConfig]) -> None:
        """Clamp Edge concurrency according to the selected voice."""
        for cfg in configs:
            if (cfg.engine or "").lower() != "edge":
                continue
            cap = self._resolve_edge_cap(cfg.voice)
            if not cap:
                continue
            current = cfg.edge_max_concurrency or cap
            cfg.edge_max_concurrency = max(1, min(cap, current))

    def _resolve_edge_cap(self, voice_id: Optional[str]) -> Optional[int]:
        if not voice_id:
            return None
        multilingual = self.tts_factory.voice_provider.edge_voice_is_multilingual(voice_id)
        if multilingual is None and isinstance(voice_id, str):
            multilingual = "multilingual" in voice_id.lower()
        if multilingual:
            return EDGE_MULTILINGUAL_RATE_CAP
        if multilingual is False:
            return EDGE_MONOLINGUAL_RATE_CAP
        return None

    def _prepare_auto_engines(
        self, base_config: ConversionConfig
    ) -> Dict[str, tuple[ConversionConfig, object]]:
        pool: Dict[str, tuple[ConversionConfig, object]] = {}
        for name in self._auto_engine_candidates(base_config):
            try:
                cloned = self._clone_engine_config(base_config, name)
                engine_instance = self.tts_factory.create_engine(cloned)
                pool[name] = (cloned, engine_instance)
            except Exception:
                continue
        return pool

    def _clone_engine_config(
        self, base_config: ConversionConfig, engine_name: str
    ) -> ConversionConfig:
        cloned = replace(base_config, engine=engine_name, voice=None, model_path=None)
        cloned.languages = list(base_config.languages)
        cloned.language_voices = {}
        prefer_monolingual = bool(getattr(base_config, "prefer_monolingual_edge", False))
        voice = self.tts_factory.voice_provider.get_voice(engine_name, cloned.primary_language)
        if engine_name == "edge" and prefer_monolingual:
            monolingual_voice = self.tts_factory.voice_provider.get_monolingual_voice(
                cloned.primary_language
            )
            if monolingual_voice:
                voice = monolingual_voice
        if engine_name == "coqui" and not voice:
            voice = "tts_models/multilingual/multi-dataset/xtts_v2"
        cloned.voice = voice
        cloned.language_voices = self.tts_factory.voice_provider.build_language_voice_map(
            engine_name,
            cloned.languages
            or (
                [cloned.primary_language]
                if cloned.primary_language and cloned.primary_language != "auto"
                else []
            ),
            voice,
            primary_language=cloned.primary_language,
        )
        if engine_name == "edge" and prefer_monolingual:
            lang_key = (cloned.primary_language or "").split("-", 1)[0]
            cloned.language_voices = (
                {lang_key: voice} if lang_key and voice else dict(cloned.language_voices)
            )
        return cloned

    def _pick_auto_engine(
        self,
        chapter_chars: int,
        estimated_seconds: float,
        pool: Dict[str, tuple[ConversionConfig, object]],
    ) -> tuple[str, List[str]]:
        """
        Pick the best engine for this chapter based on its size and runtime
        performance data.

        Priority order:
        1. Chapter-size-aware recommendation (uses per-bucket throughput data
           when available, otherwise heuristic based on chapter length).
        2. SpeedController global ranking (recent performance across all sizes).
        3. Static preferred order (network tier, config hints).
        """
        available_engines = list(pool.keys())

        if not available_engines:
            return ("edge", [])

        # --- 1. Chapter-size recommendation ---
        size_pick = self.speed_controller.recommend_engine_for_chapter(
            chapter_chars, available_engines
        )

        # --- 2. Global performance ranking (size-aware when enough samples) ---
        rankings = self.speed_controller.get_engine_ranking(
            available_engines, chapter_chars=chapter_chars
        )

        if self.verbose and rankings:
            print("📊 Engine Rankings (based on recent performance):")
            for engine, score, reason in rankings:
                marker = " ← size pick" if engine == size_pick else ""
                print(f"   {engine}: {score:.1f}/100 ({reason}){marker}")

        order = [engine for engine, _, _ in rankings]

        # --- 3. Fallback to static order ---
        if not order:
            order = self._preferred_auto_engine_order(pool)
        if not order:
            order = available_engines

        # Product decision: auto mode must always attempt Edge first.
        if "edge" in available_engines:
            order = ["edge"] + [e for e in order if e != "edge"]
            selected = "edge"
        elif size_pick and size_pick in available_engines:
            selected = size_pick
            if size_pick != order[0]:
                order = [size_pick] + [e for e in order if e != size_pick]
        else:
            selected = order[0]

        # Online A/B exploration to avoid lock-in to stale ranking.
        if self._auto_ab_enabled and len(order) >= 2 and "edge" not in available_engines:
            self._auto_ab_counter += 1
            if self._auto_ab_counter % self._auto_ab_interval == 0:
                score_by_engine = {engine: score for engine, score, _ in rankings}
                top_engine = order[0]
                alt_engine = order[1]
                top_score = float(score_by_engine.get(top_engine, 0.0))
                alt_score = float(score_by_engine.get(alt_engine, 0.0))
                if (top_score - alt_score) <= self._auto_ab_max_gap:
                    selected = alt_engine
                    order = [alt_engine] + [e for e in order if e != alt_engine]
                    self._append_runtime_metric(
                        {
                            "event": "auto_ab_exploration",
                            "selected_engine": alt_engine,
                            "baseline_engine": top_engine,
                            "score_gap": round(top_score - alt_score, 3),
                            "chapter_chars": int(chapter_chars or 0),
                        }
                    )
                    if self.verbose:
                        print(
                            f"🧪 AUTO A/B: exploring {alt_engine} "
                            f"(gap {top_score - alt_score:.1f} vs {top_engine})"
                        )

        # Check if speed controller recommends switching from current engine
        current = getattr(self.speed_controller, "_current_engine", None)
        if (
            current
            and current in available_engines
            and current != selected
            and "edge" not in available_engines
        ):
            switch_recommendation = self.speed_controller.recommend_engine_switch(
                current, available_engines, verbose=self.verbose
            )
            if switch_recommendation:
                new_engine, reason = switch_recommendation
                print(f"🔄 AUTO: Switching {current} → {new_engine}")
                print(f"   Reason: {reason}")
                selected = new_engine
                self.speed_controller.record_engine_switch(new_engine)

        return selected, order

    def _preferred_auto_engine_order(
        self, pool: Dict[str, tuple[ConversionConfig, object]]
    ) -> List[str]:
        order: List[str] = []
        # Product decision: keep Edge as default attempt; local engines are fallback-only.
        base_candidates = ["edge", "piper"]
        if _has_coqui_support():
            base_candidates.append("coqui")
        for candidate in base_candidates:
            if candidate in pool and candidate not in order:
                order.append(candidate)
        for name in pool:
            if name not in order:
                order.append(name)
        return order

    @staticmethod
    def _next_auto_engine(order: List[str], attempted: Set[str]) -> Optional[str]:
        for name in order:
            if name not in attempted:
                return name
        return None

    @staticmethod
    def _chapter_preview(text: str, limit: int = 180) -> str:
        if not text:
            return ""
        preview = " ".join(text.split())
        if len(preview) > limit:
            preview = preview[:limit].rstrip() + "…"
        return preview

    def _prioritize_chapters(self, chapters: List[Chapter], selectors: List[str]) -> List[Chapter]:
        if not selectors:
            return chapters

        prioritized: List[Chapter] = []
        seen_indices: Set[int] = set()
        selectors_normalized = [str(sel).strip().lower() for sel in selectors if str(sel).strip()]

        for selector in selectors_normalized:
            numeric_target: Optional[int] = None
            if selector.replace(".", "", 1).isdigit():
                try:
                    numeric_target = int(float(selector))
                except ValueError:
                    numeric_target = None
            for idx, chapter in enumerate(chapters):
                if idx in seen_indices:
                    continue
                chapter_num = self._chapter_number(chapter, idx + 1)
                display_name = self._chapter_display_name(chapter, chapter_num).lower()
                if numeric_target is not None and chapter_num == numeric_target:
                    prioritized.append(chapter)
                    seen_indices.add(idx)
                    break
                if selector in display_name:
                    prioritized.append(chapter)
                    seen_indices.add(idx)
                    break

        if not prioritized:
            return chapters

        # Keep prioritized chapters in natural book order (ascending index),
        # then append the remaining chapters also in natural order.
        prioritized_sorted = [
            chapter for idx, chapter in enumerate(chapters) if idx in seen_indices
        ]
        remaining = [chapter for idx, chapter in enumerate(chapters) if idx not in seen_indices]
        return prioritized_sorted + remaining

    def _install_requirements(self) -> bool:
        if self._requirements_attempted:
            return False
        self._requirements_attempted = True

        python_root = Path(__file__).resolve().parents[1]
        project_root = python_root.parent
        candidate_paths = [
            Path("requirements.txt"),
            Path.cwd() / "requirements.txt",
            python_root / "requirements.txt",
        ]
        requirements_path = next((path for path in candidate_paths if path.exists()), None)

        if requirements_path is None:
            print(self.loc.t("requirements_not_found"))
            return False

        print(self.loc.t("installing_requirements"))
        result = subprocess.run(
            [sys.executable, "-m", "pip", "install", "-r", str(requirements_path)],
            check=False,
            capture_output=True,
            text=True,
        )

        if result.returncode == 0:
            print(self.loc.t("requirements_success"))
            return True

        stderr = (result.stderr or "").lower()
        stdout = (result.stdout or "").lower()
        if "externally-managed-environment" in stderr or "externally-managed-environment" in stdout:
            if not os.getenv("EPUB2MP3_VENV_BOOTSTRAPPED"):
                venv_path = project_root / ".venv"
                venv_python = venv_path / "bin" / "python"
                try:
                    if not venv_python.exists():
                        print("🔧 Criando ambiente virtual local (.venv)...")
                        subprocess.run(
                            [sys.executable, "-m", "venv", str(venv_path)],
                            check=False,
                        )
                    if venv_python.exists():
                        print("📦 Installing dependencies in .venv...")
                        subprocess.run(
                            [
                                str(venv_python),
                                "-m",
                                "pip",
                                "install",
                                "-r",
                                str(requirements_path),
                            ],
                            check=False,
                        )
                        os.environ["EPUB2MP3_VENV_BOOTSTRAPPED"] = "1"
                        os.execv(str(venv_python), [str(venv_python)] + sys.argv)
                except Exception:
                    pass

        print(self.loc.t("requirements_failure"))
        return False
