import Foundation

/// Words the Play choice shown when the reader and the audio are in different places.
/// It names both places; a page the client has not laid out is left out, never guessed.
struct ResumeChoiceCopy: Equatable {
    struct ReaderPlace {
        let chapterIndex: Int
        let page: Int?
    }

    struct AudioPlace {
        let chapterIndex: Int
        let page: Int?
        let seconds: TimeInterval
    }

    let message: String
    let listenTitle: String
    let returnTitle: String

    init(reader: ReaderPlace, audio: AudioPlace?,
         localize: (String, [CVarArg]) -> String = { String(format: L10n.string($0), arguments: $1) }) {
        let readerChapter = reader.chapterIndex + 1
        var sentences = [reader.page.map { localize("player.divergence.readerPage", [$0, readerChapter]) }
            ?? localize("player.divergence.readerChapter", [readerChapter])]
        listenTitle = reader.page.map { localize("player.divergence.listenPage", [$0]) }
            ?? localize("player.divergence.listen", [])
        if let audio {
            let chapter = audio.chapterIndex + 1
            let time = PlayerTransportPresentation.formatTime(audio.seconds)
            sentences.append(audio.page.map { localize("player.divergence.audioPage", [$0, chapter, time]) }
                ?? localize("player.divergence.audioChapter", [chapter, time]))
            returnTitle = audio.page.map { localize("player.divergence.returnPage", [$0, chapter]) }
                ?? localize("player.divergence.returnChapter", [chapter])
        } else {
            returnTitle = localize("player.divergence.return", [])
        }
        message = sentences.joined(separator: " ")
    }
}

/// Page numbers of the open reader. Both are nil where the reader shows no pages
/// or has not laid out the narrated chapter.
struct ReaderPageSource {
    let current: @MainActor () -> Int?
    let narrated: @MainActor (ReaderPlaybackLocation) -> Int?
}

extension AudioPlayer {
    func resumeChoiceCopy(readerChapterIndex: Int) -> ResumeChoiceCopy {
        ResumeChoiceCopy(
            reader: .init(chapterIndex: readerChapterIndex, page: readerPages?.current()),
            audio: ReaderPlaybackLocation(player: self).map {
                .init(chapterIndex: $0.chapterIndex, page: readerPages?.narrated($0), seconds: $0.seconds)
            }
        )
    }
}
