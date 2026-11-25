#if os(macOS)
import AppKit
import XCTest
@testable import EpubToMp3

/// Renders the macOS reader voice menu of a book with its own voice, for the PR's visual evidence.
/// It only writes files when EPUB2MP3_MODELS_SNAPSHOT_DIR (or its marker file) is set.
@MainActor
final class ReaderVoiceMenuSnapshotTests: XCTestCase {
    func testRenderTheMenuOfABookWithItsOwnVoice() async throws {
        guard let directory = ProcessInfo.processInfo.environment["EPUB2MP3_MODELS_SNAPSHOT_DIR"]
            ?? (try? String(contentsOfFile: "/tmp/epub2mp3-models-snapshot-dir", encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        else { throw XCTSkip("Set EPUB2MP3_MODELS_SNAPSHOT_DIR to render") }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let suite = "voice-menu-snapshot-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let book = BookEntity(id: suite, title: "Book", bookmark: Data([1]), displayFilename: "book.epub", addedAt: Date())
        settings.bookVoices.set(.systemDefault, bookID: book.id)
        let request = ReaderVoicePickerRequest(settings: settings, library: LibraryStore(defaults: defaults),
            player: AudioPlayer(), currentContext: { .init(book: book) }, restart: { _, _ in })
        let reader = NSViewController()
        let anchor = NSView(frame: NSRect(x: 40, y: 320, width: 40, height: 24))
        reader.view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 420))
        reader.view.addSubview(anchor)
        let window = NSWindow(contentViewController: reader)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let captured = expectation(description: "The menu was captured")
        var image: CGImage?
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
            object: nil, queue: .main) { notification in
            MainActor.assumeIsolated {
                guard let menu = notification.object as? NSMenu, menu.title == L10n.string("models.title") else { return }
                XCTAssertTrue(menu.items.contains { $0.title == L10n.string("models.bookVoice.useDefault") })
                let timer = Timer(timeInterval: 1, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
                        let menuWindow = windows.first {
                            $0[kCGWindowOwnerPID as String] as? Int32 == ProcessInfo.processInfo.processIdentifier
                                && ($0[kCGWindowLayer as String] as? Int ?? 0) >= Int(CGWindowLevelForKey(.popUpMenuWindow))
                        }
                        if let number = menuWindow?[kCGWindowNumber as String] as? CGWindowID {
                            image = CGWindowListCreateImage(.null, .optionIncludingWindow, number,
                                                            [.boundsIgnoreFraming, .bestResolution])
                        }
                        menu.cancelTracking()
                        captured.fulfill()
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let presenter = MacReaderVoicePickerPresenter()
        presenter.present(from: reader, anchor: anchor, request: request)
        await fulfillment(of: [captured], timeout: 30)
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: try XCTUnwrap(image)).representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("reader-voice-menu.png"))
    }
}
#endif
