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
    case dark
    case black

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .light: return "Light"
        case .sepia: return "Sepia"
        case .dark:  return "Dark"
        case .black: return "Black"
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
