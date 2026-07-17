import Foundation
import NaturalLanguage

/// Pure-function voice selection based on NLLanguageRecognizer.
/// Extracted from `BookOpenView` to enable unit testing.
enum VoiceSelector {

    /// Returns the best Edge-TTS voice identifier for the given text sample.
    static func edgeVoice(for text: String, declaredLanguage: String? = nil) -> String {
        if let declaredLanguage {
            let root = declaredLanguage.lowercased().split(separator: "-").first.map(String.init)
            if root == "en" { return "en-US-AriaNeural" }
            if root == "pt" { return "pt-BR-FranciscaNeural" }
            if root == "es" { return "es-MX-DaliaNeural" }
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return voiceName(for: recognizer.dominantLanguage)
    }

    /// Maps a detected `NLLanguage` to an Edge-TTS voice name.
    static func voiceName(for language: NLLanguage?) -> String {
        switch language {
        case .portuguese:            return "pt-BR-FranciscaNeural"
        case .spanish:               return "es-MX-DaliaNeural"
        case .french:                return "fr-FR-DeniseNeural"
        case .german:                return "de-DE-KatjaNeural"
        case .italian:               return "it-IT-ElsaNeural"
        case .japanese:              return "ja-JP-NanamiNeural"
        case .korean:                return "ko-KR-SunHiNeural"
        case .simplifiedChinese:     return "zh-CN-XiaoxiaoNeural"
        case .traditionalChinese:    return "zh-TW-HsiaoChenNeural"
        default:                     return "en-US-AriaNeural"
        }
    }
}
