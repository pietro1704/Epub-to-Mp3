"""Regression checks for native macOS reader update behavior."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ROOT_CONTROLLER = ROOT / "ios" / "EpubToMp3" / "EpubToMp3" / "App" / "MacAppKitRootController.swift"
READER_CONTROLLER = (
    ROOT
    / "ios"
    / "EpubToMp3"
    / "EpubToMp3"
    / "Features"
    / "Reader"
    / "Views"
    / "MacReaderViewController.swift"
)
LIBRARY_CONTROLLER = (
    ROOT
    / "ios"
    / "EpubToMp3"
    / "EpubToMp3"
    / "Features"
    / "Library"
    / "Views"
    / "MacLibraryViewController.swift"
)
JOBS_CONTROLLER = (
    ROOT
    / "ios"
    / "EpubToMp3"
    / "EpubToMp3"
    / "Features"
    / "Conversion"
    / "Views"
    / "MacJobsListViewController.swift"
)
SETTINGS_CONTROLLER = (
    ROOT
    / "ios"
    / "EpubToMp3"
    / "EpubToMp3"
    / "Features"
    / "Settings"
    / "Views"
    / "MacSettingsViewController.swift"
)


def test_root_does_not_recreate_reader_for_each_library_publish() -> None:
    source = ROOT_CONTROLLER.read_text(encoding="utf-8")

    assert "refreshDetailIfNeeded" not in source
    assert "library.$books.sink" not in source


def test_reader_does_not_reload_after_its_own_last_opened_update() -> None:
    source = READER_CONTROLLER.read_text(encoding="utf-8")

    assert "library.$books.sink" not in source


def test_root_embeds_selected_detail_controller_with_constraints() -> None:
    source = ROOT_CONTROLLER.read_text(encoding="utf-8")

    assert "detailContainer.addChild(controller)" in source
    assert "detailContainer.view.addSubview(contentView)" in source
    assert (
        "contentView.leadingAnchor.constraint(equalTo: detailContainer.view.leadingAnchor)"
        in source
    )
    assert "contentView.bottomAnchor.constraint(equalTo: playerBar.view.topAnchor)" in source
    assert "detailContainer.view.addSubview(playerBar.view)" in source
    assert "addChild(playerBar)" not in source
    assert (
        "UserDefaults.standard.string(forKey: ReaderSessionState.currentlyReadingBookIDKey)"
        in source
    )
    assert "library.books.contains { $0.lastOpenedAt != nil }" in source
    assert "playerBarHeightConstraint?.constant = hasReadingContext ? 58 : 0" in source
    assert "\n        view.addSubview(playerBar.view)" not in source
    assert "override func viewDidAppear()" in source
    assert "view.frame = contentView.bounds" in source


def test_root_reuses_native_destination_controllers() -> None:
    source = ROOT_CONTROLLER.read_text(encoding="utf-8")

    assert "private var controllers: [Destination: NSViewController] = [:]" in source
    assert "if let existing = controllers[destination]" in source
    assert "if let detailController, detailController === controllers[destination]" in source
    assert "splitViewItems[0].canCollapse = true" in source
    assert "@objc private func toggleNavigationSidebar()" in source
    assert "sidebarItem.isCollapsed.toggle()" in source
    assert "for destination in Destination.allCases" in source
    assert "#selector(sidebarButtonActivated(_:))" in source
    assert "@objc private func sidebarButtonActivated(_ sender: NSButton)" in source
    assert "private var sidebarButtons: [Destination: NSButton] = [:]" in source
    assert "private func updateSidebarSelection(_ destination: Destination)" in source
    assert "button.state = selected ? .on : .off" in source
    assert "button.layer?.backgroundColor = selected" in source
    assert "NSTableViewDataSource" not in source


def test_reader_is_opened_from_library_and_not_exposed_in_sidebar() -> None:
    root = ROOT_CONTROLLER.read_text(encoding="utf-8")
    library = LIBRARY_CONTROLLER.read_text(encoding="utf-8")
    reader = READER_CONTROLLER.read_text(encoding="utf-8")

    assert "case reader" not in root
    # Library grid opens Book Detail first (P0 gap #4), whose "Read" action
    # is what actually shows the reader — see `showBookDetail`/`onRead`.
    assert "onOpenBook: { [weak self] bookID in self?.showBookDetail(bookID: bookID) }" in root
    assert "onRead: { [weak self] bookID in self?.showReader(bookID: bookID) }" in root
    assert "private func showBookDetail(bookID: String)" in root
    assert "private func showReader(bookID: String)" in root
    assert "onOpenBook(book.id)" in library
    assert "bookItem.configure(with: book, onOpen:" in library
    assert "private let openButton = NSButton()" in library
    assert "openButton.action = #selector(openBook)" in library
    assert "openButton.leadingAnchor.constraint(equalTo: root.leadingAnchor)" in library
    assert "@objc private func openBook() { onOpen?() }" in library
    assert "openButton.setAccessibilityLabel(book.resolvedTitle)" in library
    assert "didSelectItemsAt indexPaths: Set<IndexPath>" in library
    assert "open(books[indexPath.item])" in library
    assert "view.setAccessibilityChildren([openButton])" in library
    assert (
        "view.setAccessibilityChildren([searchField, sortButton, collectionView, emptyLabel, addButton])"
        in library
    )
    assert "collectionView.setAccessibilityElement(true)" in library
    assert "collectionView.setAccessibilityChildren(" in library
    assert "collectionView.visibleItems().compactMap { $0.view }" in library
    assert "openButton.setAccessibilityLabel(book.resolvedTitle)" in library
    assert "onClose: @escaping () -> Void" in reader
    assert "@objc private func closeReader() { onClose() }" in reader


def test_reader_cell_retains_label_before_assigning_weak_outlet() -> None:
    source = READER_CONTROLLER.read_text(encoding="utf-8")

    assert "cell.addSubview(textField)\n            cell.textField = textField" in source
    assert "cell.addSubview(cell.textField!)" not in source


def test_reader_cell_uses_a_safe_chapter_index_during_table_reloads() -> None:
    source = READER_CONTROLLER.read_text(encoding="utf-8")

    # Rows come from `ReaderTocFlattener` (flat chapter list or TOC
    # hierarchy) since the P0 TOC-hierarchy slice, but the safe-subscript
    # guard against a stale `row` during a reload is still in place.
    assert "tocRows[safe: row]" in source


def test_reader_expands_content_and_skips_empty_cover_sections() -> None:
    source = READER_CONTROLLER.read_text(encoding="utf-8")

    assert "final class MacReaderViewController: NSViewController" in source
    assert "NSSplitViewController" not in source
    assert "private let tocPopover = NSPopover()" in source
    assert "tocPopover.behavior = .transient" in source
    assert "@objc private func showTOC" in source
    assert "contentScrollView.documentView = textView" in source
    assert (
        "contentScrollView.trailingAnchor.constraint(equalTo: chapterTitleLabel.trailingAnchor)"
        in source
    )
    assert (
        "contentScrollView.leadingAnchor.constraint(equalTo: chapterTitleLabel.leadingAnchor)"
        in source
    )
    assert "firstReadableChapter" in source
    assert "count >= 80" in source
    assert 'L10n.string("reader.chapterCount", payload.chapters.count)' in source
    assert "private final class MacReaderSurfaceView: NSView" in source
    assert "private final class MacReaderTextView: NSTextView" in source
    assert "override func viewDidAppear()" in source
    assert "view.window?.makeFirstResponder(view)" in source
    assert "case 124, 125, 49:" in source
    assert "case 123, 126:" in source
    assert "case 53:" in source
    assert "private func scrollPage(forward: Bool)" in source
    assert "contentScrollView.reflectScrolledClipView(clipView)" in source


def test_library_creates_programmatic_collection_items_without_unarchiving() -> None:
    source = LIBRARY_CONTROLLER.read_text(encoding="utf-8")

    assert "MacBookCollectionItem(nibName: nil, bundle: nil)" in source
    assert "collectionView.makeItem" not in source
    assert "coverView.layer?.backgroundColor" not in source


def test_jobs_and_settings_use_localized_semantic_labels() -> None:
    jobs = JOBS_CONTROLLER.read_text(encoding="utf-8")
    settings = SETTINGS_CONTROLLER.read_text(encoding="utf-8")

    assert 'titleColumn.title = L10n.string("jobs.book")' in jobs
    assert 'detailColumn.title = L10n.string("jobs.status")' in jobs
    assert "detailColumn.resizingMask = .autoresizingMask" in jobs
    assert "conversions.jsonl" in jobs
    assert "JSONDecoder()" in jobs
    assert "backendField" not in settings
    assert 'L10n.string("settings.fontStep", settings.readerFontSize + 1, 5)' in settings
