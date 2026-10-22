"""Input engine declarations for the retained CLI schema."""

def add_input_engine_arguments(parser, input_required):
    input_arg = parser.add_argument(
        "input_file",
        nargs="?",
        help="Input EPUB or PDF file",
    )
    parser.add_argument(
        "extra_inputs",
        nargs="*",
        help="Additional EPUB/PDF files to convert sequentially",
    )
    engine_arg = parser.add_argument(
        "--engine",
        choices=["auto", "edge", "piper"],
        default="edge",
        help="TTS engine to use (default: edge). rust uses the embedded Rust backend",
    )
    parser.add_argument(
        "--fallback-engine",
        choices=["auto", "piper", "none"],
        default="none",
        help=(
            "Engine used to re-synthesize a single sentence if the primary engine hangs/fails. "
            "Default is 'none' — staying on the user-chosen engine instead of silently switching "
            "(the Carl regression: a pt-BR audiobook was narrated by an English Piper model "
            "because the previous default 'auto' fell through to Piper without telling the user). "
            "Set explicitly to 'piper' / 'auto' to opt back into per-sentence fallback."
        ),
    )
    parser.add_argument(
        "--engine-chain-fallback",
        action="store_true",
        help="Enable the legacy Edge -> Piper cascade. Default is Edge-first with per-chunk fallback. Mirrors ENGINE_CHAIN_FALLBACK=1.",
    )
    parser.add_argument(
        "--prewarm-edge",
        action="store_true",
        help=(
            "Open and drain a tiny Edge-TTS stream before the chapter loop starts so "
            "the first chapter does not pay the TLS handshake + first-request latency. "
            "Saves ~300-500ms on the first chapter. Best-effort: failures are silent."
        ),
    )
    parser.add_argument(
        "--prewarm-piper",
        action="store_true",
        help=(
            "Locate the Piper binary and resolve the model file for the primary "
            "language before the chapter loop starts. Useful when Piper is the "
            "expected fallback. Best-effort: failures are silent."
        ),
    )
    parser.add_argument(
        "--inject-title-pause",
        type=int,
        default=0,
        metavar="MS",
        help=(
            "Inject N ms of silence between the chapter title announcement and "
            "the body via ffmpeg post-processing. Off by default (a fixed-length "
            "pause sounds uniform across chapters of varying length). "
            "Try 1500 or 2000 to opt in."
        ),
    )
    parser.add_argument("--voice", help="Voice to use (engine-specific)")
    parser.add_argument("--model", help="Model path (for Piper)")
    parser.add_argument("--output-dir", help="Output directory")
    parser.add_argument(
        "--show-structure",
        action="store_true",
        help="Print the detected book structure and exit",
    )
    parser.add_argument(
        "--detect-language",
        "--show-language",
        action="store_true",
        help="Detect book language and exit (prints primary language + precision)",
    )
    parser.add_argument(
        "--filter-chapters",
        action="store_true",
        help="Skip very short chapters when converting",
    )

    return input_arg, engine_arg
