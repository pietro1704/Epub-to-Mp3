"""Regression tests guarding the English-only language policy in the conversion completion owner.

These tests are static-source assertions (not behavioural). They prevent the
Portuguese strings/comments removed during the 2026-04-28 cleanup from being
reintroduced — `git blame` on these lines should always point to a fix, not to
a regression.
"""

from __future__ import annotations

from pathlib import Path

SOURCE_ROOT = Path(__file__).resolve().parent.parent / "src"
FACADE_SOURCE = (SOURCE_ROOT / "converter.py").read_text(encoding="utf-8")
COMPLETION_SOURCE = FACADE_SOURCE + (SOURCE_ROOT / "book_conversion_completion.py").read_text(
    encoding="utf-8"
)
HEARTBEAT_SOURCE = FACADE_SOURCE + (SOURCE_ROOT / "chapter_synthesis_budget.py").read_text(
    encoding="utf-8"
)


def test_no_portuguese_correlacionado_string() -> None:
    """`(not correlacionado)` was a Portuguese leak in unresolved-error labels.

    The replacement is `(uncorrelated)` so error messages are fully English.
    """
    assert "correlacionado" not in COMPLETION_SOURCE, (
        "Portuguese string 'correlacionado' reintroduced in the conversion completion owner — "
        "use 'uncorrelated' instead."
    )
    assert (
        "(uncorrelated)" in COMPLETION_SOURCE
    ), "English replacement '(uncorrelated)' missing from the conversion completion owner."


def test_no_portuguese_heartbeat_comment() -> None:
    """The async synthesis heartbeat comment must stay in English."""
    assert "Atualizar a cada" not in HEARTBEAT_SOURCE, (
        "Portuguese comment 'Atualizar a cada ...' reintroduced in "
        "the synthesis heartbeat owner — use English per Language Policy."
    )
    assert "Update every 5 seconds" in HEARTBEAT_SOURCE, (
        "English heartbeat comment missing or rewritten — restore the "
        "'Update every 5 seconds' marker for the Stop hook coverage gate."
    )
