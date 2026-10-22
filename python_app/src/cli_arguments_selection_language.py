"""Selection language declarations for the retained CLI schema."""

def add_selection_language_arguments(parser):
    parser.add_argument(
        "--chapter",
        action="append",
        dest="chapters",
        metavar="CHAPTER",
        help="Select chapters by index (supports dotted syntax like 3 or 1.2) or title snippet; repeat the flag or pass comma-separated values (e.g., 5.1,5.2,5.3)",
    )
    parser.add_argument(
        "--from-chapter-to-end",
        dest="from_chapter_to_end",
        metavar="CHAPTER",
        help="Convert starting from a chapter (same syntax as --chapter) to the end",
    )
    parser.add_argument(
        "--from-chapter-to-chapter",
        dest="from_chapter_to_chapter",
        metavar="RANGE",
        help="Convert from chapter A to chapter B (use A..B, e.g., 5.1..7.3)",
    )
    parser.add_argument(
        "--section",
        action="append",
        dest="sections",
        metavar="SECTION",
        help="Additional selectors for subsections or names (accepts dotted indices and text); repeat or use comma-separated values",
    )
    parser.add_argument(
        "--priority",
        action="append",
        dest="priority",
        metavar="PRIORITY",
        help="Prioritize chapters before the rest (same syntax as --chapter)",
    )
    parser.add_argument(
        "--language",
        help="Override primary language (e.g., pt, en, pt-BR). Use 'auto' to detect",
    )
    language_detection_group = parser.add_mutually_exclusive_group()
    language_detection_group.add_argument(
        "--use-language-detection",
        dest="use_language_detection",
        action="store_true",
        default=None,
        help="Enable automatic language markup for mixed-language text",
    )
    language_detection_group.add_argument(
        "--no-language-detection",
        dest="use_language_detection",
        action="store_false",
        default=None,
        help="Disable automatic language markup for mixed-language text",
    )
    prioritize_language_group = parser.add_mutually_exclusive_group()
    prioritize_language_group.add_argument(
        "--prioritize-primary-language",
        dest="prioritize_primary_language",
        action="store_true",
        default=None,
        help="Prefer the primary language when detections are ambiguous",
    )
    prioritize_language_group.add_argument(
        "--no-prioritize-primary-language",
        dest="prioritize_primary_language",
        action="store_false",
        default=None,
        help="Allow ambiguous language detections to override the primary language",
    )
    parser.add_argument(
        "--ui-language",
        dest="ui_language",
        help="Force CLI language (pt or en)",
    )
