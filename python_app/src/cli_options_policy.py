"""Options policy for the retained legacy CLI."""

from .cli_runtime_dependencies import Optional as Optional
from .cli_runtime_dependencies import argparse as argparse


class CLIOptionsPolicy:
    @staticmethod
    def _resolve_verbose(args: argparse.Namespace) -> bool:
        raw = getattr(args, "verbose", None)
        if raw is None:
            return True
        return bool(raw)

    @staticmethod
    def _resolve_formatting_cues(args: argparse.Namespace, default: bool = True) -> bool:
        raw = getattr(args, "formatting_cues", None)
        if raw is None:
            return default
        return bool(raw)

    @staticmethod
    def _normalize_language_override(raw: Optional[str]) -> Optional[str]:
        if raw is None:
            return None
        cleaned = str(raw).strip()
        if not cleaned:
            return None
        if cleaned.lower() in {"auto", "unknown"}:
            return None
        return cleaned

    @staticmethod
    def _clamp_int(
        value: Optional[int],
        *,
        min_value: Optional[int] = None,
        max_value: Optional[int] = None,
    ) -> Optional[int]:
        if value is None:
            return None
        try:
            parsed = int(value)
        except (TypeError, ValueError):
            return None
        if min_value is not None:
            parsed = max(min_value, parsed)
        if max_value is not None:
            parsed = min(max_value, parsed)
        return parsed

    @staticmethod
    def _clamp_float(
        value: Optional[float],
        *,
        min_value: Optional[float] = None,
        max_value: Optional[float] = None,
    ) -> Optional[float]:
        if value is None:
            return None
        try:
            parsed = float(value)
        except (TypeError, ValueError):
            return None
        if min_value is not None:
            parsed = max(min_value, parsed)
        if max_value is not None:
            parsed = min(max_value, parsed)
        return parsed

    @staticmethod
    def _apply_no_parallel_env(args: argparse.Namespace, *, namespace) -> None:
        if getattr(args, "no_parallel", False):
            namespace.os.environ["CHAPTER_PARALLEL_COUNT"] = "1"
            namespace.os.environ["CHAPTER_PARALLEL_MAX"] = "1"
            namespace.os.environ["EDGE_ENABLE_PARALLEL"] = "false"
