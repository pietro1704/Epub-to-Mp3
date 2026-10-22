"""Reader behavior declarations for the retained CLI schema."""

def add_reader_behavior_arguments(parser):
    verbose_group = parser.add_mutually_exclusive_group()
    verbose_group.add_argument(
        "--verbose",
        dest="verbose",
        action="store_true",
        default=None,
        help="Enable verbose logging (default: enabled)",
    )
    verbose_group.add_argument(
        "--no-verbose",
        dest="verbose",
        action="store_false",
        default=None,
        help="Disable verbose logging",
    )
    cues_group = parser.add_mutually_exclusive_group()
    cues_group.add_argument(
        "--formatting-cues",
        dest="formatting_cues",
        action="store_true",
        default=None,
        help="Read formatting cues aloud (quotes, italics, bold)",
    )
    cues_group.add_argument(
        "--no-formatting-cues",
        dest="formatting_cues",
        action="store_false",
        default=None,
        help="Disable spoken formatting cues",
    )
    char_voices_group = parser.add_mutually_exclusive_group()
    char_voices_group.add_argument(
        "--character-voices",
        dest="character_voices",
        action="store_true",
        default=None,
        help="Use a separate voice for dialogue (default: on)",
    )
    char_voices_group.add_argument(
        "--no-character-voices",
        dest="character_voices",
        action="store_false",
        default=None,
        help="Read every line with the same voice (no narrator/character split)",
    )
    parser.add_argument(
        "--narrator-voice",
        dest="narrator_voice",
        default=None,
        help="Voice for narration (defaults to --voice when omitted)",
    )
    parser.add_argument(
        "--character-voice",
        dest="character_voice",
        default=None,
        help="Voice for dialogue spans (text inside quotes / em-dash lines)",
    )
    parser.add_argument(
        "--listen",
        action="store_true",
        help="Play each chapter immediately after conversion",
    )
    parser.add_argument(
        "--export-to-iphone",
        dest="export_to_iphone",
        action="store_true",
        default=None,
        help=(
            "After conversion, copy MP3s into the MP3AudioBookPlayer iCloud "
            "Drive container so they sync to the iPhone (macOS only). The "
            "files appear in 'Files > MP3AudioBookPlayer' on the device. "
            "Override the container path with IPHONE_EXPORT_DIR or enable "
            "globally with EXPORT_TO_IPHONE=1."
        ),
    )
    parser.add_argument(
        "--no-parallel",
        dest="no_parallel",
        action="store_true",
        help="Disable chapter/segment parallelism (1 chapter at a time)",
    )
    parser.add_argument(
        "--multi-engine",
        dest="multi_engine_parallel",
        action="store_true",
        help="Run Edge and a local engine (Piper) simultaneously on different chapters for maximum throughput. Disabled by default — local engines may misdetect language.",
    )
    parser.add_argument(
        "--no-footnote",
        action="store_true",
        help="Skip footnotes entirely",
    )
    parser.add_argument(
        "--footnote-chapter-end",
        action="store_true",
        help="Read footnotes at the end of the chapter instead of inline",
    )
    parser.add_argument(
        "--clear-cache",
        action="store_true",
        help="Remove cache and output for this book, then convert. Without a book, removes ALL cache/output (with confirmation)",
    )
    parser.add_argument(
        "--no-cache",
        dest="no_cache",
        action="store_true",
        help="Ignore existing cache/output and regenerate only the selected book from scratch (use --clear-cache without a book for explicit global cleanup)",
    )
