from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
IOS_ROOT = ROOT / "ios" / "EpubToMp3" / "EpubToMp3"


def _read(relative: str) -> str:
    return (IOS_ROOT / relative).read_text(encoding="utf-8")


def _remove_action_body(source: str, remove_call: str = "library.remove(id: book.id)") -> str:
    remove_index = source.index(remove_call)
    start = source.rfind("private func remove", 0, remove_index)
    if start == -1:
        start = source.rfind("contextMenu", 0, remove_index)
    assert start != -1
    return source[start : remove_index + len(remove_call)]


def test_local_fulltext_cache_exposes_single_book_eviction() -> None:
    source = _read("Features/Offline/Services/LocalFulltextCache.swift")

    assert "static func evict(bookId: String)" in source
    evict_start = source.index("static func evict(bookId: String)")
    evict_body = source[evict_start : source.index("\n    }", evict_start) + 7]

    assert "fileURL(bookId: bookId)" in evict_body
    assert "FileManager.default.removeItem(at: url)" in evict_body


def test_local_fulltext_cache_exposes_orphan_prune_for_launch_cleanup() -> None:
    source = _read("Features/Offline/Services/LocalFulltextCache.swift")

    assert "static func pruneOrphans(validBookIds: Set<String>) -> Int" in source
    prune_start = source.index("static func pruneOrphans(validBookIds: Set<String>) -> Int")
    prune_body = source[prune_start : source.index("\n    }", prune_start) + 7]

    assert "contentsOfDirectory" in prune_body
    assert 'url.pathExtension == "json"' in prune_body
    assert "deletingPathExtension().lastPathComponent" in prune_body
    assert "!validBookIds.contains(bookId)" in prune_body
    assert "FileManager.default.removeItem(at: url)" in prune_body
    assert "return removed" in prune_body


def test_ios_library_controller_evicts_fulltext_cache_before_removing_book() -> None:
    source = _read("Features/Library/Views/LibraryScreenController.swift")
    body = _remove_action_body(source)

    assert "bookmarkStore.removeAll(for: book.id)" in body
    assert "LocalFulltextCache.evict(bookId: book.id)" in body
    assert body.index("LocalFulltextCache.evict(bookId: book.id)") < body.index(
        "library.remove(id: book.id)"
    )


def test_mac_library_controller_evicts_fulltext_cache_before_removing_book() -> None:
    source = _read("Features/Library/Views/MacLibraryViewController.swift")
    body = _remove_action_body(source, "library.remove(id: id)")

    assert "bookmarkStore.removeAll(for: id)" in body
    assert "LocalFulltextCache.evict(bookId: id)" in body
    assert body.index("LocalFulltextCache.evict(bookId: id)") < body.index("library.remove(id: id)")


def test_app_launch_prunes_orphan_fulltext_cache_behind_xctest_guard() -> None:
    source = _read("App/EpubToMp3App.swift")

    assert "pruneOrphanFulltextCache()" in source
    runtime_start = source.index("private func activateRuntime()")
    runtime_body = source[
        runtime_start : source.index("\n    private func deactivateRuntime", runtime_start)
    ]

    assert "guard !Self.isRunningUnderXCTest() else { return }" in runtime_body
    assert "pruneOrphanBookmarks()" in runtime_body
    assert "pruneOrphanFulltextCache()" in runtime_body

    helper_start = source.index("private func pruneOrphanFulltextCache()")
    helper_body = source[helper_start : source.index("\n    }", helper_start) + 7]

    assert "Set(library.books.map(\\.id))" in helper_body
    assert (
        "LocalFulltextCache.pruneOrphans(validBookIds: Set(library.books.map(\\.id)))"
        in helper_body
    )
