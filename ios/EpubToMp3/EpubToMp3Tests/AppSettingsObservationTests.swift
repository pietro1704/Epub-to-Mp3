import XCTest
import Combine
@testable import EpubToMp3

/// Regression for the long-standing bug where toolbar pickers in
/// `ReaderView` looked dead until the next page-turn: the previous
/// `@AppStorage`-on-an-ObservableObject hybrid only published change
/// events inside `View` bodies that re-read the wrapper directly, so
/// any nested SwiftUI sub-body (GeometryReader, the menu sheet, etc.)
/// kept seeing stale values.
///
/// Each test below subscribes to `settings.objectWillChange` and
/// asserts the publisher fires when the property mutates. If any case
/// regresses, the reader UI will stop repainting on toolbar changes.
final class AppSettingsObservationTests: XCTestCase {

    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    private func makeSettings() -> AppSettings {
        // Suite-name UUID guarantees a clean slate per test so we
        // never observe a value coming back from a sibling test.
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        return AppSettings(defaults: defaults)
    }

    /// Asserts `settings.objectWillChange` fires at least once when
    /// `mutate` runs. The keyPath is taken so the test signature stays
    /// identical to the previous `withObservationTracking`-based
    /// version, even though Combine subscribes to the publisher itself
    /// rather than a single property read.
    private func observe<T>(
        _ keyPath: KeyPath<AppSettings, T>,
        on settings: AppSettings,
        message: String,
        mutate: () -> Void
    ) {
        let exp = expectation(description: message)
        exp.assertForOverFulfill = false
        settings.objectWillChange
            .sink { _ in exp.fulfill() }
            .store(in: &cancellables)
        mutate()
        wait(for: [exp], timeout: 1.0)
    }

    // MARK: Core typography

    func testReaderFontSizeChangeFiresObservation() {
        let s = makeSettings()
        observe(\.readerFontSize, on: s, message: "fontSize observed") {
            s.readerFontSize = 3
        }
    }

    func testReaderFontFamilyChangeFiresObservation() {
        let s = makeSettings()
        observe(\.readerFontFamily, on: s, message: "fontFamily observed") {
            s.readerFontFamily = .mono
        }
    }

    func testReaderThemeChangeFiresObservation() {
        let s = makeSettings()
        observe(\.readerTheme, on: s, message: "theme observed") {
            s.readerTheme = .sepia
        }
    }

    func testReaderLayoutChangeFiresObservation() {
        let s = makeSettings()
        observe(\.readerLayout, on: s, message: "layout observed") {
            s.readerLayout = .paginated
        }
    }

    func testReaderLineSpacingChangeFiresObservation() {
        let s = makeSettings()
        observe(\.readerLineSpacing, on: s, message: "lineSpacing observed") {
            s.readerLineSpacing = 12
        }
    }

    func testReaderMarginChangeFiresObservation() {
        let s = makeSettings()
        observe(\.readerMargin, on: s, message: "margin observed") {
            s.readerMargin = 48
        }
    }

    /// Regression for the 2026-05-12 portrait-clipping bug: assigning a
    /// margin below the HIG-minimum 16pt must be coerced upward, not
    /// honoured. The reader's `effectiveReaderMargin` also guards but
    /// the clamp belongs at the model layer first.
    func testReaderMarginClampsBelowHIGMinimum() {
        let s = makeSettings()
        s.readerMargin = 12
        XCTAssertGreaterThanOrEqual(s.readerMargin, 16,
            "Margins below 16pt clipped portrait text and must be clamped")
        s.readerMargin = 8
        XCTAssertGreaterThanOrEqual(s.readerMargin, 16)
        s.readerMargin = 0
        XCTAssertGreaterThanOrEqual(s.readerMargin, 16)
    }

    /// Upper bound is unchanged but the test below pins it so a future
    /// edit cannot accidentally remove the clamp altogether.
    func testReaderMarginClampsAboveMaximum() {
        let s = makeSettings()
        s.readerMargin = 999
        XCTAssertLessThanOrEqual(s.readerMargin, 80)
    }

