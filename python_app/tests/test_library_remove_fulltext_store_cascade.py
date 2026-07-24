from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
IOS_ROOT = ROOT / "ios" / "EpubToMp3" / "EpubToMp3"


def _read(relative: str) -> str:
    return (IOS_ROOT / relative).read_text(encoding="utf-8")


def _remove_action_body(source: str, remove_call: str = "library.remove(id: book.id)") -> str:
    remove_index = source.index(remove_call)
    start = source.rfind("Button", 0, remove_index)
    if start == -1:
        start = source.rfind("contextMenu", 0, remove_index)
    assert start != -1
    return source[start : remove_index + len(remove_call)]


def test_fulltext_store_exposes_jobid_eviction_api() -> None:
    source = _read("Features/Offline/Services/FulltextStore.swift")

    assert "static func evict(jobId: String) -> Bool" in source
    evict_start = source.index("static func evict(jobId: String) -> Bool")
    evict_body = source[evict_start : source.index("\n    }", evict_start) + 7]

    assert "markEvicted(jobId: jobId)" in evict_body
    assert "fulltextURL(for: jobId)" in evict_body
    assert "FileManager.default.removeItem(at: url)" in evict_body
    assert "NSFileNoSuchFileError" in evict_body


def test_fulltext_store_tombstone_blocks_stale_disk_and_memory_replay() -> None:
    source = _read("Features/Offline/Services/FulltextStore.swift")

    assert "private static var evictedJobIds: Set<String> = []" in source
    assert "private static func markEvicted(jobId: String)" in source
    assert "private static func clearEvicted(jobId: String)" in source
    assert "private static func isEvicted(jobId: String) -> Bool" in source

    load_start = source.index("static func loadFromDisk(jobId: String, root: URL? = nil)")
    load_body = source[load_start : source.index("\n    }", load_start) + 7]
    assert "guard !isEvicted(jobId: jobId) else { return nil }" in load_body

    save_start = source.index("static func saveToDisk(_ payload: EbookFulltext, root: URL? = nil)")
    save_body = source[save_start : source.index("\n    }", save_start) + 7]
    assert "clearEvicted(jobId: payload.jobId)" in save_body

    emit_start = source.index("private func emit(_ payload: EbookFulltext)")
    emit_body = source[emit_start : source.index("\n    }", emit_start) + 7]
    assert "guard !Self.isEvicted(jobId: payload.jobId) else { return }" in emit_body


def test_library_controller_evicts_fulltext_store_before_removing_book() -> None:
    source = _read("Features/Library/Views/LibraryScreenController.swift")
    remove_start = source.index("private func remove(book:")
    body = source[remove_start : source.index("\n    }", remove_start) + 6]

    assert "if let jobId = book.lastJobId" in body
    assert "FulltextStore.evict(jobId: jobId)" in body
    assert body.index("FulltextStore.evict(jobId: jobId)") < body.index(
        "library.remove(id: book.id)"
    )
    assert body.index("LocalFulltextCache.evict(bookId: book.id)") < body.index(
        "FulltextStore.evict(jobId: jobId)"
    )


def test_mac_library_controller_evicts_fulltext_store_before_removing_book() -> None:
    source = _read("Features/Library/Views/MacLibraryViewController.swift")
    remove_start = source.index("private func removeSelectedBook")
    body = source[remove_start : source.index("\n    }", remove_start) + 6]

    assert "FulltextStore.evict(jobId: jobID)" in body
    assert body.index("FulltextStore.evict(jobId: jobID)") < body.index("library.remove(id: id)")
    assert body.index("LocalFulltextCache.evict(bookId: id)") < body.index(
        "FulltextStore.evict(jobId: jobID)"
    )
