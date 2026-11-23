import XCTest
@testable import EpubToMp3

@MainActor
final class ModelsByLanguageModelTests: XCTestCase {
    final class FakeSource: ModelsByLanguageSource, @unchecked Sendable {
        private let lock = NSLock()
        private var installed: Set<String> = ["pt_BR-faber-medium"]
        private(set) var installs: [(model: String, fingerprint: String?, language: String)] = []
        private(set) var cancelled: [String] = []
        private var continuations: [String: AsyncStream<SpeechModelInstallEvent>.Continuation] = [:]
        var requiresTerms = false
        var installError: Error?
        var installDelayNanoseconds: UInt64 = 0

        func catalogLanguages() async throws -> [CatalogLanguage] {
            [CatalogLanguage(tag: "pt", modelCount: 2), CatalogLanguage(tag: "en", modelCount: 1)]
        }

        func snapshot(language: String) async throws -> SpeechModelSnapshot {
            try await snapshot(language: language, includeLow: false)
        }

        /// Languages asked for with the install browser (the only catalogue that lists Piper Low voices).
        private(set) var includeLowRequests: [String] = []
        private(set) var explicitInstalls: [String] = []
        private(set) var explicitRemovals: [String] = []
        static let lowID = "pt_BR-edresson-low"

        func snapshot(language: String, includeLow: Bool) async throws -> SpeechModelSnapshot {
            var ids = language == "pt" ? ["pt_BR-faber-medium", "pt_BR-cadu-medium"] : ["en_US-ljspeech-high"]
            if includeLow {
                lock.lock(); includeLowRequests.append(language); lock.unlock()
                if language == "pt" { ids.append(Self.lowID) }
            }
            let entries = ids.map { id in
                lock.lock(); defer { lock.unlock() }
                return Self.entry(id: id, installed: installed.contains(id), requiresTerms: requiresTerms && id == "pt_BR-cadu-medium",
                                  tag: language, quality: id == Self.lowID ? .low : .medium)
            }
            let document: [String: Any] = [
                "schema_version": 3, "generated_from_catalog_revision": "fixture", "target": ["language": language],
                "entries": [], "default_selection": ["version": 2, "provider": "piper", "runtime": "piper",
                    "model_id": NSNull(), "model_revision": NSNull(), "voice": NSNull(), "options": [:]],
            ]
            let base = try SpeechModelSnapshot.decode(JSONSerialization.data(withJSONObject: document))
            return SpeechModelSnapshot(schemaVersion: base.schemaVersion,
                                       generatedFromCatalogRevision: base.generatedFromCatalogRevision,
                                       defaultSelection: base.defaultSelection, target: base.target, entries: entries)
        }

        func install(modelID: String, acceptedTermsFingerprint: String?, language: String, explicitLow: Bool) async throws {
            if explicitLow { lock.lock(); explicitInstalls.append(modelID); lock.unlock() }
            try await install(modelID: modelID, acceptedTermsFingerprint: acceptedTermsFingerprint, language: language)
        }

        func remove(modelID: String, configuredSelections: [TtsSelection], explicitLowLanguage: String?) async throws {
            if explicitLowLanguage != nil { lock.lock(); explicitRemovals.append(modelID); lock.unlock() }
            try await remove(modelID: modelID, configuredSelections: configuredSelections)
        }

        func explicitSelection(for entry: SpeechModelSnapshot.Entry, language: String) async throws -> TtsSelection {
            TtsSelection(engine: "piper", modelID: entry.identity.modelID, voice: nil,
                         session: TtsSessionSelection(provider: "piper", runtime: "piper", modelID: entry.identity.modelID,
                                                      modelRevision: entry.identity.modelRevision, voice: nil))
        }

        func install(modelID: String, acceptedTermsFingerprint: String?, language: String) async throws {
            lock.lock(); installs.append((modelID, acceptedTermsFingerprint, language)); lock.unlock()
            if installDelayNanoseconds > 0 { try await Task.sleep(nanoseconds: installDelayNanoseconds) }
            if let installError { throw installError }
        }

        func watchInstall(modelID: String) async -> AsyncStream<SpeechModelInstallEvent> {
            AsyncStream { continuation in
                lock.lock(); continuations[modelID] = continuation; lock.unlock()
            }
        }

        func cancelInstall(modelID: String) async { lock.lock(); cancelled.append(modelID); lock.unlock() }

        private(set) var removals: [(model: String, configured: [TtsSelection])] = []
        func remove(modelID: String, configuredSelections: [TtsSelection]) async throws {
            lock.lock(); defer { lock.unlock() }
            removals.append((modelID, configuredSelections))
            if configuredSelections.contains(where: { $0.modelID == modelID }) {
                throw SpeechModelRemovalError.configured(modelID)
            }
            installed.remove(modelID)
        }

