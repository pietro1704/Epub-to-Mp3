import Foundation

/// Stable persisted requests; availability belongs to the current OS process.
enum ReaderFontFamily: String, CaseIterable, Identifiable {
    case serif, sans, mono
    case original, athelas, avenirNext, canela, charter, georgia, iowan, palatino
    case proximaNova, publico, sanFrancisco, newYork, seravek, timesNewRoman

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .serif: return L10n.string("font.serif")
        case .sans: return L10n.string("font.sans")
        case .mono: return L10n.string("font.mono")
        case .original: return L10n.string("readerSettings.font.book")
        case .athelas: return "Athelas"
        case .avenirNext: return "Avenir Next"
        case .canela: return "Canela"
        case .charter: return "Charter"
        case .georgia: return "Georgia"
        case .iowan: return "Iowan"
        case .palatino: return "Palatino"
        case .proximaNova: return "Proxima Nova"
        case .publico: return "Publico"
        case .sanFrancisco: return "San Francisco"
        case .newYork: return "New York"
        case .seravek: return "Seravek"
        case .timesNewRoman: return "Times New Roman"
        }
    }

    var namedFamily: String? {
        switch self {
        case .serif, .timesNewRoman: return "Times New Roman"
        case .sans: return "Helvetica Neue"
        case .mono: return "Menlo"
        case .original, .sanFrancisco, .newYork: return nil
        case .iowan: return "Iowan Old Style"
        case .publico: return "Publico Text"
        default: return displayName
        }
    }

    func isAvailable(in families: Set<String>) -> Bool {
        guard let namedFamily else { return true }
        return families.contains(namedFamily)
    }
}