    /// Stale persisted values from older builds (when the clamp was
    /// 8pt) must be coerced on load too, otherwise the bug returns on
    /// every existing install.
    func testReaderMarginPersistedStaleValueIsCoercedOnLoad() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        // Simulate a pre-fix install that persisted 12pt.
        defaults.set(12.0, forKey: "readerMargin")
        let s = AppSettings(defaults: defaults)
        XCTAssertGreaterThanOrEqual(s.readerMargin, 16,
            "Persisted 12pt from older build must be clamped on load")
    }

    func testReaderColumnWidthChangeFiresObservation() {
        let s = makeSettings()
        observe(\.readerColumnWidth, on: s, message: "columnWidth observed") {
            s.readerColumnWidth = 820
        }
    }

    // MARK: Override knobs

    func testReaderBoldOverrideChangeFiresObservation() {
        let s = makeSettings()
        observe(\.readerBoldOverride, on: s, message: "boldOverride observed") {
            s.readerBoldOverride = true
        }
    }

    func testReaderLetterSpacingChangeFiresObservation() {
        let s = makeSettings()
        observe(\.readerLetterSpacing, on: s, message: "letterSpacing observed") {
            s.readerLetterSpacing = 1.5
        }
    }

    // MARK: Persistence — values survive an AppSettings re-init
    //
    // Critical: `@Published` + `didSet` UserDefaults writes must
    // round-trip cleanly. A bug here used to drop every reader pref
    // on app relaunch.

    func testReaderFieldsPersistAcrossInstances() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!

        do {
            let s = AppSettings(defaults: defaults)
            s.readerFontSize = 4
            s.readerFontFamily = .mono
            s.readerTheme = .dark
            s.readerLineSpacing = 14
            s.readerMargin = 36
            s.readerColumnWidth = 640
            s.readerBoldOverride = true
            s.readerLetterSpacing = 2.0
        }

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.readerFontSize, 4)
        XCTAssertEqual(reloaded.readerFontFamily, .mono)
        XCTAssertEqual(reloaded.readerTheme, .dark)
        XCTAssertEqual(reloaded.readerLineSpacing, 14, accuracy: 0.001)
        XCTAssertEqual(reloaded.readerMargin, 36, accuracy: 0.001)
        XCTAssertEqual(reloaded.readerColumnWidth, 640, accuracy: 0.001)
        XCTAssertTrue(reloaded.readerBoldOverride)
        XCTAssertEqual(reloaded.readerLetterSpacing, 2.0, accuracy: 0.001)
    }

    // MARK: restoreOriginal()

    func testRestoreOriginalResetsAllOverrideFields() {
        let s = makeSettings()
        s.readerOverrideFontFamily = true
        s.readerOverrideFontSize = true
        s.readerOverrideColours = true
        s.readerBoldOverride = true
        s.readerSuppressItalic = true
        s.readerLetterSpacing = 2
        s.readerWordSpacing = 3
        // Preserved preferences (not in the override reset set):
        s.readerTheme = .dark
        s.readerFontFamily = .mono
        s.readerLineSpacing = 12

        s.restoreOriginal()

        XCTAssertFalse(s.readerOverrideFontFamily)
        XCTAssertFalse(s.readerOverrideFontSize)
        XCTAssertFalse(s.readerOverrideColours)
        XCTAssertFalse(s.readerBoldOverride)
        XCTAssertFalse(s.readerSuppressItalic)
        XCTAssertEqual(s.readerLetterSpacing, 0, accuracy: 0.001)
        XCTAssertEqual(s.readerWordSpacing, 0, accuracy: 0.001)
        // Preserved
        XCTAssertEqual(s.readerTheme, .dark)
        XCTAssertEqual(s.readerFontFamily, .mono)
        XCTAssertEqual(s.readerLineSpacing, 12, accuracy: 0.001)
    }

    // MARK: useEmbeddedRuntime — read paths must not block on backend URL
    //
    // Regression for the "Reader needs the backend" bug: the reader
    // pipeline (EpubMetadataReader + PythonBridge.parseEpub on iOS,
    // embedded Python runtime on macOS) is fully on-device. The
    // `useEmbeddedRuntime` flag must default to `true` on a fresh
    // install so first-launch users never see the "Configure the URL"
    // wall and `canReadOffline` mirrors the flag exactly.

    func testEmbeddedRuntimeDefaultsToOnForFreshInstall() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let s = AppSettings(defaults: defaults)
        XCTAssertTrue(s.useEmbeddedRuntime,
                      "Fresh installs must default to the embedded runtime so the reader never asks for a backend URL.")
        XCTAssertTrue(s.canReadOffline,
                      "canReadOffline must mirror useEmbeddedRuntime — it gates the BookOpenView audio bootstrap copy.")
    }

    func testReaderLayoutDefaultsToPaginatedForFreshInstall() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let s = AppSettings(defaults: defaults)
        XCTAssertEqual(s.readerLayout, .paginated,
                       "Fresh installs must default to paginated mode, not scrolling.")
    }

    func testEmbeddedRuntimePersistsAcrossInstances() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        do {
            let s = AppSettings(defaults: defaults)
            s.useEmbeddedRuntime = false
        }
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertFalse(reloaded.useEmbeddedRuntime,
                       "useEmbeddedRuntime must round-trip through UserDefaults — power users need their off-state to survive relaunch.")
        XCTAssertFalse(reloaded.canReadOffline)
    }

    func testEmbeddedRuntimeChangeFiresObservation() {
        let s = makeSettings()
        observe(\.useEmbeddedRuntime, on: s, message: "useEmbeddedRuntime observed") {
            s.useEmbeddedRuntime = false
        }
    }

    /// The reader must not depend on the backend URL when the embedded
    /// runtime is on. Concretely: with no `backendURL` and no
    /// `canReadOffline` is still `true`, so the
    /// `BookOpenView` open flow won't gate parsing on a network
    /// resource.
    func testReaderCanReadOfflineEvenWithBlankBackendURL() {
        let s = makeSettings()
        s.useEmbeddedRuntime = true
        s.backendURL = ""
        XCTAssertNil(s.resolvedBaseURL,
                     "Pre-condition: no URL resolvable.")
        XCTAssertTrue(s.canReadOffline,
                      "Reader must remain available without any backend URL when the embedded runtime is on.")
    }

    /// The embedded runtime remains authoritative while a remote URL is
    /// retained only for explicit remote-backend screens.
    func testEmbeddedRuntimeRemainsAuthoritativeWithRemoteURL() {
        let s = makeSettings()
        s.useEmbeddedRuntime = true
        s.backendURL = "http://localhost:8000"
        XCTAssertNotNil(s.resolvedBaseURL,
                        "Remote URL remains available to explicit remote-backend screens.")
        XCTAssertTrue(s.useEmbeddedRuntime,
                      "Embedded runtime must remain authoritative even when a remote URL is present.")
    }

    func testRemoteBackendControlsDimWhenEmbeddedRuntimeIsEnabled() {
        let s = makeSettings()

        s.useEmbeddedRuntime = true
        XCTAssertFalse(s.remoteBackendControlsEnabled)

        s.useEmbeddedRuntime = false
        XCTAssertTrue(s.remoteBackendControlsEnabled)
    }
}