        func auditionChoice(for entry: SpeechModelSnapshot.Entry) async throws -> (selection: TtsSelection, language: String) {
            (TtsSelection(engine: "piper", modelID: entry.identity.modelID, voice: nil), "pt")
        }

        func emit(_ modelID: String, _ stage: SpeechModelInstallEvent.Stage, done: UInt64 = 0, total: UInt64 = 100,
                  markInstalled: Bool = false) {
            lock.lock()
            if markInstalled { installed.insert(modelID) }
            let continuation = continuations[modelID]
            lock.unlock()
            continuation?.yield(SpeechModelInstallEvent(sequence: 1, operationID: "op", modelID: modelID, stage: stage,
                                                        artifactIndex: nil, bytesCompleted: done, bytesTotal: total, failure: nil))
        }

        static func entry(id: String, installed: Bool, requiresTerms: Bool, tag: String,
                          quality: SpeechModelSnapshot.Quality = .medium) -> SpeechModelSnapshot.Entry {
            .init(identity: .init(provider: "piper", runtime: "piper", modelID: id, modelRevision: "fixture"),
                  presentation: .init(modelName: id, familyName: "Piper", quality: quality, voiceChoices: []),
                  languageEvidence: .init(routingTags: [tag], exactTags: []),
                  distribution: .init(installable: true, downloadBytes: 100, installedBytes: nil),
                  licence: .init(id: nil, category: "unknown", evidenceURL: nil,
                                 termsFingerprint: requiresTerms ? "fp1" : nil, requiresAcceptance: requiresTerms,
                                 validation: "unknown"),
                  compatibility: .init(compatible: true, reasons: []),
                  installation: .init(state: installed ? .installed : .missing, verifiedRevision: nil, installedBytes: nil),
                  readiness: .init(state: installed ? .ready : .notInspected, activeRuntimeRevision: nil, failure: nil),
                  selection: .init(selectable: installed, reasons: []))
        }
    }

    private func make(_ source: FakeSource) throws -> (ModelsByLanguageModel, AppSettings, UserDefaults, String) {
        let name = "models-model-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let settings = AppSettings(defaults: defaults)
        let terms = SpeechModelTermsAcceptanceStore(defaults: defaults)
        return (ModelsByLanguageModel(source: source, settings: settings, terms: terms, systemVoiceLanguages: { [] }),
                settings, defaults, name)
    }

    private func settle() async { for _ in 0..<20 { await Task.yield() } }

    func testLoadBuildsOneSectionPerCatalogLanguage() async throws {
        let (model, _, defaults, name) = try make(FakeSource())
        defer { defaults.removePersistentDomain(forName: name) }
        await model.load()
        XCTAssertEqual(model.state.sections.map(\.language), ["pt", "en"])
        XCTAssertNil(model.loadFailure)
    }

    func testOnlyAReadyRowCanBeChosenAndTheChoiceIsPersisted() async throws {
        let (model, settings, defaults, name) = try make(FakeSource())
        defer { defaults.removePersistentDomain(forName: name) }
        await model.load()
        let pt = model.state.sections[0]
        let faber = try XCTUnwrap(pt.rows.first { $0.id == "piper:pt_BR-faber-medium" })
        let cadu = try XCTUnwrap(pt.rows.first { $0.id == "piper:pt_BR-cadu-medium" })
        XCTAssertFalse(model.choose(cadu, in: "pt"), "A dimmed row is downloaded first, never selected silently.")
        XCTAssertTrue(settings.languageModelChoices.isEmpty)
        XCTAssertTrue(model.choose(faber, in: "pt-BR"))
        XCTAssertEqual(settings.languageModelChoices["pt"]?.modelID, "pt_BR-faber-medium")
        await settle()
        XCTAssertEqual(model.state.sections[0].chosen?.id, faber.id, "The screen follows the stored choice.")
        model.clearChoice(in: "pt")
        await settle()
        XCTAssertNil(model.state.sections[0].chosen)
    }

