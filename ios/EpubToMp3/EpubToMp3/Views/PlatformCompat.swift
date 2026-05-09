import SwiftUI

/// Cross-platform shims so the same view source compiles for iOS, iPadOS,
/// and macOS. The Mac SDK doesn't expose `navigationBarTitleDisplayMode`,
/// `fullScreenCover`, `.topBarTrailing`, or `Color(.systemBackground)` —
/// those are all UIKit-flavoured APIs. macOS gets the closest no-op /
/// AppKit equivalent.
extension View {
    /// No-op on macOS; honoured on iOS / iPadOS.
    @ViewBuilder
    func compatInlineNavigationTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// `fullScreenCover` doesn't exist on macOS — fall back to a regular
    /// sheet, which on a Mac window is the right modal presentation
    /// anyway (full-screen covers are a phone metaphor).
    @ViewBuilder
    func compatFullScreenCover<Content: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        #if os(iOS)
        self.fullScreenCover(isPresented: isPresented, content: content)
        #else
        self.sheet(isPresented: isPresented, content: content)
        #endif
    }
}

extension ToolbarItemPlacement {
    /// `.topBarTrailing` is iOS-only. On macOS, `.primaryAction` puts the
    /// item on the trailing side of the window toolbar, which matches the
    /// intent.
    static var compatPrimaryTrailing: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }
}

/// True when SwiftUI is rendering inside the Xcode preview canvas.
/// Xcode sets `XCODE_RUNNING_FOR_PREVIEWS=1` in the injected dylib's
/// environment. Use this to short-circuit network calls and bookmark
/// resolution that would crash or hang in the preview sandbox.
var isSwiftUIPreview: Bool {
    ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
}

extension Color {
    /// `Color(.systemBackground)` is UIKit-only. On macOS we fall back to
    /// the AppKit `windowBackgroundColor`. On iOS it round-trips to the
    /// real UIKit token.
    static var platformSystemBackground: Color {
        #if canImport(UIKit)
        Color(.systemBackground)
        #elseif canImport(AppKit)
        Color(NSColor.windowBackgroundColor)
        #else
        Color(.white)
        #endif
    }
}
