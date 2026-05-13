"""Regression: `PythonEmbed.shared.bootstrap()` must run on the worker
queue, never on the calling actor.

`bootstrap()` runs `Py_Initialize`, imports `sys`, and installs the
Edge/Piper transports. Observed wall time on first call: 200-800 ms on
an iPhone 12 cold launch. If a `PythonBridge.*` API calls it before
`queue.async`, the main actor freezes for that duration — symptom:
"app trava ao dar play" / "não responsivo logo após abrir".

This test scans `PythonBridge.swift` and asserts that every async entry
point in the public surface places the `bootstrap()` call *inside* the
`queue.async { … }` block, not before it.
"""

from __future__ import annotations

import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
BRIDGE = REPO_ROOT / "ios" / "EpubToMp3" / "EpubToMp3" / "Services" / "PythonBridge.swift"


def test_bootstrap_is_called_inside_queue_async() -> None:
    """No `try PythonEmbed.shared.bootstrap()` should sit outside a
    `queue.async { … }` block in any async PythonBridge entry point."""
    assert BRIDGE.is_file(), f"PythonBridge.swift missing at {BRIDGE}"
    body = BRIDGE.read_text(encoding="utf-8")

    bootstrap_calls = [
        m.start() for m in re.finditer(r"try\s+PythonEmbed\.shared\.bootstrap\(\)", body)
    ]
    assert bootstrap_calls, (
        "Expected at least one PythonEmbed.shared.bootstrap() call. "
        "If the bridge stopped calling it, this test is stale."
    )

    for offset in bootstrap_calls:
        # Find the nearest preceding `queue.async {` and the nearest
        # preceding `func` declaration. If `queue.async {` is closer,
        # the call is inside the worker block — good. If `func` is
        # closer (and there's no `queue.async {` between them), the
        # call runs on the caller — regression.
        prefix = body[:offset]
        last_queue = prefix.rfind("queue.async")
        last_func = prefix.rfind("func ")
        # Both negative means we're somewhere weird (top-of-file
        # comment). Treat as failure so the test points at it.
        assert last_func >= 0, (
            f"bootstrap() at offset {offset} not inside any function — " "unexpected file layout."
        )
        assert last_queue > last_func, (
            f"bootstrap() at offset {offset} runs on the caller "
            "(main actor when invoked from SwiftUI). Move it inside "
            "the `queue.async {{ … }}` block — calling Py_Initialize "
            "on the main actor freezes the UI for hundreds of ms."
        )
