# -*- coding: utf-8 -*-
"""Book engine preparation."""

from __future__ import annotations

from typing import Dict

from .config import ConversionConfig
from .conversion_control import ConversionControl as _ConversionControl
from .ebook_reader import Chapter


async def _book_engine_preparation(self, _state):
    from . import converter as _runtime
    _state.chapter_lookup: Dict[str, tuple[Chapter, int, str]] = {}
    for _state.idx, _state.chapter in enumerate(_state.chapters, start=1):
        _state.chapter_num = self._chapter_number(_state.chapter, _state.idx)
        _state.label = self._chapter_display_name(_state.chapter, _state.chapter_num)
        self._register_chapter_lookup(_state.chapter_lookup, _state.label, _state.chapter, _state.chapter_num)

    if self.verbose:
        print(f"[DEBUG] Total chapters: {_state.total_chapters}")
        print(f"[DEBUG] Output directory: {_state.output_dir}")
        print(f"[DEBUG] Temporary directory: {_state.temp_dir}")

    if _state.chapters:
        self._normalize_output_numbers(_state.chapters, _state.output_dir, _state.config, temp_dir=_state.temp_dir)

    print(f"\n🚀 Starting conversion: {_state.reader.title} ({_state.total_chapters} chapters)")
    print(f"💾 Output: {_state.output_dir}")

    # Show validation status
    _state.validate_text = getattr(_state.config, "validate_text", True)
    _state.validate_audio = getattr(_state.config, "validate_audio", True)
    if _state.validate_text and _state.validate_audio:
        print("  ✅ Validations: Text and audio enabled")
    elif _state.validate_text:
        print("  ⚠️ Validations: Text only")
    elif _state.validate_audio:
        print("  ⚠️ Validations: Audio only")
    else:
        print("  ⚠️ Validations: Disabled (--no-validate)")

    _state.edge_stable_mode = False
    _state.edge_stable_explicit = False
    if getattr(_state.config, "extra", None):
        _state.stable_raw = _state.config.extra.get("edge_stable_mode")
        if _state.stable_raw is not None:
            _state.edge_stable_explicit = True
            _state.edge_stable_mode = str(_state.stable_raw).lower() in {"1", "true", "yes", "on"}
    if (
        not _state.edge_stable_explicit
        and _runtime.EDGE_AUTO_STABLE
        and (_state.config.engine or "").lower() == "edge"
    ):
        _state.inferred_tier = None
        if self.hardware_profile:
            _state.inferred_tier = getattr(self.hardware_profile, "network_speed_estimate", None)
        if not _state.inferred_tier:
            _state.inferred_tier = _runtime.os.getenv("EDGE_NETWORK_TIER")
        _state.inferred_tier = (_state.inferred_tier or "").strip().lower()
        if _state.inferred_tier == "slow":
            _state.edge_stable_mode = True
            if getattr(_state.config, "extra", None) is not None:
                _state.config.extra["edge_stable_mode"] = "1"
            print("🛡️ Edge automatic stable mode: slow network detected")
    if _state.edge_stable_mode and (_state.config.engine or "").lower() == "edge":
        _state.config.edge_enable_parallel = False
        _state.config.edge_auto_tune = False
        _state.config.edge_chunk_chars = 4000
        _state.config.edge_max_segment_seconds = 120
        print("🛡️ Edge stable mode: reduced parallelism and extended timeouts")
    # Auto-parallel: prefer env override, else derive from hardware profile
    # Aggressive defaults: use all available CPU cores for maximum throughput
    _state.chapter_parallel_count = int(_runtime.os.getenv("CHAPTER_PARALLEL_COUNT", "0") or "0")
    _state.network_tier = ""
    if _state.chapter_parallel_count <= 0:
        _state.cpu_logical = _runtime.os.cpu_count() or 1
        _state.cpu_physical = 0
        with _runtime.contextlib.suppress(Exception):
            _state.cpu_physical = _runtime.psutil.cpu_count(logical=False) or 0
        _state.ram_total = 0.0
        _state.ram_available = 0.0
        if self.hardware_profile is not None:
            _state.ram_total = float(getattr(self.hardware_profile, "ram_total_gb", 0.0) or 0.0)
            _state.ram_available = float(
                getattr(self.hardware_profile, "ram_available_gb", 0.0) or 0.0
            )
            _state.network_tier = str(
                getattr(self.hardware_profile, "network_speed_estimate", "") or ""
            ).lower()
        _state.engine_is_edge = (_state.config.engine or "").lower() == "edge"
        if _state.cpu_physical >= 8:
            _state.chapter_parallel_count = min(
                16 if _state.engine_is_edge else 8, _state.cpu_logical * (2 if _state.engine_is_edge else 1)
            )
        elif _state.cpu_physical >= 4:
            _state.chapter_parallel_count = min(
                12 if _state.engine_is_edge else 6, _state.cpu_logical * (2 if _state.engine_is_edge else 1)
            )
        elif _state.cpu_physical >= 2:
            _state.chapter_parallel_count = min(
                8 if _state.engine_is_edge else 4, _state.cpu_logical * (2 if _state.engine_is_edge else 1)
            )
        else:
            _state.chapter_parallel_count = 4 if _state.engine_is_edge else 2
        # Resource-aware conservative defaults for stability/throughput.
        if (_state.ram_total and _state.ram_total <= 8.5) or (_state.ram_available and _state.ram_available <= 2.5):
            _state.chapter_parallel_count = min(_state.chapter_parallel_count, 2)
        if _state.network_tier in {"slow", "medium"}:
            _state.chapter_parallel_count = min(_state.chapter_parallel_count, 1)
    if _state.edge_stable_mode and _state.chapter_parallel_count != 1:
        _state.chapter_parallel_count = 1
    self._reset_parallel_state(_state.chapter_parallel_count)

    if _state.total_chapters == 0:
        self._record_effective_runtime_profile(
            config=_state.config,
            edge_engine=None,
            chapter_parallel_count=_state.chapter_parallel_count,
            network_tier=_state.network_tier or "unknown",
            edge_cap=0,
            output_dir=_state.temp_dir,
        )
        _state.empty_result = _runtime.ConversionResult(
            False,
            0,
            0,
            [],
            [f"No readable chapters were extracted from {_state.reader.title}"],
        )
        await self._report_results(_state.empty_result)
        return _ConversionControl("return", _state.empty_result)

    # Fast-path cache check before heavy prep (uses existing text/cache index if present)
    _state.cached_paths, _state.pending_chapters = self._split_cached_chapters(
        _state.chapters, _state.temp_dir, _state.config, allow_index_only=True
    )

    # **NEW**: Generate ALL .txt files BEFORE starting TTS conversion (unless fully cached)
    if _state.pending_chapters:
        print("\n📝 Generating text files...")
        self._generate_all_text_files(_state.chapters, _state.temp_dir, _state.config, cleanup_existing=False)
        print(f"  ✅ Generated {_state.total_chapters} text file(s)\n")
        _state.cached_paths, _state.pending_chapters = self._split_cached_chapters(
            _state.chapters, _state.temp_dir, _state.config, allow_index_only=False
        )

    _state.cover_art = self._extract_cover_art(_state.reader)
    _state.book_title = (
        _state.reader.title
        or getattr(_state.config, "book_title", None)
        or (self._current_book_path.stem if self._current_book_path else "")
    )
    _state.book_author = getattr(_state.reader, "author", "") or ""
    if _state.cached_paths and _state.pending_chapters:
        print(
            f"  ♻️ Cache detected: {len(_state.cached_paths)} chapter(s) ready; "
            f"converting {len(_state.pending_chapters)} remaining"
        )
    elif _state.cached_paths and not _state.pending_chapters:
        print(f"  ♻️ All {len(_state.cached_paths)} chapter(s) already cached (MP3)")

    _state.pending_total = len(_state.pending_chapters)
    self._start_health_watchdog(_state.pending_total)
    self._engine_warmup_done.clear()
    self._assign_progress_indices(_state.pending_chapters)
    self.progress.start(_state.pending_total, description="Converting chapters")

    if _state.pending_total == 0:
        _state.moved_files = self.file_manager.move_files_to_final_output(_state.temp_dir, _state.output_dir)
        # Run dedup BEFORE applying ID3 tags so we don't waste cycles
        # tagging files that are about to be deleted, and BEFORE
        # building the final result so the file count is accurate.
        # The auto-fix-and-retry pipeline only runs dedup when there
        # are validation problems; the all-cached fast path used to
        # skip it entirely, so leftover duplicates from earlier runs
        # accumulated forever (the v0.3.18 Carl conversion ended up
        # with 64 MP3s for 61 chapters because of this).
        if self._duplicate_cleanup_enabled(_state.config):
            _state.dedup_removed = self._dedup_chapter_outputs(_state.output_dir)
            if _state.dedup_removed:
                print(
                    f"   🧹 Auto-dedup (cache-hit path): removed {_state.dedup_removed} duplicate MP3(s)"
                )
        _state.result = _runtime.ConversionResult(
            success=True,
            total_chapters=_state.total_chapters,
            converted_chapters=_state.total_chapters,
            output_files=_state.moved_files or _state.cached_paths,
            errors=[],
        )
        _state.normalized_outputs = self._normalize_output_numbers(_state.chapters, _state.output_dir, _state.config)
        if _state.normalized_outputs:
            _state.result.output_files = _state.normalized_outputs
        # Apply ID3 tags (including cover art) to ALL MP3s in output dir
        _state.album_name = _state.book_title or (
            self._current_book_path.stem if self._current_book_path else _state.output_dir.name
        )
        _state.all_output_mp3s = sorted(_state.output_dir.glob("*.mp3")) if _state.output_dir.exists() else []
        if _state.all_output_mp3s:
            self._apply_final_id3_tags(
                _state.all_output_mp3s,
                default_album=_state.album_name,
                artist=_state.book_author or None,
                cover_art=_state.cover_art,
            )
        self._sync_text_cache_to_output(_state.temp_dir, _state.output_dir)
        self.progress.finish()
        self._write_runtime_metrics_summary(_state.temp_dir)
        self._write_runtime_metrics_csv(_state.temp_dir)
        self._write_runtime_metrics_dashboard(_state.temp_dir)
        self._write_segment_metrics_summary(_state.temp_dir)
        self._write_segment_metrics_csv(_state.temp_dir)
        self._write_segment_metrics_dashboard(_state.temp_dir)
        self._write_runtime_recommendations(_state.temp_dir)
        await self._report_results(_state.result)
        return _ConversionControl("return", _state.result)

    _state.is_auto_engine = (_state.config.engine or "").lower() == "auto"
    _state.auto_engine_pool: Dict[str, tuple[ConversionConfig, object]] = {}
    _state.engine_seeds: Dict[str, object] = {}
    try:
        if _state.is_auto_engine:
            _state.auto_engine_pool = self._prepare_auto_engines(_state.config)
            if not _state.auto_engine_pool:
                raise RuntimeError("No engine available in automatic mode")
            for _state.name, (_state._, _state.engine_obj) in _state.auto_engine_pool.items():
                if _state.engine_obj is not None:
                    _state.engine_seeds[_state.name.lower()] = _state.engine_obj
            _state.tts_engine = None
        else:
            _state.tts_engine = self.tts_factory.create_engine(_state.config)
            _state.engine_seeds[(_state.config.engine or "").lower()] = _state.tts_engine
    except ImportError:
        if self._install_requirements():
            if _state.is_auto_engine:
                _state.auto_engine_pool = self._prepare_auto_engines(_state.config)
                if not _state.auto_engine_pool:
                    raise RuntimeError("No engine available in automatic mode")
                _state.engine_seeds = {
                    name.lower(): engine_obj
                    for name, (_, engine_obj) in _state.auto_engine_pool.items()
                    if engine_obj is not None
                }
                _state.tts_engine = None
            else:
                _state.tts_engine = self.tts_factory.create_engine(_state.config)
                _state.engine_seeds[(_state.config.engine or "").lower()] = _state.tts_engine
        else:
            raise
    for _state.engine_name, _state.engine_obj in _state.engine_seeds.items():
        if _state.engine_name.lower() == "edge":
            self._attach_edge_metric_sink(_state.engine_obj, _state.temp_dir)
    if _state.is_auto_engine:
        _state.voice_label = "Auto (Edge/Piper)"
    else:
        _state.primary_engine = _state.engine_seeds.get((_state.config.engine or "").lower())
        _state.voice_label = getattr(_state.primary_engine, "voice", None) or _state.config.voice or "(auto)"
    print(f"🎙️ Engine: {_state.config.engine} | Voice: {_state.voice_label}")
    if getattr(_state.config, "languages", None):
        print(f"🌐 Languages: {', '.join(_state.config.languages)}")

    _state.has_edge_engine = (_state.config.engine or "").lower() == "edge"
    if _state.is_auto_engine and _state.auto_engine_pool:
        _state.has_edge_engine = _state.has_edge_engine or "edge" in _state.auto_engine_pool
    _state.edge_network_tier = (
        getattr(self.hardware_profile, "network_speed_estimate", None)
        if self.hardware_profile
        else None
    )
    if not _state.edge_network_tier:
        _state.edge_network_tier = _runtime.os.getenv("EDGE_NETWORK_TIER", "fast")
    _state.edge_network_tier = (_state.edge_network_tier or "fast").strip().lower()
    if _state.edge_network_tier not in _runtime.EDGE_AUTO_PARALLEL_CAPS:
        _state.edge_network_tier = "fast"
    self._apply_detected_runtime_defaults(
        _state.config,
        network_tier=_state.edge_network_tier,
        auto_engine_pool=_state.auto_engine_pool if _state.is_auto_engine else None,
    )
    if _state.is_auto_engine:
        for _state.name, (_state.pool_cfg, _state.pool_engine_obj) in _state.auto_engine_pool.items():
            self._apply_persisted_engine_params(
                cfg=_state.pool_cfg,
                engine_label=_state.name,
                engine_obj=_state.pool_engine_obj,
            )
    else:
        self._apply_persisted_engine_params(
            cfg=_state.config,
            engine_label=(_state.config.engine or "").lower(),
            engine_obj=_state.engine_seeds.get((_state.config.engine or "").lower()),
        )
