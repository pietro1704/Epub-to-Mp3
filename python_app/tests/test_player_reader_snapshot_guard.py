"""Regression: PlayerReaderView must guard against mid-mount snapshot
identity changes.

Slice 43 added a defense-in-depth `.compatOnChange(of: snapshot.jobId)`
that tears down and re-bootstraps `PlayerReaderView` when the incoming
snapshot's jobId changes while the view stays mounted. Today every
parent forces a fresh view identity on snapshot change via `.id(...)`,
so this code path is dormant — but a future call site that forgets the
identity key would leave `positionTask` / `sentenceTask` / `streamTask`
subscribed to the previous job's streams and the UI would silently
desync.

This file-content test pins the modifier so the guard cannot be removed
without an explicit decision. It runs without booting CoreSimulator,
which is required on this user's low-resource Intel Mac.
"""

from __future__ import annotations

from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
VIEW = (
    REPO_ROOT
    / "ios"
    / "EpubToMp3"
    / "EpubToMp3"
    / "Features"
    / "Reader"
    / "Views"
    / "PlayerReaderView.swift"
)


def _body() -> str:
    assert VIEW.is_file(), f"PlayerReaderView.swift missing at {VIEW}"
    return VIEW.read_text(encoding="utf-8")


def _extract_jobid_guard_closure(body: str) -> str | None:
    """Return the body of the `compatOnChange(of: snapshot.jobId)` closure.

    Walks the source to find the modifier call and then balances braces
    until the closure's matching `}` so nested guards / returns inside
    the closure don't terminate the match early (a non-greedy `[^}]*`
    regex would stop at the first inner `}`).
    """
    marker = "compatOnChange(of: snapshot.jobId)"
    start = body.find(marker)
    if start == -1:
        return None
    brace = body.find("{", start)
    if brace == -1:
        return None
    depth = 0
    for i in range(brace, len(body)):
        ch = body[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return body[brace : i + 1]
    return None


def test_view_has_jobid_change_guard() -> None:
    """A `compatOnChange(of: snapshot.jobId)` modifier must be wired up."""
    body = _body()
    assert "compatOnChange(of: snapshot.jobId)" in body, (
        "PlayerReaderView must defend against mid-mount snapshot "
        "identity changes via `.compatOnChange(of: snapshot.jobId)`. "
        "Removing this guard means a parent that forgets `.id(...)` "
        "would leave the view subscribed to the previous job's "
        "position/sentence/stream tasks."
    )


def test_jobid_change_guard_calls_teardown_then_bootstrap() -> None:
    """The guard's closure must teardown first, then re-bootstrap.

    Ordering matters: re-bootstrapping before teardown would leave the
    old `positionTask` / `sentenceTask` running against the prior
    player snapshot while the new ones spin up — exactly the
    double-subscription failure mode the guard exists to prevent.
    """
    body = _body()
    # Match the closure body of the `compatOnChange(of: snapshot.jobId)`
    # modifier and assert teardown precedes bootstrap.
    closure = _extract_jobid_guard_closure(body)
    assert closure is not None, (
        "Could not locate the `compatOnChange(of: snapshot.jobId)` "
        "closure in PlayerReaderView.swift."
    )
    teardown_idx = closure.find("teardown()")
    bootstrap_idx = closure.find("bootstrap()")
    assert teardown_idx != -1, "Guard closure must call teardown()."
    assert bootstrap_idx != -1, "Guard closure must call bootstrap()."
    assert teardown_idx < bootstrap_idx, (
        "Guard closure must call teardown() BEFORE bootstrap() so the "
        "old job's tasks are cancelled before new ones are spawned."
    )


def test_jobid_guard_skips_swiftui_preview() -> None:
    """SwiftUI previews must not re-bootstrap on jobId changes.

    `bootstrap()` opens a live SSE connection and starts AVPlayer
    work — neither is appropriate inside a Xcode preview canvas. The
    onAppear path already guards on `isSwiftUIPreview`; the jobId
    guard must do the same so a previewing a parent that mutates the
    snapshot doesn't blow up the canvas.
    """
    body = _body()
    closure = _extract_jobid_guard_closure(body)
    assert closure is not None
    assert "isSwiftUIPreview" in closure, (
        "The jobId-change guard must early-return inside SwiftUI "
        "previews — `bootstrap()` opens a live SSE connection."
    )


def test_bootstrap_and_teardown_symbols_still_exist() -> None:
    """If `bootstrap()` / `teardown()` were renamed, update the guard."""
    body = _body()
    assert "private func bootstrap()" in body, (
        "If `bootstrap()` was renamed, also update the snapshot-jobId "
        "guard in PlayerReaderView.swift."
    )
    assert "private func teardown()" in body, (
        "If `teardown()` was renamed, also update the snapshot-jobId "
        "guard in PlayerReaderView.swift."
    )
