# -*- coding: utf-8 -*-
"""Bounded parallel chapter scheduling and progress."""

from __future__ import annotations

import asyncio
from pathlib import Path
from typing import Dict, Iterable, List, Optional

from .config import ConversionConfig
from .converter_models import ConversionResult
from .ebook_reader import Chapter
from .engine_pool import JobEnginePool


class ConverterParallelScheduler:
    """Bounded parallel chapter scheduling and progress."""

    async def _convert_chapters_parallel(
        self,
        chapters: Iterable[Chapter],
        engine_pool: JobEnginePool,
        output_dir: Path,
        config: ConversionConfig,
        max_concurrent_chapters: int = 3,
        *,
        skip_preprocessing: bool = False,
        is_auto_engine: bool = False,
        auto_engine_pool: Optional[Dict[str, tuple[ConversionConfig, object]]] = None,
        book_title: str = "",
        book_author: str = "",
        cover_art: Optional[dict] = None,
    ) -> ConversionResult:
        """Convert multiple chapters in parallel for maximum throughput."""
        from . import converter as _runtime
        chapters_list = list(chapters)
        selected_indices_raw = (config.extra.get("selected_indices") or "").strip()
        if selected_indices_raw:
            allowed = {item.strip() for item in selected_indices_raw.split(",") if item.strip()}
            if allowed:
                chapters_list = [ch for ch in chapters_list if str(ch.index) in allowed]
        if not chapters_list:
            return _runtime.ConversionResult(True, 0, 0, [], [])

        chapters_for_text = list(chapters_list)
        bounded_prepare_enabled = _runtime._env_bool("CLI_BOUNDED_PREPARE", False)
        bounded_prepare_raw = (getattr(config, "extra", {}) or {}).get("bounded_prepare")
        if bounded_prepare_raw is not None:
            bounded_prepare_enabled = str(bounded_prepare_raw).strip().lower() in {
                "1",
                "true",
                "yes",
                "on",
            }

        # Bucketize by size (largest first) to reduce tail latency and lock contention
        chapters_sorted = sorted(chapters_list, key=self._estimate_chapter_chars, reverse=True)

        total_chapters = len(chapters_sorted)
        recommended = max(1, int(max_concurrent_chapters or 1))
        self._parallel_state.setdefault("ceiling", recommended)
        self._parallel_state["ceiling"] = recommended
        self._parallel_state["current"] = max(
            1, min(recommended, int(self._parallel_state.get("current") or recommended))
        )
        print(
            f"🚀 Parallel mode: processing {total_chapters} chapters (current {self._parallel_state['current']} concurrent)"
        )

        # If preprocessing already done by caller, skip duplicate work
        if not skip_preprocessing:
            # Validate and clean cache (once for all chapters)
            self._validate_and_clean_cache(chapters_for_text, output_dir, config)

            generated_text = False
            cleanup_existing = bool(
                getattr(config, "force_reprocess", False) or getattr(config, "clear_cache", False)
            )
            if not bounded_prepare_enabled and getattr(config, "auto_validate_output", True):
                self._generate_all_text_files(
                    chapters_for_text, output_dir, config, cleanup_existing=cleanup_existing
                )
                generated_text = True

            # Fast-path cache check before generating text (partial-aware)
            cached_audio, pending_chapters = self._split_cached_chapters(
                chapters_for_text, output_dir, config, allow_index_only=True
            )

            # Generate all text files (once for all chapters) if needed
            if pending_chapters and not generated_text and not bounded_prepare_enabled:
                self._generate_all_text_files(
                    chapters_for_text, output_dir, config, cleanup_existing=cleanup_existing
                )

                # Retry cache check after text generation (allows hash validation)
                cached_audio, pending_chapters = self._split_cached_chapters(
                    chapters_for_text, output_dir, config, allow_index_only=False
                )

            if cached_audio and not pending_chapters:
                print(
                    f"♻️ All {len(chapters_list)} chapter(s) already cached (MP3) — skipping synthesis"
                )
                for _ in chapters_list:
                    self.progress.tick("✅ Complete (cache)") if hasattr(self, "progress") else None
                if getattr(config, "auto_validate_output", True):
                    await self._auto_validate_output(output_dir, stage="cache-only")
                return _runtime.ConversionResult(
                    success=True,
                    total_chapters=len(chapters_for_text),
                    converted_chapters=len(chapters_for_text),
                    output_files=cached_audio,
                    errors=[],
                )

            if cached_audio and pending_chapters:
                print(
                    f"♻️ Cache detected: {len(cached_audio)} chapter(s) ready; "
                    f"converting {len(pending_chapters)} remaining"
                )

            pending_chapters = sorted(
                pending_chapters,
                key=self._estimate_chapter_chars,
                reverse=True,
            )

            self._assign_progress_indices(pending_chapters)
            chapters_list = pending_chapters
        else:
            # Preprocessing done by caller - no cached files to track here
            cached_audio = []

        all_converted_files: List[Path] = []
        all_errors: List[str] = []
        converted_total = 0

        # **OPTIMIZED**: Dynamic task completion - eliminates batch starvation
        # Process chapters with max concurrency, starting new tasks as any task completes
        pending_tasks = {}  # task -> chapter
        chapter_iter = iter(chapters_list)
        batch_start = _runtime.time.time()

        # Compute multi-engine slot affinity (default off; needs explicit opt-in).
        _me_requested = (
            bool((config.extra or {}).get("multi_engine_parallel")) and not is_auto_engine
        )
        cli_slot_affinity: list[str] = []
        if _me_requested and not is_auto_engine:
            _me_engines: list[str] = []
            if (config.engine or "").lower() not in {"", "auto"}:
                _me_engines.append((config.engine or "").lower())
            # Add local engines from auto_engine_pool if available
            for name in auto_engine_pool or {}:
                if name not in _me_engines:
                    _me_engines.append(name)
            # Dynamic edge fraction: proportional to relative telemetry speed.
            _tele = getattr(self, "telemetry", None)
            _tele_summary = _tele.summary() if _tele else {}
            _edge_spd = float((_tele_summary.get("edge") or {}).get("avg_chars_per_second") or 0.0)
            _local_spds = [
                float((_tele_summary.get(e) or {}).get("avg_chars_per_second") or 0.0)
                for e in _me_engines[1:]
            ]
            _best_local = max(_local_spds) if _local_spds else 0.0
            if _edge_spd > 0 and _best_local > 0:
                _edge_frac = _edge_spd / (_edge_spd + _best_local)
                _edge_frac = max(0.50, min(0.85, _edge_frac))
            else:
                _edge_frac = float(_runtime.os.getenv("MULTI_ENGINE_EDGE_FRACTION", "0.67"))
            cli_slot_affinity = _runtime._build_multi_engine_slot_map(
                recommended,
                _me_engines,
                edge_fraction=_edge_frac,
            )
            if cli_slot_affinity:
                counts = {e: cli_slot_affinity.count(e) for e in dict.fromkeys(cli_slot_affinity)}
                print(
                    "⚡ Multi-engine parallel: " + ", ".join(f"{e}×{n}" for e, n in counts.items())
                )

        # Hard per-chapter deadline — last-line defence against silent stalls
        # where neither per-segment nor stall watchdogs fire (e.g. a chapter
        # hung deep in post-TTS validation/encoding emits no heartbeat).
        # Without this, the outer `asyncio.wait(FIRST_COMPLETED)` would block
        # forever. Override via CLI_CHAPTER_HARD_TIMEOUT_SECONDS (0 disables).
        try:
            hard_chapter_timeout = float(_runtime.os.getenv("CLI_CHAPTER_HARD_TIMEOUT_SECONDS", "900"))
        except (TypeError, ValueError):
            hard_chapter_timeout = 900.0

        async def _chapter_with_deadline(coro, chapter_label: str, chapter_chars: int = 0):
            if hard_chapter_timeout <= 0:
                return await coro
            # Scale timeout for large chapters: base 900s + 15s per 1K chars
            # over 20K.  A 100K-char chapter gets 900 + 1200 = 2100s.
            effective_timeout = hard_chapter_timeout
            if chapter_chars > 20_000:
                extra = (chapter_chars - 20_000) / 1000.0 * 15.0
                effective_timeout = hard_chapter_timeout + extra
            try:
                return await _runtime.asyncio.wait_for(coro, timeout=effective_timeout)
            except _runtime.asyncio.TimeoutError:
                msg = (
                    f"Chapter {chapter_label} cancelled after hard timeout "
                    f"{int(effective_timeout)}s"
                )
                print(f"\n⏱️  {msg}")
                return _runtime.ConversionResult(
                    success=False,
                    total_chapters=1,
                    converted_chapters=0,
                    output_files=[],
                    errors=[msg],
                )

        # Helper to create chapter task
        def create_chapter_task(
            chapter: Chapter, preferred_engine: Optional[str] = None
        ) -> asyncio.Task:
            task_config = config
            if preferred_engine and not is_auto_engine:
                from dataclasses import replace as _dc_replace

                task_config = _dc_replace(config, engine=preferred_engine)
            chapter_label = str(getattr(chapter, "index", "?"))
            ch_chars = len(getattr(chapter, "text", "") or "")
            inner_coro = self._convert_chapters_sequential(
                [chapter],
                engine_pool,
                output_dir,
                task_config,
                is_auto_engine=is_auto_engine,
                auto_engine_pool=auto_engine_pool,
                book_title=book_title,
                book_author=book_author,
                cover_art=cover_art,
                skip_preprocessing=True,  # Preprocessing already done by parallel caller
            )
            task = _runtime.asyncio.create_task(_chapter_with_deadline(inner_coro, chapter_label, ch_chars))
            self._inflight_chapter_tasks.add(task)
            task.add_done_callback(self._inflight_chapter_tasks.discard)
            return task

        parallel_slots = int(self._parallel_state.get("current", recommended) or recommended)
        parallel_slots = max(1, min(parallel_slots, recommended))
        engine_pool.update_parallel_slots(parallel_slots)

        overall_start = _runtime.time.time()
        batch_chars = 0
        total_chars_processed = 0
        batch_errors = 0
        completed_since_tune = 0
        slot_task_engine: dict[_runtime.asyncio.Task, str] = {}

        for slot_idx in range(min(parallel_slots, total_chapters)):
            try:
                chapter = next(chapter_iter)
                pref = cli_slot_affinity[slot_idx] if slot_idx < len(cli_slot_affinity) else None
                task = create_chapter_task(chapter, preferred_engine=pref)
                pending_tasks[task] = chapter
                slot_task_engine[task] = pref or ""
            except StopIteration:
                break

        while pending_tasks:
            done, _ = await _runtime.asyncio.wait(pending_tasks.keys(), return_when=_runtime.asyncio.FIRST_COMPLETED)

            freed_slot_engines: list[str] = []
            for task in done:
                chapter = pending_tasks.pop(task)
                freed_slot_engines.append(slot_task_engine.pop(task, ""))
                chapter_chars = self._estimate_chapter_chars(chapter)
                batch_chars += chapter_chars
                total_chars_processed += chapter_chars
                completed_since_tune += 1

                try:
                    result = task.result()
                    if isinstance(result, Exception):
                        all_errors.append(str(result))
                        batch_errors += 1
                    elif isinstance(result, _runtime.ConversionResult):
                        all_converted_files.extend(result.output_files)
                        all_errors.extend(result.errors)
                        converted_total += result.converted_chapters
                        batch_errors += len(result.errors)
                except Exception as exc:
                    all_errors.append(str(exc))
                    batch_errors += 1

            tuned_slots = int(self._parallel_state.get("current") or parallel_slots)
            if tuned_slots < parallel_slots:
                parallel_slots = max(1, tuned_slots)
                engine_pool.update_parallel_slots(parallel_slots)

            # Refill freed slots, preserving engine affinity.
            for freed_engine in freed_slot_engines:
                if len(pending_tasks) >= parallel_slots:
                    break
                try:
                    chapter = next(chapter_iter)
                    pref = freed_engine if (freed_engine and cli_slot_affinity) else None
                    task = create_chapter_task(chapter, preferred_engine=pref)
                    pending_tasks[task] = chapter
                    slot_task_engine[task] = pref or ""
                except StopIteration:
                    break

            if completed_since_tune >= 2:
                elapsed = max(_runtime.time.time() - batch_start, 0.001)
                throughput = (batch_chars / elapsed) if batch_chars else None
                new_slots, reason = self._auto_tune_parallelism(
                    throughput=throughput,
                    batch_errors=batch_errors,
                )
                if new_slots != parallel_slots:
                    parallel_slots = new_slots
                    engine_pool.update_parallel_slots(parallel_slots)
                    if reason:
                        print(f"⚙️ {reason}")
                batch_start = _runtime.time.time()
                batch_chars = 0
                batch_errors = 0
                completed_since_tune = 0

                # Clean up resources periodically to reduce memory usage
                if converted_total % 10 == 0:  # Every 10 chapters
                    self._cleanup_resources(force_gc=False)

        batch_elapsed = max(_runtime.time.time() - overall_start, 0.001)

        # Calculate final metrics
        batch_throughput = (
            (total_chars_processed / batch_elapsed) if total_chars_processed else None
        )
        if batch_throughput and self.verbose:
            print(
                f"   📈 Dynamic processing: ~{int(batch_throughput)} chars/s ({int(batch_elapsed)}s total)"
            )

        # All chapters processed dynamically
        if cached_audio:
            all_converted_files = list(cached_audio) + all_converted_files
            converted_total = len(all_converted_files)

        # **INTEGRITY VALIDATION**: Verify all chapters from EPUB are present in audio output
        self._print_final_validation_report(
            chapters=chapters,
            converted_files=all_converted_files,
            errors=all_errors,
            output_dir=output_dir,
            verbose=self.verbose,
        )

        # **DEEP VALIDATION**: Automatic comprehensive validation
        # Verifies duplicates, start/middle/end content, and character counts
        # Skip when chapter filter is active (only validate requested chapters)
        chapter_filter_active = bool(self._parse_chapter_whitelist(config)) or bool(
            (config.extra or {}).get("selected_indices", "").strip()
        )
        deep_validation_requested = bool(getattr(config, "deep_validate", False))
        deep_validation_passed = True
        if (
            deep_validation_requested
            and self._current_book_path
            and len(all_errors) == 0
            and not chapter_filter_active
        ):
            try:
                from .deep_validator import run_deep_validation

                cache_path = output_dir
                report = run_deep_validation(str(self._current_book_path), str(cache_path))
                deep_validation_passed = report.success

                if not deep_validation_passed:
                    # Retry once: re-save parsed text for failed chapters and re-validate
                    from .deep_validator import DeepValidator

                    # Extract indices of failed chapters from their filenames
                    failed_indices = set()
                    for c in report.comparisons:
                        if not c.is_valid:
                            idx = DeepValidator._extract_chapter_index(c.chapter_id)
                            if idx:
                                failed_indices.add(idx)

                    if failed_indices and self.verbose:
                        print(
                            f"🔄 Re-saving {len(failed_indices)} failed chapter(s) from EbookReader..."
                        )

                    if failed_indices:
                        dv = DeepValidator(str(self._current_book_path), str(cache_path))
                        if dv.load_epub_chapters():
                            text_dir = cache_path / "text"
                            # Overwrite parsed files for failed chapters
                            for ch in dv._chapter_list:
                                if str(ch.index) in failed_indices:
                                    # Find the actual parsed file by glob
                                    pattern = f"{ch.index} - *-parsed.txt"
                                    for pf in text_dir.glob(pattern):
                                        ch_text = ch.text or ""
                                        pf.write_text(ch_text, encoding="utf-8")

                    # Re-run validation
                    report = run_deep_validation(str(self._current_book_path), str(cache_path))
                    deep_validation_passed = report.success

                    if not deep_validation_passed and self.verbose:
                        print("⚠️  Deep validation still has issues after retry.")
            except Exception as e:
                if self.verbose:
                    print(f"⚠️  Deep validation failed to run: {e}")

        return _runtime.ConversionResult(
            success=len(all_errors) == 0 and deep_validation_passed,
            total_chapters=total_chapters,
            converted_chapters=converted_total or len(all_converted_files),
            output_files=all_converted_files,
            errors=all_errors,
        )
