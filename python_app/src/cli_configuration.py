"""Configuration for the retained legacy CLI."""

from .cli_runtime_dependencies import (
    Any as Any,
    ConversionConfig as ConversionConfig,
    Dict as Dict,
    EbookReader as EbookReader,
    argparse as argparse,
)

class CLIConfiguration:
    def _get_conversion_config(self, args: argparse.Namespace, reader: EbookReader):
        """Get conversion configuration"""
        formatting_cues_pref = getattr(args, "formatting_cues", None)
        if getattr(args, "menu", False):
            config = self.menu.get_conversion_config(
                reader,
                language_profile=self.language_profile,
                formatting_cues=formatting_cues_pref,
            )
            if config:
                if getattr(args, "listen", False):
                    config.listen = True
                cache_dir = getattr(args, "cache_dir", None)
                if cache_dir:
                    config.cache_dir = self._cli_runtime.Path(cache_dir)
                config.clear_cache = getattr(args, "clear_cache", False)
                config.footnote_mode = self._resolve_footnote_mode(args)
                config.footnote_context_words = self.FOOTNOTE_CONTEXT_WORDS
                self._apply_language_preferences(config)
                cues_enabled = (
                    formatting_cues_pref
                    if formatting_cues_pref is not None
                    else getattr(config, "speak_formatting_cues", True)
                )
                config.speak_formatting_cues = bool(cues_enabled)
                config.formatting_locale = self.localization.language
                self._cli_runtime.apply_benchmark_profile(config.engine, config=config)
                self._apply_cli_overrides(args, config)
            return config
        config = self._create_config_from_args(args, reader)
        self._apply_language_preferences(config)
        self._cli_runtime.apply_benchmark_profile(config.engine, config=config)
        self._apply_cli_overrides(args, config)
        return config

    def _create_config_from_args(self, args: argparse.Namespace, reader: EbookReader):
        """Create config from command line arguments"""
        verbose = self._resolve_verbose(args)
        formatting_cues_pref = getattr(args, "formatting_cues", None)
        cues_enabled = True if formatting_cues_pref is None else bool(formatting_cues_pref)
        primary_language = self._normalize_language_override(getattr(args, "language", None))
        edge_chunk_chars = self._clamp_int(
            getattr(args, "edge_chunk_chars", None), min_value=4000, max_value=24000
        )
        edge_max_segment_seconds = self._clamp_int(
            getattr(args, "edge_max_segment_seconds", None), min_value=30, max_value=600
        )
        piper_max_procs = self._clamp_int(
            getattr(args, "piper_max_procs", None), min_value=1, max_value=12
        )
        piper_chunk_chars = self._clamp_int(
            getattr(args, "piper_chunk_chars", None), min_value=800, max_value=12000
        )
        sample_rate = self._clamp_int(
            getattr(args, "sample_rate", None), min_value=8000, max_value=96000
        )
        channels = self._clamp_int(getattr(args, "channels", None), min_value=1, max_value=2)
        overrides: Dict[str, Any] = {}
        if primary_language:
            overrides["primary_language"] = primary_language
        if edge_chunk_chars is not None:
            overrides["edge_chunk_chars"] = edge_chunk_chars
        if edge_max_segment_seconds is not None:
            overrides["edge_max_segment_seconds"] = edge_max_segment_seconds
        if getattr(args, "edge_enable_parallel", None) is not None:
            overrides["edge_enable_parallel"] = bool(getattr(args, "edge_enable_parallel"))
        if getattr(args, "edge_auto_tune", None) is not None:
            overrides["edge_auto_tune"] = bool(getattr(args, "edge_auto_tune"))
        if piper_max_procs is not None:
            overrides["piper_max_procs"] = piper_max_procs
        if piper_chunk_chars is not None:
            overrides["piper_chunk_chars"] = piper_chunk_chars
        if getattr(args, "bitrate", None):
            overrides["bitrate"] = str(getattr(args, "bitrate"))
        if sample_rate is not None:
            overrides["sample_rate"] = sample_rate
        if channels is not None:
            overrides["channels"] = channels

        # Validation settings
        if getattr(args, "verify_transcription", None) is not None:
            overrides["verify_transcription"] = bool(args.verify_transcription)
        if getattr(args, "transcription_model", None):
            overrides["transcription_model"] = str(args.transcription_model)
        if getattr(args, "validation_language", None):
            overrides["validation_language"] = str(args.validation_language)
        if getattr(args, "validate_during_conversion", False):
            overrides["validate_text"] = True
            overrides["validate_audio"] = True
        if getattr(args, "validate_text", None) is not None:
            overrides["validate_text"] = bool(getattr(args, "validate_text"))
        if getattr(args, "validate_audio", None) is not None:
            overrides["validate_audio"] = bool(getattr(args, "validate_audio"))
        if getattr(args, "strict_validate", False):
            overrides["strict_validate"] = True
        if getattr(args, "auto_validate_output", None) is not None:
            overrides["auto_validate_output"] = bool(getattr(args, "auto_validate_output"))
        if getattr(args, "auto_fix_output", None) is not None:
            overrides["auto_fix_output"] = bool(getattr(args, "auto_fix_output"))

        # "auto" is a UI-friendly alias kept for parity with the web form.
        engine_choice = args.engine or "edge"
        if engine_choice == "auto":
            engine_choice = "edge"
        if engine_choice == "rust":
            raise RuntimeError(
                "The Rust backend is invoked through the Rust CLI; use "
                "./convert-rust or mise exec -- cargo run -p converter-cli -- ..."
            )
        config = self.config.create_conversion_config(
            engine=engine_choice,
            voice=args.voice,
            model=args.model,
            output_dir=args.output_dir or str(self._cli_runtime.OUTPUT_DIR),
            book_title=reader.title,
            preserve_all_chapters=not getattr(args, "filter_chapters", False),
            use_simple_converter=False,
            listen=getattr(args, "listen", False),
            cache_dir=getattr(args, "cache_dir", None),
            clear_cache=getattr(args, "clear_cache", False),
            footnote_mode=self._resolve_footnote_mode(args),
            footnote_context_words=self.FOOTNOTE_CONTEXT_WORDS,
            verbose=verbose,
            priority_selectors=getattr(args, "priority", []) or [],
            speak_formatting_cues=cues_enabled,
            formatting_locale=self.localization.language,
            max_auto_retries=getattr(args, "retry_failed_rounds", None),
            manual_retry_failed=getattr(args, "retry_failed_manual", False),
            force_reprocess=bool(
                getattr(args, "force_reprocess", False) or getattr(args, "no_cache", False)
            ),
            **overrides,
        )
        # Optional title-pause injection (off by default, opt-in via
        # --inject-title-pause MS). 0 = disabled, any positive value
        # is the silence duration in milliseconds.
        try:
            config.inject_title_pause_ms = max(0, int(getattr(args, "inject_title_pause", 0) or 0))
        except (TypeError, ValueError):
            config.inject_title_pause_ms = 0
        char_voices_pref = getattr(args, "character_voices", None)
        if char_voices_pref is not None:
            config.enable_character_voices = bool(char_voices_pref)
        narrator_override = getattr(args, "narrator_voice", None)
        if narrator_override:
            config.narrator_voice = narrator_override
        character_override = getattr(args, "character_voice", None)
        if character_override:
            config.character_voice = character_override
        use_language_detection = getattr(args, "use_language_detection", None)
        if use_language_detection is not None:
            config.use_language_detection = bool(use_language_detection)
        prioritize_primary = getattr(args, "prioritize_primary_language", None)
        if prioritize_primary is not None:
            config.prioritize_primary_language = bool(prioritize_primary)
        return config

    def _apply_cli_overrides(self, args: argparse.Namespace, config: ConversionConfig) -> None:
        if config is None:
            return
        use_language_detection = getattr(args, "use_language_detection", None)
        if use_language_detection is not None:
            config.use_language_detection = bool(use_language_detection)
        prioritize_primary = getattr(args, "prioritize_primary_language", None)
        if prioritize_primary is not None:
            config.prioritize_primary_language = bool(prioritize_primary)

        if (
            getattr(args, "force_reprocess", False)
            or getattr(args, "no_cache", False)
            or getattr(args, "clear_cache", False)
        ):
            config.force_reprocess = True
        resume_from_failure = getattr(args, "resume_from_failure", None)
        if resume_from_failure is not None:
            config.extra["resume_from_failure"] = "1" if bool(resume_from_failure) else "0"
        chapter_prefetch = getattr(args, "chapter_prefetch", None)
        if chapter_prefetch is not None:
            config.extra["chapter_prefetch"] = "1" if bool(chapter_prefetch) else "0"
        auto_ab = getattr(args, "auto_ab", None)
        if auto_ab is not None:
            config.extra["auto_ab"] = "1" if bool(auto_ab) else "0"
        adaptive_checkpoint = getattr(args, "adaptive_checkpoint", None)
        if adaptive_checkpoint is not None:
            config.extra["adaptive_checkpoint"] = "1" if bool(adaptive_checkpoint) else "0"
        stage_pipeline = getattr(args, "stage_pipeline", None)
        if stage_pipeline is not None:
            config.extra["stage_pipeline"] = "1" if bool(stage_pipeline) else "0"
        stage_pipeline_depth = self._clamp_int(
            getattr(args, "stage_pipeline_depth", None), min_value=1, max_value=8
        )
        if stage_pipeline_depth is not None:
            config.extra["stage_pipeline_depth"] = str(stage_pipeline_depth)

        edge_chunk_chars = self._clamp_int(
            getattr(args, "edge_chunk_chars", None), min_value=4000, max_value=24000
        )
        edge_max_segment_seconds = self._clamp_int(
            getattr(args, "edge_max_segment_seconds", None), min_value=30, max_value=600
        )
        edge_parallel_override = getattr(args, "edge_enable_parallel", None)
        edge_auto_tune_override = getattr(args, "edge_auto_tune", None)
        piper_max_procs = self._clamp_int(
            getattr(args, "piper_max_procs", None), min_value=1, max_value=12
        )
        piper_chunk_chars = self._clamp_int(
            getattr(args, "piper_chunk_chars", None), min_value=800, max_value=12000
        )

        if edge_chunk_chars is not None:
            config.edge_chunk_chars = edge_chunk_chars
        if edge_max_segment_seconds is not None:
            config.edge_max_segment_seconds = edge_max_segment_seconds
        if edge_parallel_override is not None:
            config.edge_enable_parallel = bool(edge_parallel_override)
        if edge_auto_tune_override is not None:
            config.edge_auto_tune = bool(edge_auto_tune_override)
        if piper_max_procs is not None:
            config.piper_max_procs = piper_max_procs
        if piper_chunk_chars is not None:
            config.piper_chunk_chars = piper_chunk_chars
            self._cli_runtime.os.environ["PIPER_CHUNK_CHARS"] = str(piper_chunk_chars)

        edge_stable_mode = getattr(args, "edge_stable_mode", None)
        if edge_stable_mode is not None:
            config.extra["edge_stable_mode"] = "1" if edge_stable_mode else "0"
        if edge_stable_mode:
            if (config.engine or "").lower() == "edge":
                if edge_chunk_chars is None:
                    config.edge_chunk_chars = 4000
                if edge_max_segment_seconds is None:
                    config.edge_max_segment_seconds = 120
                if edge_auto_tune_override is None:
                    config.edge_auto_tune = False
                config.edge_enable_parallel = False
            self._cli_runtime.os.environ["CHAPTER_PARALLEL_COUNT"] = "1"
            self._cli_runtime.os.environ["CHAPTER_PARALLEL_MAX"] = "1"
            self._cli_runtime.os.environ.setdefault("CHAPTER_STALL_SECONDS", "60")
            self._cli_runtime.os.environ.setdefault("EDGE_NETWORK_TIER", "slow")

        bitrate = getattr(args, "bitrate", None)
        if bitrate:
            config.bitrate = str(bitrate)

        if getattr(args, "auto_validate_output", None) is not None:
            config.auto_validate_output = bool(getattr(args, "auto_validate_output"))
        if getattr(args, "auto_fix_output", None) is not None:
            config.auto_fix_output = bool(getattr(args, "auto_fix_output"))
        if getattr(args, "deep_validate", None) is not None:
            config.deep_validate = bool(getattr(args, "deep_validate"))
        sample_rate = self._clamp_int(
            getattr(args, "sample_rate", None), min_value=8000, max_value=96000
        )
        if sample_rate is not None:
            config.sample_rate = sample_rate
        channels = self._clamp_int(getattr(args, "channels", None), min_value=1, max_value=2)
        if channels is not None:
            config.channels = channels

        auto_engine_mode = (config.engine or "").lower() == "auto"
        if auto_engine_mode:
            # Auto mode should continuously tune for throughput in CLI runs.
            self._cli_runtime.os.environ.setdefault("ENABLE_AUTO_TUNING", "1")
            self._cli_runtime.os.environ.setdefault("ENABLE_ADAPTIVE_PERFORMANCE", "1")
            self._cli_runtime.os.environ.setdefault("CHAPTER_STALL_SECONDS", "45")
            if edge_auto_tune_override is None:
                config.edge_auto_tune = True

        self._apply_speed_profile(args, config)

        max_performance = bool(getattr(args, "max_performance", False) or auto_engine_mode)
        if max_performance:
            profile = getattr(self.converter, "hardware_profile", None)
            cpu_physical = int(getattr(profile, "cpu_physical", 2) or 2)
            bool(getattr(profile, "has_gpu", False))
            float(getattr(profile, "ram_total_gb", 0.0) or 0.0)
            if edge_chunk_chars is None:
                config.edge_chunk_chars = 24000
            if edge_max_segment_seconds is None:
                config.edge_max_segment_seconds = 300
            if edge_parallel_override is None:
                config.edge_enable_parallel = True
            if piper_max_procs is None:
                config.piper_max_procs = min(6, max(1, cpu_physical))
            if piper_chunk_chars is None and getattr(config, "piper_chunk_chars", None) is None:
                config.piper_chunk_chars = 3000

        parallel_slots = self._clamp_int(
            getattr(args, "parallel_slots", None), min_value=1, max_value=12
        )
        if parallel_slots is None and max_performance and not getattr(args, "no_parallel", False):
            profile = getattr(self.converter, "hardware_profile", None)
            cpu_physical = int(getattr(profile, "cpu_physical", 2) or 2)
            parallel_slots = min(6, max(2, cpu_physical * 2))
        if parallel_slots is not None:
            self._cli_runtime.os.environ["CHAPTER_PARALLEL_COUNT"] = str(parallel_slots)
            self._cli_runtime.os.environ["CHAPTER_PARALLEL_MAX"] = str(parallel_slots)

        chapter_stall_seconds = self._clamp_float(
            getattr(args, "chapter_stall_seconds", None),
            min_value=10.0,
            max_value=900.0,
        )
        if chapter_stall_seconds is not None:
            self._cli_runtime.os.environ["CHAPTER_STALL_SECONDS"] = str(chapter_stall_seconds)

        edge_network_tier = getattr(args, "edge_network_tier", None)
        if edge_network_tier:
            self._cli_runtime.os.environ["EDGE_NETWORK_TIER"] = str(edge_network_tier)

        self._apply_healthcheck_env(args)

        if getattr(args, "no_parallel", False):
            config.edge_enable_parallel = False
            self._cli_runtime.os.environ["CHAPTER_PARALLEL_COUNT"] = "1"
            self._cli_runtime.os.environ["CHAPTER_PARALLEL_MAX"] = "1"

        if getattr(args, "multi_engine_parallel", False):
            config.extra["multi_engine_parallel"] = "1"

    def _apply_speed_profile(self, args: argparse.Namespace, config: ConversionConfig) -> None:
        profile_name = str(getattr(args, "profile", "") or "").strip().lower()
        if profile_name != "speed":
            return

        scenario = str(getattr(args, "speed_scenario", "auto") or "auto").strip().lower()
        hw_profile = getattr(self.converter, "hardware_profile", None)
        network_tier = str(getattr(hw_profile, "network_speed_estimate", "") or "").lower()
        cpu_physical = int(getattr(hw_profile, "cpu_physical", 2) or 2)
        ram_total = float(getattr(hw_profile, "ram_total_gb", 0.0) or 0.0)

        if scenario == "auto":
            if network_tier in {"slow", "medium"}:
                scenario = "offline-heavy"
            elif network_tier in {"fast", "ultra"} and cpu_physical >= 6 and ram_total >= 12:
                scenario = "edge-fast"
            else:
                scenario = "balanced"

        if getattr(config, "extra", None) is None:
            config.extra = {}
        config.extra["speed_profile"] = "speed"
        config.extra["speed_scenario"] = scenario

        if scenario == "offline-heavy":
            config.auto_prefer_piper = True
            config.edge_enable_parallel = False
            config.edge_chunk_chars = min(int(config.edge_chunk_chars or 12000), 8000)
            config.edge_max_segment_seconds = min(int(config.edge_max_segment_seconds or 85), 90)
            slots = max(1, min(3, cpu_physical // 2 if cpu_physical > 1 else 1))
            self._cli_runtime.os.environ["CHAPTER_PARALLEL_COUNT"] = str(slots)
            self._cli_runtime.os.environ["CHAPTER_PARALLEL_MAX"] = str(slots)
        elif scenario == "edge-fast":
            config.edge_enable_parallel = True
            config.edge_chunk_chars = max(int(config.edge_chunk_chars or 12000), 20000)
            config.edge_max_segment_seconds = max(int(config.edge_max_segment_seconds or 85), 180)
            config.edge_max_concurrency = max(int(config.edge_max_concurrency or 8), 12)
            slots = min(6, max(2, cpu_physical))
            self._cli_runtime.os.environ["CHAPTER_PARALLEL_COUNT"] = str(slots)
            self._cli_runtime.os.environ["CHAPTER_PARALLEL_MAX"] = str(slots)
        else:
            config.edge_enable_parallel = True
            config.edge_chunk_chars = max(12000, int(config.edge_chunk_chars or 12000))
            config.edge_max_segment_seconds = max(85, int(config.edge_max_segment_seconds or 85))
            config.edge_max_concurrency = max(int(config.edge_max_concurrency or 6), 8)
            slots = min(4, max(2, cpu_physical // 2 if cpu_physical > 2 else 2))
            self._cli_runtime.os.environ["CHAPTER_PARALLEL_COUNT"] = str(slots)
            self._cli_runtime.os.environ["CHAPTER_PARALLEL_MAX"] = str(slots)

    def _apply_healthcheck_env(self, args: argparse.Namespace) -> None:
        interval = self._clamp_float(
            getattr(args, "health_check_interval_seconds", None),
            min_value=10.0,
            max_value=300.0,
        )
        slow_edge = self._clamp_float(
            getattr(args, "health_check_slow_edge_cps", None),
            min_value=10.0,
            max_value=500.0,
        )
        slow_cps = self._clamp_float(
            getattr(args, "health_check_slow_cps", None),
            min_value=10.0,
            max_value=300.0,
        )
        high_cpu = self._clamp_float(
            getattr(args, "health_check_high_cpu", None),
            min_value=30.0,
            max_value=100.0,
        )
        high_mem = self._clamp_float(
            getattr(args, "health_check_high_mem", None),
            min_value=30.0,
            max_value=100.0,
        )
        ok_cpu = self._clamp_float(
            getattr(args, "health_check_ok_cpu", None),
            min_value=10.0,
            max_value=100.0,
        )
        ok_mem = self._clamp_float(
            getattr(args, "health_check_ok_mem", None),
            min_value=10.0,
            max_value=100.0,
        )
        slow_streak = self._clamp_int(
            getattr(args, "health_check_slow_streak", None), min_value=1, max_value=6
        )
        if interval is not None:
            self._cli_runtime.os.environ["JOB_HEALTHCHECK_INTERVAL_SECONDS"] = str(interval)
        if slow_edge is not None:
            self._cli_runtime.os.environ["JOB_HEALTHCHECK_SLOW_EDGE_CPS"] = str(slow_edge)
        if slow_cps is not None:
            self._cli_runtime.os.environ["JOB_HEALTHCHECK_SLOW_CPS"] = str(slow_cps)
        if high_cpu is not None:
            self._cli_runtime.os.environ["JOB_HEALTHCHECK_HIGH_CPU_PERCENT"] = str(high_cpu)
        if high_mem is not None:
            self._cli_runtime.os.environ["JOB_HEALTHCHECK_HIGH_MEM_PERCENT"] = str(high_mem)
        if ok_cpu is not None:
            self._cli_runtime.os.environ["JOB_HEALTHCHECK_OK_CPU_PERCENT"] = str(ok_cpu)
        if ok_mem is not None:
            self._cli_runtime.os.environ["JOB_HEALTHCHECK_OK_MEM_PERCENT"] = str(ok_mem)
        if slow_streak is not None:
            self._cli_runtime.os.environ["JOB_HEALTHCHECK_SLOW_STREAK"] = str(slow_streak)
