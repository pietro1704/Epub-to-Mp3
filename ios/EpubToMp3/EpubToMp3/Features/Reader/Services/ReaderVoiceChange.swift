import Foundation

/// The voice picker can present the active job's voice independently of Settings.
struct ReaderVoicePicker {
    let selection: TtsSelection
    var resolvedTitle: String? = nil
    let onChange: @MainActor (TtsSelection) -> Void

    func marks(_ choice: TtsSelection) -> Bool {
        if SpeechModelLibraryViewState.sameChoice(selection, choice) { return true }
        // A resolved platform voice can be named without the catalogue model ID.
        return selection.engine == choice.engine && selection.modelID == nil && !selection.isPiper
            && selection.voice != nil && selection.voice == choice.voice
    }

    struct Choice {
        let selection: TtsSelection
        let title: String
        let selected: Bool
        let available: Bool
    }

    func choices(from catalog: SpeechModelLibraryViewState) -> [Choice] {
        var choices = catalog.primaryNarrationChoices.map {
            Choice(selection: $0.selection, title: $0.title, selected: marks($0.selection), available: true)
        }
        if !choices.contains(where: \.selected) {
            choices.insert(.init(selection: selection, title: resolvedTitle ?? catalog.displayName(for: selection),
                selected: true, available: false), at: 0)
        }
        return choices
    }

    @MainActor
    func choose(_ choice: TtsSelection) {
        guard !marks(choice) else { return }
        onChange(choice)
    }
}

@MainActor
struct ReaderVoiceChange {
    let chapter: Int
    let pageRatio: Double?
    let seek: PendingPlaybackSeek.ChapterRequest?
    let autoplay: Bool
    var sourceScalarOffset: Int? = nil

    static func capture(player: AudioPlayer, book: BookEntity,
                        starting: Self?, ownedJobID: String?,
                        pdfPosition: (chapter: Int, offset: Int)? = nil) -> Self? {
        guard book.fileType.supportsAudioConversion else { return nil }
        if let starting { return starting }
        guard let snapshot = player.snapshot,
              belongsToBook(player: player, snapshot: snapshot, book: book, ownedJobID: ownedJobID),
              player.isPlaying || player.hasPendingAutoplay || player.isConverting
                || player.hasPausedPlaybackToResume else { return nil }
        let autoplay = player.isPlaying || player.hasPendingAutoplay
        // The PDF clock is relative to the selected source suffix. Carry that
        // suffix's exact origin alongside the time within it.
        func pdfOffset(at chapter: Int) -> Int? {
            guard book.fileType == .pdf else { return nil }
            return pdfPosition.flatMap { $0.chapter == chapter ? $0.offset : nil }
                ?? player.currentPlaybackChapter.flatMap { $0.index == chapter ? $0.textOffset : nil }
        }
        if let navigation = player.pendingNavigation,
           let request = player.pendingListeningSeek(for: navigation) {
            switch navigation.target {
            case .readerPage(let ratio), .approximateTime(let ratio):
                return .init(chapter: navigation.chapterIndex, pageRatio: ratio, seek: nil, autoplay: request.autoplay)
            case .chapterTime:
                return .init(chapter: navigation.chapterIndex, pageRatio: nil, seek: request, autoplay: request.autoplay,
                    sourceScalarOffset: pdfOffset(at: navigation.chapterIndex))
            }
        }
        guard let chapter = player.activeStreamingChapterIndex ?? player.currentPlaybackChapter?.index else { return nil }
        if book.fileType != .pdf,
           let source = LocalFulltextCache.inMemoryPayload(bookId: book.id)?
            .chapters.first(where: { $0.zeroBasedEpubIndex == chapter }),
           let ratio = textAnchor(in: source, position: player.playbackClock.audioOutput.position,
                                  activeSentence: player.activeSentenceId) {
            return .init(chapter: chapter, pageRatio: ratio, seek: nil, autoplay: autoplay)
        }
        // No sentence timing (an engine without it, or a position still before its first sentence): the chapter
        // clock still maps to the text through the same time-to-text ratio that feeds the slider. Carrying seconds
        // would replay the OLD voice's time on a voice of another speed, which can lie beyond what the new job has
        // generated and leaves the player waiting for it.
        if book.fileType != .pdf, let ratio = timeAnchor(position: player.playbackClock.audioOutput.position, chapter: chapter) {
            return .init(chapter: chapter, pageRatio: ratio, seek: nil, autoplay: autoplay)
        }
        return chapterTime(player: player, chapter: chapter, jobID: snapshot.jobId, autoplay: autoplay,
            sourceScalarOffset: pdfOffset(at: chapter))
    }

