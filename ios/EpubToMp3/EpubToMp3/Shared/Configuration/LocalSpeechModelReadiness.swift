import Foundation

enum LocalSpeechModelReadiness {
    static func ttsModelsRoot(fileManager: FileManager = .default, create: Bool = true) -> URL? {
        try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: create
        ).appendingPathComponent("EpubToMp3/TTSModels", isDirectory: true)
    }
}
