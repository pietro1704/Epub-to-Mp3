"""Engine runtime declarations for the retained CLI schema."""

def add_engine_runtime_arguments(parser):
    parser.add_argument(
        "--max-performance",
        dest="max_performance",
        action="store_true",
        help="Use aggressive performance defaults (larger chunks and more parallelism)",
    )
    parser.add_argument(
        "--overnight",
        dest="overnight",
        action="store_true",
        help="Apply overnight preset: Piper + offline-heavy speed profile + staged pipeline + minimal validation",
    )
    parser.add_argument(
        "--profile",
        dest="profile",
        choices=["speed"],
        help="Apply predefined profile (speed)",
    )
    parser.add_argument(
        "--speed-scenario",
        dest="speed_scenario",
        choices=["auto", "balanced", "edge-fast", "offline-heavy"],
        default="auto",
        help="Scenario for --profile speed (auto|balanced|edge-fast|offline-heavy)",
    )
    parser.add_argument(
        "--parallel-slots",
        dest="parallel_slots",
        type=int,
        help="Override number of parallel chapters",
    )
    parser.add_argument(
        "--chapter-stall-seconds",
        dest="chapter_stall_seconds",
        type=float,
        help="Watchdog timeout before restarting a stalled chapter",
    )
    parser.add_argument(
        "--edge-chunk-chars",
        dest="edge_chunk_chars",
        type=int,
        help="Override Edge chunk size (chars)",
    )
    parser.add_argument(
        "--edge-max-segment-seconds",
        dest="edge_max_segment_seconds",
        type=int,
        help="Override Edge max segment duration (seconds)",
    )
    parser.add_argument(
        "--edge-network-tier",
        dest="edge_network_tier",
        choices=["slow", "medium", "fast", "ultra"],
        help="Override Edge network tier (slow/medium/fast/ultra)",
    )
    edge_parallel_group = parser.add_mutually_exclusive_group()
    edge_parallel_group.add_argument(
        "--edge-enable-parallel",
        dest="edge_enable_parallel",
        action="store_true",
        default=None,
        help="Enable Edge internal parallelism",
    )
    edge_parallel_group.add_argument(
        "--edge-disable-parallel",
        dest="edge_enable_parallel",
        action="store_false",
        default=None,
        help="Disable Edge internal parallelism",
    )
    edge_auto_tune_group = parser.add_mutually_exclusive_group()
    edge_auto_tune_group.add_argument(
        "--edge-auto-tune",
        dest="edge_auto_tune",
        action="store_true",
        default=None,
        help="Enable Edge auto-tuning (adaptive chunk/segment sizes)",
    )
    edge_auto_tune_group.add_argument(
        "--no-edge-auto-tune",
        dest="edge_auto_tune",
        action="store_false",
        default=None,
        help="Disable Edge auto-tuning",
    )
    edge_stable_group = parser.add_mutually_exclusive_group()
    edge_stable_group.add_argument(
        "--edge-stable-mode",
        dest="edge_stable_mode",
        action="store_true",
        default=None,
        help="Use a safer Edge profile (lower parallelism, longer timeouts)",
    )
    edge_stable_group.add_argument(
        "--no-edge-stable-mode",
        dest="edge_stable_mode",
        action="store_false",
        default=None,
        help="Disable Edge stable mode overrides",
    )
    parser.add_argument(
        "--piper-max-procs",
        "--piper-workers",
        dest="piper_max_procs",
        type=int,
        help="Override Piper concurrent process limit",
    )
    parser.add_argument(
        "--piper-chunk-chars",
        dest="piper_chunk_chars",
        type=int,
        help="Override Piper chunk size (chars)",
    )
    parser.add_argument(
        "--bitrate",
        dest="bitrate",
        help="Override output bitrate (e.g., 8k, 32k)",
    )
    parser.add_argument(
        "--sample-rate",
        dest="sample_rate",
        type=int,
        help="Override output sample rate (Hz)",
    )
    parser.add_argument(
        "--channels",
        dest="channels",
        type=int,
        help="Override output channels (1=mono, 2=stereo)",
    )
    parser.add_argument(
        "--force-reprocess",
        dest="force_reprocess",
        action="store_true",
        help="Ignore cached audio and regenerate all chapters",
    )