    /// Fraction of the chapter already spoken, from the confirmed audio position; `nil` when unknown.
    static func timeAnchor(position: PlaybackAudioOutput.Position?, chapter: Int) -> Double? {
        guard let position, position.chapterIndex == chapter, position.seconds.isFinite, position.seconds >= 0,
              position.duration.isFinite, position.duration > 0 else { return nil }
        return min(1, position.seconds / position.duration)
    }

    private static func chapterTime(player: AudioPlayer, chapter: Int, jobID: String, autoplay: Bool,
                                    sourceScalarOffset: Int? = nil) -> Self {
        let seconds = player.positionSeconds
        let seek = PendingPlaybackSeek.ChapterRequest(id: UUID(), jobID: jobID,
            chapterIndex: chapter, autoplay: autoplay, position: seconds.isFinite ? max(0, seconds) : 0)
        return .init(chapter: chapter, pageRatio: nil, seek: seek, autoplay: autoplay,
            sourceScalarOffset: sourceScalarOffset)
    }

    static func textAnchor(in chapter: EbookFulltext.Chapter, position: PlaybackAudioOutput.Position?,
                           activeSentence: String?) -> Double? {
        let position = position.flatMap { $0.chapterIndex == chapter.zeroBasedEpubIndex ? $0 : nil }
        if let position, let word = position.alignment?.spokenWord(at: position.itemSeconds),
           let range = ReaderSpokenTextResolver.word(word.word, passage: word.passage,
               chapterText: chapter.text, renderedText: chapter.text),
           let ratio = sourceRatio(chapter.text, range: range) {
            return ratio
        }

        guard let sentenceID = position?.sentenceID ?? activeSentence else { return nil }
        let sync = SyncEngine()
        sync.load(chapter: chapter, chapterDurationSeconds: position?.duration ?? 0)
        guard let id = sync.readerSentenceID(forTimingID: sentenceID),
              let sentence = sync.spans.first(where: { $0.id == id }) else { return nil }
        let tokens = sentence.text.split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return nil }
        let pattern = tokens.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s+")
        let matches = (try? NSRegularExpression(pattern: pattern))?.matches(in: chapter.text,
            range: NSRange(chapter.text.startIndex..., in: chapter.text)) ?? []
        guard matches.count == 1, let match = matches.first else { return nil }
        return sourceRatio(chapter.text, range: match.range)
    }

    static func sourceRatio(_ text: String, range: NSRange) -> Double? {
        // The Rust start offset is measured in Unicode scalar values. Reader
        // sentence offsets use graphemes and the speech resolver uses UTF-16.
        guard let range = Range(range, in: text), !text.isEmpty else { return nil }
        return Double(text[..<range.lowerBound].unicodeScalars.count) / Double(text.unicodeScalars.count)
    }

    private static func belongsToBook(player: AudioPlayer, snapshot: JobSnapshot,
                                      book: BookEntity, ownedJobID: String?) -> Bool {
        if let ownedJobID { return snapshot.jobId == ownedJobID }
        return snapshot.jobId == book.lastJobId || player.isPlaybackForReaderBook(book.id)
    }

    static func activeVoiceTitle(player: AudioPlayer, book: BookEntity, ownedJobID: String?) -> String? {
        guard let snapshot = player.snapshot,
              belongsToBook(player: player, snapshot: snapshot, book: book, ownedJobID: ownedJobID) else { return nil }
        return snapshot.activeVoiceDisplayName
    }

    static func selection(player: AudioPlayer, book: BookEntity, ownedJobID: String?,
                          requested: TtsSelection?, configured: TtsSelection) -> TtsSelection {
        guard let snapshot = player.snapshot,
              belongsToBook(player: player, snapshot: snapshot, book: book, ownedJobID: ownedJobID),
              let engine = snapshot.engine else { return requested ?? configured }
        guard TtsSelection.selectableEngines.contains(engine) else { return requested ?? configured }
        if engine == TtsSelection.piperEngine, let modelID = snapshot.voice,
           !modelID.contains(" + ") {
            if let requested, requested.engine == engine, requested.modelID == modelID { return requested }
            return .init(engine: engine, modelID: modelID, voice: nil)
        }
        if let voice = snapshot.voice, !voice.contains(" + ") {
            let identifier: String
            if voice.hasSuffix(")"), let start = voice.range(of: " (", options: .backwards) {
                identifier = String(voice[start.upperBound..<voice.index(before: voice.endIndex)])
            } else { identifier = voice }
            if let requested, requested.engine == engine, requested.voice == identifier { return requested }
            if !identifier.isEmpty, identifier != engine { return .engineDefault(engine, voice: identifier) }
        }
        if let requested, requested.engine == engine { return requested }
        return .engineDefault(engine)
    }
}