    func testTappingADimmedRowDownloadsItAndItBecomesSelectable() async throws {
        let source = FakeSource()
        let (model, _, defaults, name) = try make(source)
        defer { defaults.removePersistentDomain(forName: name) }
        await model.load()
        let cadu = try XCTUnwrap(model.state.sections[0].rows.first { $0.id == "piper:pt_BR-cadu-medium" })
        XCTAssertTrue(cadu.isDimmed)
        await model.download(cadu, in: "pt")
        XCTAssertEqual(source.installs.map(\.model), ["pt_BR-cadu-medium"])
        XCTAssertEqual(model.progress[cadu.id], 0)
        source.emit("pt_BR-cadu-medium", .downloading, done: 40)
        await settle()
        XCTAssertEqual(model.progress[cadu.id] ?? -1, 0.4, accuracy: 0.001)
        await model.download(cadu, in: "pt")
        XCTAssertEqual(source.installs.count, 1, "A second tap while downloading is ignored.")
        source.emit("pt_BR-cadu-medium", .completed, done: 100, markInstalled: true)
        await settle()
        XCTAssertNil(model.progress[cadu.id])
        let refreshed = try XCTUnwrap(model.state.sections[0].rows.first { $0.id == cadu.id })
        XCTAssertEqual(refreshed.availability, .ready)
        XCTAssertTrue(model.choose(refreshed, in: "pt"))
    }

    func testReadyRowsAreNeverDownloaded() async throws {
        let source = FakeSource()
        let (model, _, defaults, name) = try make(source)
        defer { defaults.removePersistentDomain(forName: name) }
        await model.load()
        let faber = try XCTUnwrap(model.state.sections[0].rows.first { $0.id == "piper:pt_BR-faber-medium" })
        await model.download(faber, in: "pt")
        XCTAssertTrue(source.installs.isEmpty)
    }

    func testALicenceMustBeAcceptedBeforeTheDownloadStarts() async throws {
        let source = FakeSource()
        source.requiresTerms = true
        let (model, _, defaults, name) = try make(source)
        defer { defaults.removePersistentDomain(forName: name) }
        await model.load()
        let cadu = try XCTUnwrap(model.state.sections[0].rows.first { $0.id == "piper:pt_BR-cadu-medium" })
        await model.download(cadu, in: "pt")
        XCTAssertTrue(source.installs.isEmpty)
        XCTAssertEqual(model.pendingTerms?.fingerprint, "fp1")
        model.declinePendingTerms()
        XCTAssertNil(model.pendingTerms)
        XCTAssertTrue(source.installs.isEmpty)
        await model.download(cadu, in: "pt")
        await model.acceptPendingTerms()
        XCTAssertEqual(source.installs.first?.fingerprint, "fp1")
    }

    func testAFailedInstallShowsAMessageAndKeepsTheRowDownloadable() async throws {
        let source = FakeSource()
        source.installError = SpeechModelInstallationError.transport("offline")
        let (model, _, defaults, name) = try make(source)
        defer { defaults.removePersistentDomain(forName: name) }
        await model.load()
        let cadu = try XCTUnwrap(model.state.sections[0].rows.first { $0.id == "piper:pt_BR-cadu-medium" })
        await model.download(cadu, in: "pt")
        XCTAssertEqual(model.failures[cadu.id], L10n.string("settings.modelInstall.downloadFailed"))
        XCTAssertNil(model.progress[cadu.id])
        XCTAssertTrue(model.state.sections[0].rows.first { $0.id == cadu.id }?.isDimmed ?? false)
    }

    func testRemovalRefreshesTheLanguageAndRefusesAChosenModel() async throws {
        let source = FakeSource()
        let (model, settings, defaults, name) = try make(source)
        defer { defaults.removePersistentDomain(forName: name) }
        await model.load()
        let faber = try XCTUnwrap(model.state.sections[0].rows.first { $0.id == "piper:pt_BR-faber-medium" })
        XCTAssertTrue(model.choose(faber, in: "pt"))
        do {
            try await model.remove(faber, in: "pt")
            XCTFail("A model chosen for a language must keep its files.")
        } catch let error as SpeechModelRemovalError {
            XCTAssertEqual(error, .configured("pt_BR-faber-medium"))
        }
        XCTAssertTrue(source.removals.last?.configured.contains { $0.modelID == "pt_BR-faber-medium" } ?? false)
        model.clearChoice(in: "pt")
        settings.selectPrimaryNarration(.systemDefault)
        await settle()
        try await model.remove(faber, in: "pt")
        let refreshed = try XCTUnwrap(model.state.sections[0].rows.first { $0.id == faber.id })
        XCTAssertEqual(refreshed.availability, .downloadable(bytes: 100), "Removed: dimmed and downloadable again.")
    }

