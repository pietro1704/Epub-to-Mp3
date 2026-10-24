import Foundation

// Reader source-coordinate projection stays outside the Foundation conversion facade.
extension RustConversionCoordinator {
    @MainActor
    static func executeStreaming(
        bookURL: URL,
        jobID: String,
        chapterStart: Int32,
        chapterEnd: Int32,
        control: ConverterPlaybackControl,
        options: ConversionOptions? = nil,
        onProgress: (@MainActor @Sendable (ConversionProgressEvent) -> Void)?,
        onChapterCompleted: (@MainActor @Sendable (ChapterCompletionEvent) -> Void)?,
        onAudioChunk: (@Sendable (Int, Int, Data) -> Bool)?
    ) async throws -> Result {
        let coordinator = RustConversionCoordinator()
        // Manual conversion uses the Rust structure directly; streaming is
        // requested by a reader/book surface and uses its persisted chapter axis.
        guard bookURL.pathExtension.lowercased() == "epub", chapterStart >= 0 else {
            return try await coordinator.convert(
                bookURL: bookURL, jobID: jobID, chapterStart: chapterStart, chapterEnd: chapterEnd,
                options: options, playbackControl: control, onProgress: onProgress,
                onChapterCompleted: onChapterCompleted, onAudioChunk: onAudioChunk
            )
        }
        let chapterMap = try await Task.detached(priority: .userInitiated) {
            let bookID = try BookContentIdentity.hash(of: bookURL)
            let reader = LocalFulltextCache.read(bookId: bookID)
                ?? EpubFallbackParser.parse(url: bookURL, bookId: bookID)
            let metadata = try ConverterFFIAdapter().openBook(at: bookURL).metadataJSON
            return try ReaderConversionChapterMap(reader: reader, metadata: metadata)
        }.value
        try Task.checkCancellation()
        let coreStart = try chapterMap.corePosition(for: Int(chapterStart))
        let coreEnd = chapterEnd < 0 ? -1 : try chapterMap.corePosition(for: Int(chapterEnd))
        control.installReaderChapterMap(chapterMap)
        let projectedAudio: (@Sendable (Int, Int, Data) -> Bool)?
        if let callback = onAudioChunk {
            projectedAudio = { coreIndex, chunkIndex, data in
                guard let readerIndex = try? chapterMap.readerPosition(for: coreIndex) else { return false }
                return callback(readerIndex, chunkIndex, data)
            }
        } else { projectedAudio = nil }
        let result = try await coordinator.convert(
            bookURL: bookURL,
            jobID: jobID,
            chapterStart: Int32(coreStart),
            chapterEnd: Int32(coreEnd),
            options: options,
            playbackControl: control,
            onProgress: { event in onProgress?(event) },
            onChapterCompleted: { event in onChapterCompleted?(event) },
            onAudioChunk: projectedAudio,
            readerChapterMap: chapterMap
        )
        let projected = try chapterMap.manifest(result.manifestJSON)
        return Result(jobID: result.jobID, manifestJSON: projected, outputDirectory: result.outputDirectory)
    }

}
