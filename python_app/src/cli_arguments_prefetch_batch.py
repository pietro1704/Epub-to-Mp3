"""Prefetch batch declarations for the retained CLI schema."""

def add_prefetch_batch_arguments(parser):
    prefetch_group = parser.add_mutually_exclusive_group()
    prefetch_group.add_argument(
        "--prefetch",
        dest="chapter_prefetch",
        action="store_true",
        default=None,
        help="Enable chapter prefetch pipeline",
    )
    prefetch_group.add_argument(
        "--no-prefetch",
        dest="chapter_prefetch",
        action="store_false",
        default=None,
        help="Disable chapter prefetch pipeline",
    )
    stage_pipeline_group = parser.add_mutually_exclusive_group()
    stage_pipeline_group.add_argument(
        "--stage-pipeline",
        dest="stage_pipeline",
        action="store_true",
        default=None,
        help="Enable internal staged pipeline (prepare/synthesize/encode overlap)",
    )
    stage_pipeline_group.add_argument(
        "--no-stage-pipeline",
        dest="stage_pipeline",
        action="store_false",
        default=None,
        help="Disable internal staged pipeline",
    )
    parser.add_argument(
        "--stage-pipeline-depth",
        dest="stage_pipeline_depth",
        type=int,
        help="Prefetch depth for staged pipeline (default: 2)",
    )
    auto_ab_group = parser.add_mutually_exclusive_group()
    auto_ab_group.add_argument(
        "--ab-auto",
        dest="auto_ab",
        action="store_true",
        default=None,
        help="Enable online A/B exploration in auto-engine mode",
    )
    auto_ab_group.add_argument(
        "--no-ab-auto",
        dest="auto_ab",
        action="store_false",
        default=None,
        help="Disable online A/B exploration in auto-engine mode",
    )
    adaptive_checkpoint_group = parser.add_mutually_exclusive_group()
    adaptive_checkpoint_group.add_argument(
        "--adaptive-checkpoint",
        dest="adaptive_checkpoint",
        action="store_true",
        default=None,
        help="Enable adaptive-state checkpoint persistence",
    )
    adaptive_checkpoint_group.add_argument(
        "--no-adaptive-checkpoint",
        dest="adaptive_checkpoint",
        action="store_false",
        default=None,
        help="Disable adaptive-state checkpoint persistence",
    )
    parser.add_argument(
        "--batch",
        action="append",
        dest="batch_inputs",
        metavar="PATH",
        help="Additional EPUB/PDF files or directories to convert sequentially (accepts glob patterns)",
    )
    parser.add_argument(
        "--batch-file",
        dest="batch_manifest",
        metavar="FILE",
        help="Path to a text file containing one EPUB/PDF path per line for batch conversion",
    )
    parser.add_argument(
        "--stop-on-error",
        dest="batch_stop_on_error",
        action="store_true",
        help="Stop batch conversions after the first failed book (default: continue processing)",
    )
