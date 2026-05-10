import Foundation
import Observation
import SwiftUI

/// Reader appearance choices surfaced in `ReaderView`'s toolbar.
enum ReaderFontFamily: String, CaseIterable, Identifiable {
    case serif
    case sans
    case mono

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .serif: return "Serif"
        case .sans:  return "Sans"
        case .mono:  return "Mono"
        }
    }
}

enum ReaderTheme: String, CaseIterable, Identifiable {
    case light
    case sepia
    case parchment
    case paper
    case dark
    case black
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .light:     return "Light"
        case .sepia:     return "Sepia"
        case .parchment: return "Parchment"
        case .paper:     return "Paper"
        case .dark:      return "Dark"
        case .black:     return "Black"
        case .custom:    return "Custom"
        }
    }
}

enum ReaderLayout: String, CaseIterable, Identifiable {
    case scrolling
    case paginated

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .scrolling: return "Scrolling"
        case .paginated: return "Paginated"
        }
    }
}

/// Persisted user preferences. The backend URL drives every API call so the
/// user can flip between localhost (dev), a tunnelled HF Spaces deploy, or
/// any reachable server hosting the Python backend.
@Observable
final class AppSettings {
    @ObservationIgnored
    @AppStorage("backendURL") private var storedBackendURL: String = "http://localhost:8000"

    /// 5-step font size scale: 0=XS, 1=S, 2=M (default), 3=L, 4=XL.
    @ObservationIgnored
    @AppStorage("readerFontSize") private var storedReaderFontSize: Int = 2

    @ObservationIgnored
    @AppStorage("readerFontFamily") private var storedReaderFontFamily: String = ReaderFontFamily.serif.rawValue

    @ObservationIgnored
    @AppStorage("readerTheme") private var storedReaderTheme: String = ReaderTheme.light.rawValue

    @ObservationIgnored
    @AppStorage("readerAutoScroll") private var storedReaderAutoScroll: Bool = true

    @ObservationIgnored
    @AppStorage("readerLayout") private var storedReaderLayout: String = ReaderLayout.scrolling.rawValue

    /// Line spacing in points. 0 = system default (~1.2 line-height).
    /// Range exposed to the UI: 0…16.
    @ObservationIgnored
    @AppStorage("readerLineSpacing") private var storedReaderLineSpacing: Double = 6

    /// Horizontal text margin inside the reading column (px).
    @ObservationIgnored
    @AppStorage("readerMargin") private var storedReaderMargin: Double = 24

    /// Maximum reading column width. Controls how wide a line gets on
    /// large windows; iPad/Mac users typically want narrower columns.
    @ObservationIgnored
    @AppStorage("readerColumnWidth") private var storedReaderColumnWidth: Double = 720

    /// Custom theme — packed RGB values stored as comma-separated
    /// "r,g,b,r,g,b" (background then foreground). Doubles 0…1.
    @ObservationIgnored
    @AppStorage("readerCustomColors") private var storedReaderCustomColors: String = "1,1,1,0,0,0"

    @ObservationIgnored
    @AppStorage("useEmbeddedSidecar") private var storedUseEmbeddedSidecar: Bool = true

    /// Filled in by `SidecarManager` once the bundled Python server is
    /// healthy. When non-nil and `useEmbeddedSidecar == true`, all API
    /// calls go to this URL instead of the user-typed `backendURL`. Not
    /// persisted — the port is recomputed on each app launch.
    var sidecarURL: URL? = nil

    var backendURL: String {
        get { storedBackendURL }
        set { storedBackendURL = newValue }
    }

    /// Whether to prefer the embedded sidecar over the user-configured
    /// backend URL. macOS-only switch (iOS / iPadOS always use
    /// `backendURL` since they cannot embed a Python process).
    var useEmbeddedSidecar: Bool {
        get { storedUseEmbeddedSidecar }
        set { storedUseEmbeddedSidecar = newValue }
    }

    var readerFontSize: Int {
        get { max(0, min(4, storedReaderFontSize)) }
        set { storedReaderFontSize = max(0, min(4, newValue)) }
    }

    var readerFontFamily: ReaderFontFamily {
        get { ReaderFontFamily(rawValue: storedReaderFontFamily) ?? .serif }
        set { storedReaderFontFamily = newValue.rawValue }
    }

    var readerTheme: ReaderTheme {
        get { ReaderTheme(rawValue: storedReaderTheme) ?? .light }
        set { storedReaderTheme = newValue.rawValue }
    }

    var readerAutoScroll: Bool {
        get { storedReaderAutoScroll }
        set { storedReaderAutoScroll = newValue }
    }

    var readerLayout: ReaderLayout {
        get { ReaderLayout(rawValue: storedReaderLayout) ?? .scrolling }
        set { storedReaderLayout = newValue.rawValue }
    }

    var readerLineSpacing: Double {
        get { max(0, min(16, storedReaderLineSpacing)) }
        set { storedReaderLineSpacing = max(0, min(16, newValue)) }
    }

    var readerMargin: Double {
        get { max(8, min(80, storedReaderMargin)) }
        set { storedReaderMargin = max(8, min(80, newValue)) }
    }

    var readerColumnWidth: Double {
        get { max(420, min(960, storedReaderColumnWidth)) }
        set { storedReaderColumnWidth = max(420, min(960, newValue)) }
    }

    /// Decoded (background, foreground) RGB tuple — six doubles in
    /// 0…1, defaults to white-on-black if the stored string is bad.
    var readerCustomColors: (background: (Double, Double, Double),
                              foreground: (Double, Double, Double)) {
        get {
            let parts = storedReaderCustomColors
                .split(separator: ",")
                .compactMap { Double($0) }
            guard parts.count == 6 else {
                return ((1, 1, 1), (0, 0, 0))
            }
            return ((parts[0], parts[1], parts[2]),
                    (parts[3], parts[4], parts[5]))
        }
        set {
            let v = [newValue.background.0, newValue.background.1, newValue.background.2,
                     newValue.foreground.0, newValue.foreground.1, newValue.foreground.2]
            storedReaderCustomColors = v.map { String(format: "%.4f", $0) }.joined(separator: ",")
        }
    }

    /// Best-effort parsed URL — returns nil if the user typed garbage so the
    /// caller can surface a validation error instead of silently failing.
    /// On macOS, when `useEmbeddedSidecar` is on and the sidecar has come
    /// up healthy, the sidecar URL wins so the app stays self-contained
    /// even if the user once pointed `backendURL` at HF Spaces.
    var resolvedBaseURL: URL? {
        if useEmbeddedSidecar, let sidecarURL { return sidecarURL }
        let trimmed = backendURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed)
    }

    /// Resolved point size for the current font-size step.
    var readerPointSize: CGFloat {
        switch readerFontSize {
        case 0: return 14
        case 1: return 17
        case 2: return 20
        case 3: return 24
        case 4: return 28
        default: return 20
        }
    }
}