    func testTermsCanBeRevokedAndPreviewResolvesAChoice() async throws {
        let source = FakeSource()
        source.requiresTerms = true
        let (model, _, defaults, name) = try make(source)
        defer { defaults.removePersistentDomain(forName: name) }
        await model.load()
        let cadu = try XCTUnwrap(model.state.sections[0].rows.first { $0.id == "piper:pt_BR-cadu-medium" })
        let entry = try XCTUnwrap(model.entry(forRow: cadu, in: "pt"))
        XCTAssertFalse(model.isTermsAccepted(for: entry))
        await model.download(cadu, in: "pt")
        await model.acceptPendingTerms()
        XCTAssertTrue(model.isTermsAccepted(for: entry))
        model.revokeTerms(for: entry)
        XCTAssertFalse(model.isTermsAccepted(for: entry))
        let preview = try await model.auditionChoice(for: cadu, in: "pt")
        XCTAssertEqual(preview.selection.modelID, "pt_BR-cadu-medium")
    }

    func testNarrationSettingsLiveOnTheModelsScreen() async throws {
        let (model, settings, defaults, name) = try make(FakeSource())
        defer { defaults.removePersistentDomain(forName: name) }
        await model.load()
        // Default voice and reserve choices: ready models of every language, the system voice and Edge.
        let titles = model.narrationChoices.map(\.title)
        XCTAssertTrue(titles.contains("pt_BR-faber-medium") && titles.contains(L10n.string("settings.systemTts")))
        XCTAssertFalse(titles.contains("pt_BR-cadu-medium"), "A model that is not downloaded is not offered as the default voice.")
        model.selectPrimary(.systemDefault)
        XCTAssertEqual(settings.primaryTtsSelection, .systemDefault)
        XCTAssertFalse(model.secondaryChoices.contains { $0.selection.engine == "edge" }, "Edge needs the online consent")
        model.allowOnlineFallback = true
        XCTAssertTrue(settings.allowOnlineAudioFallback)
        XCTAssertTrue(model.secondaryChoices.contains { $0.selection.engine == "edge" })
        model.selectSecondary(.edgeDefault)
        XCTAssertEqual(settings.secondaryTtsSelection, .edgeDefault)
        model.selectSecondary(nil)
        XCTAssertNil(settings.secondaryTtsSelection)
        model.allowAutomaticSystemVoiceFallback = false
        XCTAssertFalse(settings.allowAutomaticSystemVoiceFallback)
        XCTAssertEqual(model.title(for: TtsSelection(engine: "piper", modelID: "pt_BR-faber-medium", voice: nil)), "pt_BR-faber-medium")
    }

    func testTheBooksLanguageComesFirstSoTheScreenOpensOnIt() async throws {
        let (model, _, defaults, name) = try make(FakeSource())
        defer { defaults.removePersistentDomain(forName: name) }
        model.priorityLanguage = "en-US"
        await model.load()
        XCTAssertEqual(model.state.sections.map(\.language), ["en", "pt"], "English first although Portuguese has the installed model")
        model.priorityLanguage = nil
        XCTAssertEqual(model.state.sections.map(\.language), ["pt", "en"])
    }

    func testASlowDownloadNeverBlocksTheMainActor() async throws {
        let source = FakeSource()
        source.installDelayNanoseconds = 400_000_000
        let (model, _, defaults, name) = try make(source)
        defer { defaults.removePersistentDomain(forName: name) }
        await model.load()
        let cadu = try XCTUnwrap(model.state.sections[0].rows.first { $0.id == "piper:pt_BR-cadu-medium" })
        var ticks = 0
        let timer = Timer(timeInterval: 0.02, repeats: true) { _ in MainActor.assumeIsolated { ticks += 1 } }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        await model.download(cadu, in: "pt")
        XCTAssertGreaterThan(ticks, 5, "The main actor kept running while the download was in flight")
        XCTAssertEqual(source.installs.map(\.model), ["pt_BR-cadu-medium"])
    }

    // MARK: Piper Low voices (explicit-only)

    private func lowRow(_ model: ModelsByLanguageModel) -> ModelsByLanguageViewState.Row? {
        model.state.sections.first { $0.language == "pt" }?.rows.first { $0.selection.modelID == FakeSource.lowID }
    }

    func testLowVoicesAreHiddenByDefaultAndTheInstallBrowserIsNotLoaded() async throws {
        let source = FakeSource()
        let (model, _, defaults, name) = try make(source)
        defer { defaults.removePersistentDomain(forName: name) }
        await model.load()
        XCTAssertFalse(model.showLowQuality)
        XCTAssertNil(lowRow(model), "Low voices are never listed until the listener asks")
        XCTAssertTrue(source.includeLowRequests.isEmpty)
    }

