import Foundation

enum ContinuationChoice: Equatable, Sendable {
    case reader
    case audio
}

enum ContinuationResolution: Equatable, Sendable {
    case offer([ContinuationChoice])
    case start(ContinuationPosition)
    case startDefault
}

enum ContinuationPosition: Equatable, Sendable {
    case reader(ReaderAudioPositionAnchor)
    case audio(ReaderAudioPositionAnchor)
}

enum ContinuationChoiceResolver {
    static func resolve(
        reader: ReaderAudioPositionAnchor?,
        audio: ReaderAudioPositionAnchor?
    ) -> ContinuationResolution {
        switch (reader?.isMeaningful == true, audio?.isMeaningful == true) {
        case (true, true): return .offer([.reader, .audio])
        case (true, false): return .start(.reader(reader!))
        case (false, true): return .start(.audio(audio!))
        case (false, false): return .startDefault
        }
    }
}
