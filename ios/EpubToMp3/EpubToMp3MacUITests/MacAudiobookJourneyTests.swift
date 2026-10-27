import XCTest
import AppKit

/// Drives the shipping application through its actual AppKit controls.
@MainActor
final class MacAudiobookJourneyTests: XCTestCase {
    private var application: XCUIApplication?
    private var savedClipboard: [[NSPasteboard.PasteboardType: Data]]?
    private var ownedClipboardChange: Int?

    override func tearDownWithError() throws {
        if let app = application, app.state != .notRunning {
            app.typeKey(.escape, modifierFlags: [])
            app.terminate()
        }
        application = nil
        let board = NSPasteboard.general
        if board.changeCount == ownedClipboardChange, let savedClipboard {
            board.clearContents()
            let items = savedClipboard.map { values in
                let item = NSPasteboardItem()
                values.forEach { item.setData($0.value, forType: $0.key) }
                return item
            }
            if !items.isEmpty { board.writeObjects(items) }
        }
        savedClipboard = nil

    }

    func testRealApplicationAudiobookJourney() throws {
        continueAfterFailure = false
        let (app, root, container) = try acceptanceApplication()
        application = app
        dismissOwnedCrashNotice()
        app.launch()
        defer {
            if app.state != .notRunning {
                app.typeKey(.escape, modifierFlags: [])
                app.terminate()
            }
        }
        XCTAssertTrue(app.buttons["library.add"].waitForExistence(timeout: 15))
        attach(app, name: "01-isolated-library")
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "launch-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        let importedBooks = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.book.open."))
        XCTAssertTrue(importedBooks.allElementsBoundByIndex.allSatisfy { $0.label == "Mac Acceptance Journey" },
                      "Acceptance must not load the user's existing library")
        XCTAssertTrue(FileManager.default.fileExists(atPath: container.appendingPathComponent(
            "Library/Application Support/EpubToMp3/TTSModels/pt_BR-faber-medium/model.onnx").path))
        app.buttons["Settings"].firstMatch.click()
        let language = app.popUpButtons["settings.speechModels.language"]
        XCTAssertTrue(language.waitForExistence(timeout: 15))
        language.click()
        app.menuItems.matching(NSPredicate(format: "title == %@", "Portuguese (Brazil)")).firstMatch.click()
        try waitUntil(seconds: 10) { (language.value as? String)?.contains("Portuguese") == true }
        let preview = app.buttons["settings.speechModel.pt_BR-faber-medium.preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 20), app.debugDescription)
        attach(app, name: "02-real-installed-faber")
        preview.click()
        XCTAssertTrue(app.windows.buttons["Stop sample"].firstMatch.waitForExistence(timeout: 10))
        app.windows.buttons["Stop sample"].firstMatch.click()
        try waitUntil(seconds: 5) { !app.windows.buttons["Stop sample"].firstMatch.exists }
        preview.click()
        XCTAssertTrue(app.buttons["Stop sample"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Sample finished"].waitForExistence(timeout: 30), app.debugDescription)
        attach(app, name: "03-real-faber-preview-completed")
        app.windows.buttons["Stop sample"].firstMatch.click()
        app.popUpButtons["settings.tts.primary"].click()
        app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", "System voice")).firstMatch.click()
        let select = app.buttons["settings.speechModel.pt_BR-faber-medium.select"]
        XCTAssertTrue(select.waitForExistence(timeout: 10))
        select.click()
        XCTAssertTrue((app.popUpButtons["settings.tts.primary"].value as? String)?.contains("Faber") == true)

        app.buttons["Library"].firstMatch.click()
        let convert = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.book.convert.")).firstMatch
        if !convert.exists {
        app.buttons["library.add"].click()
        app.typeKey("g", modifierFlags: [.command, .shift])
        let pathField = app.textFields["PathTextField"]
        XCTAssertTrue(pathField.waitForExistence(timeout: 5))
        paste(root.appendingPathComponent("MacAcceptance.epub").path, into: pathField)
        XCTAssertEqual(pathField.value as? String, root.appendingPathComponent("MacAcceptance.epub").path)
        attach(app, name: "04-file-picker-target")
        pathField.typeKey(.return, modifierFlags: [])
        try waitUntil(seconds: 10) { !pathField.exists }
        let open = app.buttons["OKButton"]
        try waitUntil(seconds: 5) { open.isEnabled }
        open.click()
        }
        XCTAssertTrue(convert.waitForExistence(timeout: 20), app.debugDescription)
        attach(app, name: "04-imported-real-epub")
        convert.click()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        app.dialogs.buttons["Cancel"].firstMatch.click()
        let pronunciation = app.buttons["bookDetail.pronunciation"]
        XCTAssertTrue(pronunciation.waitForExistence(timeout: 5), app.debugDescription)
        pronunciation.click()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        paste("Tolkien = Tólkien", into: editor)
        attach(app, name: "05-pronunciation-editor")
        app.dialogs.buttons["Save"].firstMatch.click()
        pronunciation.click()
        XCTAssertEqual(app.textViews.firstMatch.value as? String, "Tolkien = Tólkien")
        app.dialogs.buttons["Cancel"].firstMatch.click()

        // Keep the interrupted chapter fresh even when this journey is repeated.
        pronunciation.click()
        paste("Tolkien = Tólkien " + String(UUID().uuidString.prefix(4)), into: app.textViews.firstMatch)
        app.dialogs.buttons["Save"].firstMatch.click()

        let support = container.appendingPathComponent("Library/Application Support/EpubToMp3")
        let outputs = support.appendingPathComponent("RustConversions")
        let existingJobs = jobDirectories(outputs)
        app.buttons["bookDetail.convert"].click()
        app.buttons.matching(NSPredicate(format: "title == %@ AND identifier != %@",
            "Convert", "bookDetail.convert")).firstMatch.click()
        let progress = app.staticTexts["bookDetail.progress"]
        try waitUntil(seconds: 90) {
            self.jobDirectories(outputs).subtracting(existingJobs).contains { job in
                self.completedAudio(in: URL(fileURLWithPath: job)).count == 1
            }
        }
        let interruptedJob = try XCTUnwrap(jobDirectories(outputs).subtracting(existingJobs).first)
        attach(app, name: "06-real-conversion-progress")
        let preserved = try XCTUnwrap(completedAudio(in: URL(fileURLWithPath: interruptedJob)).first)
        let preservedAudio = try Data(contentsOf: preserved)
        let preservedReceipt = try Data(contentsOf: preserved.withExtension("mp3.complete.json"))
        let savedProgress = progress.value as? String ?? progress.label
        add(XCTAttachment(string: "Visible conversion progress: \(savedProgress)"))
        app.terminate()
        XCTAssertEqual(app.state, .notRunning)
        XCTAssertEqual(completedAudio(in: URL(fileURLWithPath: interruptedJob)).count, 1)
        app.launch()
        XCTAssertTrue(app.buttons["Settings"].firstMatch.waitForExistence(timeout: 15))
        app.buttons["Settings"].firstMatch.click()
        XCTAssertTrue(app.popUpButtons["settings.tts.primary"].waitForExistence(timeout: 10))
        app.buttons["Library"].firstMatch.click()
        XCTAssertTrue(convert.waitForExistence(timeout: 15))
        convert.click()
        app.dialogs.buttons["Cancel"].firstMatch.click()
        let resume = app.buttons["bookRecovery.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 15), app.debugDescription)
        attach(app, name: "07-real-interruption-recovery")
        let priorJobs = jobDirectories(outputs)
        resume.click()
        try waitUntil(seconds: 120) {
            self.jobDirectories(outputs).subtracting(priorJobs).contains { job in
                self.completedAudio(in: URL(fileURLWithPath: job)).count == 2
            }
        }
        let recoveredJob = try XCTUnwrap(jobDirectories(outputs).subtracting(priorJobs).first)
        let recovered = completedAudio(in: URL(fileURLWithPath: recoveredJob))
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertEqual(recovered.count, 2)
        XCTAssertEqual(try Data(contentsOf: recovered[0]), preservedAudio)
        XCTAssertEqual(try Data(contentsOf: recovered[0].withExtension("mp3.complete.json")), preservedReceipt)
        XCTAssertFalse(resume.exists)
        attach(app, name: "08-real-resumed-conversion-complete")
        for audio in recovered {
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
                audio.withExtension("mp3.complete.json"))) as? [String: Any])
            XCTAssertEqual(value["provider"] as? String, "piper")
            XCTAssertEqual(value["fallback_used"] as? Bool, false)
            XCTAssertGreaterThan((value["size"] as? Int) ?? 0, 100)
        }
        pronunciation.click()
        paste("Tolkien = Tólkien", into: app.textViews.firstMatch)
        app.dialogs.buttons["Save"].firstMatch.click()
    }

    func testLibraryConversionButtonAfterNavigation() throws {
        continueAfterFailure = false
        let (app, _, _) = try acceptanceApplication()
        application = app
        app.launch()
        let convert = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.book.convert.")).firstMatch
        XCTAssertTrue(convert.waitForExistence(timeout: 15))
        attach(app, name: "library-before-navigation")
        add(XCTAttachment(string: "Before navigation: \(convert.frame), hittable=\(convert.isHittable)"))
        app.buttons["Settings"].firstMatch.click()
        XCTAssertTrue(app.popUpButtons["settings.tts.primary"].waitForExistence(timeout: 10))
        app.buttons["Library"].firstMatch.click()
        attach(app, name: "library-after-navigation")
        add(XCTAttachment(string: "After navigation: \(convert.frame), hittable=\(convert.isHittable)"))
        convert.click()
        XCTAssertTrue(app.dialogs.buttons["Cancel"].firstMatch.waitForExistence(timeout: 5))
        app.dialogs.buttons["Cancel"].firstMatch.click()
        XCTAssertTrue(app.buttons["bookDetail.pronunciation"].waitForExistence(timeout: 5))
    }

    func testPersistentCacheAndPronunciation() throws {
        continueAfterFailure = false
        let (app, _, container) = try acceptanceApplication()
        application = app
        app.launch()
        XCTAssertTrue(app.buttons["Settings"].firstMatch.waitForExistence(timeout: 15))
        app.buttons["Settings"].firstMatch.click()
        XCTAssertTrue(app.popUpButtons["settings.tts.primary"].waitForExistence(timeout: 10))
        app.buttons["Library"].firstMatch.click()
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.book.convert.")).firstMatch.click()
        app.dialogs.buttons["Cancel"].firstMatch.click()
        let pronunciation = app.buttons["bookDetail.pronunciation"]
        pronunciation.click()
        XCTAssertEqual(app.textViews.firstMatch.value as? String, "Tolkien = Tólkien")
        paste("Tolkien = discarded", into: app.textViews.firstMatch)
        app.dialogs.buttons["Cancel"].firstMatch.click()
        pronunciation.click()
        XCTAssertEqual(app.textViews.firstMatch.value as? String, "Tolkien = Tólkien")
        paste("invalid rule", into: app.textViews.firstMatch)
        app.dialogs.buttons["Save"].firstMatch.click()
        XCTAssertTrue(app.dialogs.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", "Use unique terms")).firstMatch.waitForExistence(timeout: 5))
        app.dialogs.buttons["OK"].firstMatch.click()
        pronunciation.click()
        XCTAssertEqual(app.textViews.firstMatch.value as? String, "Tolkien = Tólkien")
        app.dialogs.buttons["Cancel"].firstMatch.click()

        let outputs = container.appendingPathComponent("Library/Application Support/EpubToMp3/RustConversions")
        let cached = outputs.appendingPathComponent(".cache/speech-segments-v1")
        let cacheFiles = try FileManager.default.contentsOfDirectory(at: cached, includingPropertiesForKeys: nil)
            .map { $0.appendingPathComponent("audio.mp3") }.filter { FileManager.default.fileExists(atPath: $0.path) }
        XCTAssertFalse(cacheFiles.isEmpty)
        let cacheDates = try cacheFiles.map { try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        let existing = jobDirectories(outputs)
        startManualConversion(app)
        let replay = try waitForCompletedJob(outputs, excluding: existing)
        let replayLog = try String(contentsOf: replay.appendingPathComponent("conversion.log"), encoding: .utf8)
        XCTAssertNotNil(replayLog.range(of: "cached_segments=[1-9][0-9]*", options: .regularExpression))
        XCTAssertEqual(try cacheFiles.map { try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }, cacheDates)
        let replayAudio = completedAudio(in: replay).sorted { $0.lastPathComponent < $1.lastPathComponent }
        attach(app, name: "09-persistent-cache-replay-complete")
        let cacheEvidence = XCTAttachment(string: replayLog)
        cacheEvidence.name = "persistent-cache-runtime-log"
        cacheEvidence.lifetime = .keepAlways
        add(cacheEvidence)

        pronunciation.click()
        paste("Tolkien = Tóuquien " + String(UUID().uuidString.prefix(4)), into: app.textViews.firstMatch)
        app.dialogs.buttons["Save"].firstMatch.click()
        let beforeChanged = jobDirectories(outputs)
        startManualConversion(app)
        let progress = app.staticTexts["bookDetail.progress"]
        try waitUntil(seconds: 60) { (progress.value as? String ?? progress.label).contains("remaining") }
        attach(app, name: "10-chunk-progress-and-estimate")
        let changed = try waitForCompletedJob(outputs, excluding: beforeChanged)
        let changedAudio = completedAudio(in: changed).sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertEqual(changedAudio.count, 2)
        XCTAssertNotEqual(try Data(contentsOf: changedAudio[0]), try Data(contentsOf: replayAudio[0]))
        pronunciation.click()
        paste("Tolkien = Tólkien", into: app.textViews.firstMatch)
        app.dialogs.buttons["Save"].firstMatch.click()

    }

    func testPlaybackClockAdvancesAndPauses() throws {
        continueAfterFailure = false
        let (app, _, _) = try acceptanceApplication()
        application = app
        app.launch()
        XCTAssertTrue(app.buttons["Settings"].firstMatch.waitForExistence(timeout: 15))
        app.buttons["Settings"].firstMatch.click()
        XCTAssertTrue(app.popUpButtons["settings.tts.primary"].waitForExistence(timeout: 10))
        app.buttons["Library"].firstMatch.click()
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.book.convert.")).firstMatch.click()
        app.dialogs.buttons["Cancel"].firstMatch.click()
        app.windows.buttons.matching(NSPredicate(format: "title IN %@", ["Listen", "Resume audio"])).firstMatch.click()
        let pause = app.windows.buttons["Pause"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 20))
        let remaining = app.staticTexts["fullPlayer.elapsed"]
        XCTAssertTrue(remaining.waitForExistence(timeout: 15))
        let initialTime = try XCTUnwrap(remaining.value as? String)
        attach(app, name: "playback-clock-before")
        let deadline = Date().addingTimeInterval(10)
        while (remaining.value as? String) == initialTime && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        attach(app, name: "playback-clock-after")
        let evidence = XCTAttachment(string: "Elapsed before: \(initialTime); after: \(String(describing: remaining.value))")
        evidence.lifetime = .keepAlways
        add(evidence)
        XCTAssertNotEqual(remaining.value as? String, initialTime)
        attach(app, name: "11-real-book-audio-playing")
        pause.click()
        XCTAssertTrue(app.windows.buttons["Play"].firstMatch.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.3)
        let pausedTime = remaining.value as? String
        Thread.sleep(forTimeInterval: 1.2)
        XCTAssertEqual(remaining.value as? String, pausedTime)
        attach(app, name: "12-real-book-audio-paused")
    }

    func testExplicitFaberInstallation() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["MAC_AUDIOBOOK_ALLOW_FABER_DOWNLOAD"] == "1" else {
            throw XCTSkip("Requires explicit authorization to download Faber into isolated test storage")
        }
        let (app, root, container) = try acceptanceApplication()
        application = app
        let model = container.appendingPathComponent("Library/Application Support/EpubToMp3/TTSModels/pt_BR-faber-medium")
        let retained = root.appendingPathComponent("retained-faber-installation")
        guard FileManager.default.fileExists(atPath: retained.appendingPathComponent("model.onnx").path) else {
            throw XCTSkip("Requires the existing isolated model to be retained externally before this journey")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.path))
        app.launch()
        XCTAssertTrue(app.buttons["Settings"].firstMatch.waitForExistence(timeout: 15))
        app.buttons["Settings"].firstMatch.click()
        let language = app.popUpButtons["settings.speechModels.language"]
        XCTAssertTrue(language.waitForExistence(timeout: 15))
        language.click()
        app.menuItems.matching(NSPredicate(format: "title == %@", "Portuguese (Brazil)")).firstMatch.click()
        let install = app.buttons["settings.speechModel.pt_BR-faber-medium.install"]
        XCTAssertTrue(install.waitForExistence(timeout: 20))
        install.click()
        XCTAssertTrue(app.sheets.buttons["Cancel"].firstMatch.waitForExistence(timeout: 5))
        app.sheets.buttons["Cancel"].firstMatch.click()
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.path))
        install.click()
        app.sheets.buttons["Confirm installation"].firstMatch.click()
        let cancel = app.buttons["settings.speechModel.pt_BR-faber-medium.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        cancel.click()
        XCTAssertTrue(install.waitForExistence(timeout: 30))
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.appendingPathComponent("model.onnx").path))
        attach(app, name: "13-model-download-cancelled")
        install.click()
        app.sheets.buttons["Confirm installation"].firstMatch.click()
        let preview = app.buttons["settings.speechModel.pt_BR-faber-medium.preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 180), app.debugDescription)
        XCTAssertEqual(try Data(contentsOf: model.appendingPathComponent("model.onnx")),
                       try Data(contentsOf: retained.appendingPathComponent("model.onnx")))
        attach(app, name: "14-faber-installed-through-real-ui")
        preview.click()
        XCTAssertTrue(app.staticTexts["Sample finished"].waitForExistence(timeout: 30))
        attach(app, name: "15-newly-installed-faber-audition")
    }

    private func acceptanceApplication() throws -> (XCUIApplication, URL, URL) {
        let env = ProcessInfo.processInfo.environment
        guard let supplied = env["MAC_AUDIOBOOK_ACCEPTANCE_ROOT"], supplied.hasPrefix("/"),
              let data = env["MAC_AUDIOBOOK_APP_DATA"], data.hasSuffix("/Library/Containers/com.pietrocode.epubtomp3.acceptance/Data") else {
            throw XCTSkip("Requires explicitly prepared isolated application data and Faber")
        }
        let root = URL(fileURLWithPath: supplied)
        let appURL = root.appendingPathComponent("acceptance-app/EpubToMp3.app")
        guard Bundle(url: appURL)?.bundleIdentifier == "com.pietrocode.epubtomp3.acceptance" else {
            throw XCTSkip("The application must use the dedicated acceptance bundle identity")
        }
        let app = XCUIApplication(url: appURL)
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        return (app, root, URL(fileURLWithPath: data))
    }

    private func startManualConversion(_ app: XCUIApplication) {
        app.buttons["bookDetail.convert"].click()
        app.dialogs.buttons["Convert"].firstMatch.click()
    }

    private func waitForCompletedJob(_ root: URL, excluding prior: Set<String>) throws -> URL {
        var completed: URL?
        try waitUntil(seconds: 120) {
            completed = self.jobDirectories(root).subtracting(prior).map { URL(fileURLWithPath: $0) }.first {
                self.completedAudio(in: $0).count == 2 &&
                ((try? String(contentsOf: $0.appendingPathComponent("conversion.log"), encoding: .utf8))?.contains("[Rust] conversion finished") == true)
            }
            return completed != nil
        }
        return try XCTUnwrap(completed)
    }

    private func waitUntil(seconds: TimeInterval, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("The real application did not reach the expected state")
                throw NSError(domain: "MacAudiobookJourney", code: 1)
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private func paste(_ text: String, into element: XCUIElement) {
        let board = NSPasteboard.general
        if savedClipboard == nil {
            savedClipboard = (board.pasteboardItems ?? []).map { item in
                Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                    item.data(forType: type).map { (type, $0) }
                })
            }
        }
        board.clearContents()
        board.setString(text, forType: .string)
        ownedClipboardChange = board.changeCount
        element.click()
        element.typeKey("a", modifierFlags: .command)
        element.typeKey("v", modifierFlags: .command)
    }

    private func dismissOwnedCrashNotice() {
        let notice = XCUIApplication(bundleIdentifier: "com.apple.UserNotificationCenter")
        guard notice.state != .notRunning else { return }
        let text = notice.staticTexts.allElementsBoundByIndex.map {
            $0.label + " " + (($0.value as? String) ?? "")
        }.joined(separator: " ")
        guard text.contains("EpubToMp3") else { return }
        let ignore = notice.buttons.matching(NSPredicate(format: "title IN %@", ["Ignorar", "Ignore"])).firstMatch
        if ignore.exists { ignore.click() }
    }

    private func jobDirectories(_ root: URL) -> Set<String> {
        let urls = (try? FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: nil)) ?? []
        return Set(urls.filter { UUID(uuidString: $0.lastPathComponent) != nil }.map(\.path))
    }

    private func completedAudio(in root: URL) -> [URL] {
        guard let iterator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: nil) else { return [] }
        return iterator.compactMap { item -> URL? in
            guard let url = item as? URL, url.lastPathComponent.hasSuffix(".mp3.complete.json") else { return nil }
            return url.deletingLastPathComponent().appendingPathComponent(
                String(url.lastPathComponent.dropLast(".complete.json".count)))
        }
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private extension URL {
    func withExtension(_ value: String) -> URL {
        deletingPathExtension().appendingPathExtension(value)
    }
}
