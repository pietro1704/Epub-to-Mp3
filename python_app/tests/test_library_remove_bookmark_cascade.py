"""Regression: removing a book from the library must cascade to BookmarkStore.

Slice 45 mirrors the Flutter slice-42 fix on the iOS client. Book IDs
are SHA-256 of file content, so an orphan bookmark whose book left the
library can resurrect itself the moment the user re-imports the same
EPUB. The cascade has to fire at every `LibraryStore.remove(id:)` call
site, and `BookmarkStore` needs a `pruneOrphans(validBookIds:)` so a
one-shot at app start can clean up historical drift from pre-cascade
builds.

This file-content test runs without booting CoreSimulator (required on
this user's Intel 8 GiB Mac per slice 41). The Swift unit tests in
`BookmarkStoreTests` cover the in-memory pruning semantics — this
module pins the wiring at the four sites where the invariant lives.
"""

from __future__ import annotations

from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
IOS_ROOT = REPO_ROOT / "ios" / "EpubToMp3" / "EpubToMp3"
STORE = IOS_ROOT / "Services" / "BookmarkStore.swift"
APP = IOS_ROOT / "EpubToMp3App.swift"
LIBRARY_VIEW = IOS_ROOT / "Views" / "LibraryView.swift"
SIDEBAR = IOS_ROOT / "Views" / "LibrarySidebar.swift"


def _read(path: Path) -> str:
    assert path.is_file(), f"missing: {path}"
    return path.read_text(encoding="utf-8")


def test_bookmark_store_exposes_prune_orphans() -> None:
    body = _read(STORE)
    assert (
        "func pruneOrphans(validBookIds: Set<String>) -> Int" in body
    ), "BookmarkStore.pruneOrphans signature missing — slice 45 contract"
    # Silent no-op when there's nothing to drop: must early-return without
    # mutating `bookmarks` or calling `persist()`. Pinning the guard
    # keeps a future refactor from re-introducing a spurious encode that
    # would clobber the corrupt-data safety net.
    assert (
        "guard removed > 0 else { return 0 }" in body
    ), "pruneOrphans must early-return on the no-op path"


def test_library_view_cascades_bookmark_removal() -> None:
    body = _read(LIBRARY_VIEW)
    assert (
        "@EnvironmentObject private var bookmarkStore: BookmarkStore" in body
    ), "LibraryView must hold a reference to BookmarkStore for the cascade"
    # The cascade has to fire BEFORE `library.remove` — otherwise the
    # bookmark drop sees the stale library set if a future prune ever
    # reads it. Pin the textual order.
    remove_idx = body.find("library.remove(id: book.id)")
    cascade_idx = body.find("bookmarkStore.removeAll(for: book.id)")
    assert remove_idx != -1, "LibraryView no longer calls library.remove(id:)"
    assert cascade_idx != -1, "LibraryView is missing the bookmark cascade"
    assert cascade_idx < remove_idx, (
        "bookmarkStore.removeAll must precede library.remove so the cascade "
        "owns the failure surface"
    )


def test_library_sidebar_cascades_bookmark_removal() -> None:
    body = _read(SIDEBAR)
    assert (
        "@EnvironmentObject private var bookmarkStore: BookmarkStore" in body
    ), "LibrarySidebar must hold a reference to BookmarkStore for the cascade"
    remove_idx = body.find("library.remove(id: book.id)")
    cascade_idx = body.find("bookmarkStore.removeAll(for: book.id)")
    assert remove_idx != -1, "LibrarySidebar no longer calls library.remove(id:)"
    assert cascade_idx != -1, "LibrarySidebar is missing the bookmark cascade"
    assert (
        cascade_idx < remove_idx
    ), "bookmarkStore.removeAll must precede library.remove in the swipe action"


def test_app_runs_one_shot_orphan_prune_on_launch() -> None:
    body = _read(APP)
    assert "pruneOrphanBookmarks()" in body, "EpubToMp3App must call the one-shot prune on launch"
    assert (
        "bookmarkStore.pruneOrphans(validBookIds: valid)" in body
    ), "pruneOrphanBookmarks must delegate to BookmarkStore.pruneOrphans"
    # The launch task already skips under XCTest; the prune must sit
    # AFTER that guard so the unit-test bundle never mutates real
    # bookmarks while running.
    test_guard = body.find("guard !Self.isRunningUnderXCTest() else { return }")
    prune_call = body.find("pruneOrphanBookmarks()")
    assert test_guard != -1 and prune_call != -1
    assert test_guard < prune_call, "pruneOrphanBookmarks must sit behind the XCTest guard"
