"""Validation declarations for the retained CLI schema."""

def add_validation_arguments(parser):
    resume_group = parser.add_mutually_exclusive_group()
    resume_group.add_argument(
        "--resume-from-failure",
        dest="resume_from_failure",
        action="store_true",
        default=None,
        help="When a failure checkpoint exists, retry only failed chapters first",
    )
    resume_group.add_argument(
        "--no-resume-from-failure",
        dest="resume_from_failure",
        action="store_false",
        default=None,
        help="Ignore failure checkpoint and process selected chapters normally",
    )
    parser.add_argument(
        "--verify",
        "--verify-only",
        dest="verify_only",
        action="store_true",
        help="Validate existing output/cache against EPUB only (no new conversion)",
    )
    parser.add_argument(
        "--fix",
        dest="fix_mode",
        action="store_true",
        help="Verify then auto-fix: reconvert problematic chapters until book is 100%% intact",
    )
    parser.add_argument(
        "--verify-transcription",
        "--audio-verify",
        action="store_true",
        default=None,
        dest="verify_transcription",
        help="Enable deep validation via speech-to-text transcription (disabled by default, requires faster-whisper)",
    )
    parser.add_argument(
        "--no-verify-transcription",
        "--no-audio-verify",
        action="store_false",
        dest="verify_transcription",
        help="Disable speech-to-text transcription verification",
    )
    parser.add_argument(
        "--deep-validate",
        action="store_true",
        dest="deep_validate",
        default=None,
        help="Enable deep validation (full text/audio comparison) after converting",
    )
    parser.add_argument(
        "--no-deep-validate",
        action="store_false",
        dest="deep_validate",
        help="Disable deep validation (default, faster)",
    )
    parser.add_argument(
        "--validate-during-conversion",
        action="store_true",
        help="Validate parsed text and MP3 output during conversion",
    )
    parser.add_argument(
        "--auto-validate-output",
        dest="auto_validate_output",
        action="store_true",
        default=None,
        help="Always run post-validation (enabled by default)",
    )
    parser.add_argument(
        "--no-auto-validate-output",
        dest="auto_validate_output",
        action="store_false",
        default=None,
        help="Disable automatic post-validation",
    )
    parser.add_argument(
        "--auto-fix-output",
        dest="auto_fix_output",
        action="store_true",
        default=None,
        help="Always auto-fix on validation errors (enabled by default)",
    )
    parser.add_argument(
        "--no-auto-fix-output",
        dest="auto_fix_output",
        action="store_false",
        default=None,
        help="Disable automatic auto-fix",
    )
    parser.add_argument(
        "--no-validate",
        action="store_true",
        help="Disable all validation (text and audio) during conversion",
    )
    parser.add_argument(
        "--validate-text",
        dest="validate_text",
        action="store_true",
        default=True,
        help="Validate parsed/pre-tts text during conversion (enabled by default)",
    )
    parser.add_argument(
        "--no-validate-text",
        dest="validate_text",
        action="store_false",
        help="Disable text validation during conversion",
    )
    parser.add_argument(
        "--validate-audio",
        dest="validate_audio",
        action="store_true",
        default=True,
        help="Validate MP3 integrity and duration during conversion (enabled by default)",
    )
    parser.add_argument(
        "--no-validate-audio",
        dest="validate_audio",
        action="store_false",
        help="Disable MP3 validation during conversion",
    )
    parser.add_argument(
        "--strict-validate",
        action="store_true",
        help="Stop conversion when validation fails",
    )
    parser.add_argument(
        "--transcription-model",
        default="small",
        choices=["tiny", "base", "small", "medium", "large"],
        help="Whisper model for transcription validation (default: small)",
    )
    parser.add_argument(
        "--validation-language",
        help="Language code for transcription validation (e.g., pt, en, es)",
    )
