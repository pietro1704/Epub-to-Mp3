import XCTest
#if os(macOS)
import AppKit
#endif
@testable import EpubToMp3

final class AppLaunchEnvironmentTests: XCTestCase {
    #if os(macOS)
    @MainActor
    func testMacXCTestHostStartsWithoutADockIcon() {
        XCTAssertEqual(NSApplication.shared.activationPolicy(), .accessory)
    }
    #endif

    @MainActor
    func testDetectsXCTestConfigurationFilePathEvenWhenEmpty() {
        XCTAssertTrue(EpubToMp3App.isRunningUnderXCTest(environment: [
            "XCTestConfigurationFilePath": ""
        ]))
    }

    @MainActor
    func testDetectsXcode26XCTestSessionIdentifier() {
        XCTAssertTrue(EpubToMp3App.isRunningUnderXCTest(environment: [
            "XCTestSessionIdentifier": "session-id"
        ]))
    }

    @MainActor
    func testDetectsInjectedXCTestBundlePath() {
        XCTAssertTrue(EpubToMp3App.isRunningUnderXCTest(environment: [
            "XCTestBundlePath": "Contents/PlugIns/EpubToMp3Tests.xctest"
        ]))
    }

    @MainActor
    func testDetectsLoadedXCTestClassWhenEnvironmentIsSanitized() {
        XCTAssertTrue(EpubToMp3App.isRunningUnderXCTest(
            environment: [:],
            classLookup: { name in name == "XCTest.XCTestCase" ? XCTestCase.self : nil }
        ))
    }

    @MainActor
    func testDoesNotDetectRegularLaunchEnvironment() {
        XCTAssertFalse(EpubToMp3App.isRunningUnderXCTest(
            environment: [
                "HOME": "/tmp",
                "PATH": "/usr/bin"
            ],
            classLookup: { _ in nil }
        ))
    }

    /// MAC-TESTS-WRITE-REAL-LIBRARY: a LibraryStore built without an explicit
    /// import directory copied test fixtures into the listener's library.
    func testDefaultImportedBooksDirectoryStaysOutOfTheRealLibraryUnderXCTest() throws {
        let directory = try LibraryImportFiles.importedBooksDirectory(fileManager: .default, baseDirectory: nil)
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: false)
        XCTAssertFalse(directory.standardizedFileURL.path.hasPrefix(support.standardizedFileURL.path),
                       "Tests must never write into \(support.path)")
        XCTAssertTrue(directory.standardizedFileURL.path.hasPrefix(
            FileManager.default.temporaryDirectory.standardizedFileURL.path))
    }
    /// MAC-TESTS-OTHER-STORES-ISOLATION: the reader caches, fonts, Rust
    /// conversion outputs and audiobook folders also resolved to the real
    /// Application Support while unit tests ran inside the app host.
    func testDefaultStoreRootsStayOutOfTheRealApplicationSupportUnderXCTest() throws {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: false)
            .resolvingSymlinksInPath().standardizedFileURL.path + "/"
        var roots: [(String, URL?)] = [
            ("ReaderFulltext", LocalFulltextCache.storageURL(bookId: "isolation-probe")),
            ("ReaderFonts", EpubFontManager.persistentDirectory(bookID: "isolationprobe")),
            ("RustConversions", RustConversionOutputStore.defaultRoot),
        ]
        #if os(macOS)
        roots.append(("Audiobooks", AudiobookDownloadStorage.audiobooksRootLocation()))
        #endif
        for (name, root) in roots {
            let path = try XCTUnwrap(root, name).resolvingSymlinksInPath().standardizedFileURL.path
            XCTAssertFalse(path.hasPrefix(support), "\(name) must not resolve into \(support) under XCTest: \(path)")
        }
    }

    func testSharedStoreRootIsTheRealApplicationSupportOutsideTests() throws {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: false)
        XCTAssertEqual(ApplicationSupportRoot.url(underXCTest: false).standardizedFileURL.path,
                       support.standardizedFileURL.path)
    }
}