    func testShowingLowVoicesListsThemLastAndNeverAsADefaultOrReserveVoice() async throws {
        let source = FakeSource()
        let (model, _, defaults, name) = try make(source)
        defer { defaults.removePersistentDomain(forName: name) }
        await model.load()
        await model.setShowLowQuality(true)
        XCTAssertEqual(Set(source.includeLowRequests), ["pt", "en"])
        let low = try XCTUnwrap(lowRow(model))
        XCTAssertTrue(low.isExplicitOnly)
        XCTAssertEqual(low.detail, "low")
        guard case .downloadable = low.availability else { return XCTFail("Not downloaded: dimmed and downloadable") }
        XCTAssertEqual(model.state.sections.first { $0.language == "pt" }?.local.last?.selection.modelID, FakeSource.lowID,
                       "Low is ranked after the other voices")
        XCTAssertFalse(model.narrationChoices.contains { $0.selection.modelID == FakeSource.lowID })
        await model.setShowLowQuality(false)
        XCTAssertNil(lowRow(model), "Hiding the filter hides the voice again")
    }

    func testRevealingInstallingAndChoosingALowVoiceAreSeparateExplicitSteps() async throws {
        let source = FakeSource()
        let (model, settings, defaults, name) = try make(source)
        defer { defaults.removePersistentDomain(forName: name) }
        await model.load()
        await model.setShowLowQuality(true)
        var low = try XCTUnwrap(lowRow(model))
        // Showing it did not install or choose anything.
        XCTAssertTrue(source.installs.isEmpty)
        XCTAssertTrue(settings.languageModelChoices.isEmpty)
        await model.download(low, in: "pt")
        XCTAssertEqual(source.explicitInstalls, [FakeSource.lowID], "Low installs through the install browser")
        source.emit(FakeSource.lowID, .completed, markInstalled: true)
        await settle()
        low = try XCTUnwrap(lowRow(model))
        XCTAssertEqual(low.availability, .ready)
        // Installing did not choose it, and the plain choice never saves a bare Low voice.
        XCTAssertTrue(settings.languageModelChoices.isEmpty)
        XCTAssertFalse(model.choose(low, in: "pt"))
        XCTAssertTrue(settings.languageModelChoices.isEmpty)
        let chosen = await model.chooseExplicit(low, in: "pt")
        XCTAssertTrue(chosen)
        let saved = try XCTUnwrap(settings.languageModelChoices["pt"])
        XCTAssertEqual(saved.modelID, FakeSource.lowID)
        XCTAssertEqual(saved.session?.modelRevision, "fixture", "The explicit choice pins the catalogue revision")
        await settle()
        XCTAssertTrue(try XCTUnwrap(lowRow(model)).isChosen)
    }

    func testHidingTheFilterKeepsAnExplicitLowChoiceVisibleAndActive() async throws {
        let source = FakeSource()
        let (model, settings, defaults, name) = try make(source)
        defer { defaults.removePersistentDomain(forName: name) }
        await model.load()
        await model.setShowLowQuality(true)
        await model.download(try XCTUnwrap(lowRow(model)), in: "pt")
        source.emit(FakeSource.lowID, .completed, markInstalled: true)
        await settle()
        _ = await model.chooseExplicit(try XCTUnwrap(lowRow(model)), in: "pt")
        await model.setShowLowQuality(false)
        let kept = try XCTUnwrap(lowRow(model), "The chosen Low voice stays listed")
        XCTAssertTrue(kept.isChosen)
        // A new screen with the filter off (the default) loads the install browser for that language only.
        let again = ModelsByLanguageModel(source: source, settings: settings,
                                          terms: SpeechModelTermsAcceptanceStore(defaults: defaults), systemVoiceLanguages: { [] })
        let before = source.includeLowRequests.count
        await again.load()
        XCTAssertTrue(try XCTUnwrap(lowRow(again)).isChosen)
        XCTAssertEqual(Array(source.includeLowRequests.dropFirst(before)), ["pt"])
        // Clearing the choice hides it again while the filter is off.
        again.clearChoice(in: "pt")
        await again.load()
        XCTAssertNil(lowRow(again))
    }

    func testRemovingAnInstalledLowVoiceUsesTheInstallBrowser() async throws {
        let source = FakeSource()
        let (model, _, defaults, name) = try make(source)
        defer { defaults.removePersistentDomain(forName: name) }
        await model.load()
        await model.setShowLowQuality(true)
        await model.download(try XCTUnwrap(lowRow(model)), in: "pt")
        source.emit(FakeSource.lowID, .completed, markInstalled: true)
        await settle()
        try await model.remove(try XCTUnwrap(lowRow(model)), in: "pt")
        XCTAssertEqual(source.explicitRemovals, [FakeSource.lowID])
        guard case .downloadable = try XCTUnwrap(lowRow(model)).availability else { return XCTFail("Removed: downloadable again") }
    }
}
