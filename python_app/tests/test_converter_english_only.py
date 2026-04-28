"""Regression tests guarding the English-only language policy in converter.py.

These tests are static-source assertions (not behavioural). They prevent the
Portuguese strings/comments removed during the 2026-04-28 cleanup from being
reintroduced — `git blame` on these lines should always point to a fix, not to
a regression.
"""

from __future__ import annotations

from pathlib import Path

CONVERTER_SOURCE = (Path(__file__).resolve().parent.parent / "src" / "converter.py").read_text(
    encoding="utf-8"
)


def test_no_portuguese_correlacionado_string() -> None:
    """`(not correlacionado)` was a Portuguese leak in unresolved-error labels.

    The replacement is `(uncorrelated)` so error messages are fully English.
    """
    assert "correlacionado" not in CONVERTER_SOURCE, (
        "Portuguese string 'correlacionado' reintroduced in converter.py — "
        "use 'uncorrelated' instead."
    )
    assert (
        "(uncorrelated)" in CONVERTER_SOURCE
    ), "English replacement '(uncorrelated)' missing from converter.py."


def test_no_portuguese_heartbeat_comment() -> None:
    """The async synthesis heartbeat comment must stay in English."""
    assert "Atualizar a cada" not in CONVERTER_SOURCE, (
        "Portuguese comment 'Atualizar a cada ...' reintroduced in "
        "converter.py heartbeat — use English per Language Policy."
    )
    assert "Update every 5 seconds" in CONVERTER_SOURCE, (
        "English heartbeat comment missing or rewritten — restore the "
        "'Update every 5 seconds' marker for the Stop hook coverage gate."
    )
