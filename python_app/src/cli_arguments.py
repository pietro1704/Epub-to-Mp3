"""Ordered argparse schema assembly and optional completion wiring."""

from typing import Optional

from .cli_arguments_input_engine import add_input_engine_arguments
from .cli_arguments_reader_behavior import add_reader_behavior_arguments
from .cli_arguments_validation import add_validation_arguments
from .cli_arguments_selection_language import add_selection_language_arguments
from .cli_arguments_engine_runtime import add_engine_runtime_arguments
from .cli_arguments_health_metrics import add_health_metrics_arguments
from .cli_arguments_prefetch_batch import add_prefetch_batch_arguments


def add_conversion_arguments(parser, *, include_menu_flag, input_required, namespace):
    input_arg, engine_arg = add_input_engine_arguments(parser, input_required)
    add_reader_behavior_arguments(parser)
    add_validation_arguments(parser)
    add_selection_language_arguments(parser)
    add_engine_runtime_arguments(parser)
    add_health_metrics_arguments(parser)
    add_prefetch_batch_arguments(parser)

    if include_menu_flag:
        parser.add_argument(
            "--menu",
            action="store_true",
            help="Use interactive menu instead of CLI defaults",
        )

    # Configure tab completion (argcomplete adds 'completer' attribute dynamically)
    if namespace.FilesCompleter is not None:
        input_arg.completer = namespace.FilesCompleter(allowednames=(".epub", ".pdf"))  # type: ignore

    if namespace.ChoicesCompleter is not None:
        engine_arg.completer = namespace.ChoicesCompleter(engine_arg.choices)  # type: ignore

    def _parse_leading_number(raw_index: str) -> Optional[int]:
        try:
            return int(raw_index.split()[0])
        except (ValueError, IndexError):
            return None

    return parser
