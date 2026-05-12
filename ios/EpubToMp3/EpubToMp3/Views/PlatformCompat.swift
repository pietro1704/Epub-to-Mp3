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

    /// `presentationDetents` was introduced in iOS 16 / macOS 13. On
    /// earlier OSes the sheet renders at the system default size.
    @ViewBuilder
    func compatPresentationDetents() -> some View {
        if #available(iOS 16, macOS 13, *) {
            self.presentationDetents([.medium, .large])
        } else {
            self
        }
    }

    /// `onKeyPress` requires iOS 17 / macOS 14. We expose a generic
    /// shim so callers don't have to gate the call site. On older
    /// OSes the modifier becomes a no-op.
    @ViewBuilder
    func compatOnKeyPressArrowsAndPaging(
        _ handler: @escaping (CompatKey) -> Bool
    ) -> some View {
        if #available(iOS 17, macOS 14, *) {
            self.onKeyPress { press in
                let key: CompatKey?
                switch press.key {
                case .leftArrow: key = .leftArrow
                case .rightArrow: key = .rightArrow
                case .pageUp: key = .pageUp
                case .pageDown: key = .pageDown
                case .space: key = .space
                case .home: key = .home
                case .end: key = .end
                default:
                    if press.characters == "k" { key = .k }
                    else if press.characters == "j" { key = .j }
                    else { key = nil }
                }
                guard let key else { return .ignored }
                return handler(key) ? .handled : .ignored
            }
        } else {
            self
        }
    }
}

/// OS-agnostic key enum used by the `compatOnKeyPressArrowsAndPaging`
/// shim. Keeps call sites free of `KeyPress` (iOS 17+) imports.
enum CompatKey {
    case leftArrow, rightArrow, pageUp, pageDown, space, home, end, j, k
}

extension View {
    /// `onChange(of:) { oldValue, newValue in }` requires iOS 17 /
    /// macOS 14. The single-argument legacy form is iOS 14 / macOS
    /// 11 friendly. This shim picks the modern signature when
    /// available and falls back to the legacy one — the modern path
    /// stays free of the deprecation warning.
    @ViewBuilder
    func compatOnChange<V: Equatable>(
        of value: V, action: @escaping (V) -> Void
    ) -> some View {
        if #available(iOS 17, macOS 14, *) {
            self.onChange(of: value) { _, newValue in
                action(newValue)
            }
        } else {
            self.onChange(of: value, perform: action)
        }
    }

    /// `focusable()` (no-arg) requires iOS 17. On iOS 15-16 we drop
    /// the modifier entirely — paginated mode's `.focused` binding
    /// still works (it claims focus on appear), and arrow-key paging
    /// is iOS-17-only anyway via `compatOnKeyPressArrowsAndPaging`,
    /// so iOS 15 users page via swipe / tap.
    @ViewBuilder
    func compatFocusable() -> some View {
        if #available(iOS 17, macOS 12, *) {
            self.focusable()
        } else {
            self
        }
    }
}

/// `LabeledContent` is iOS 16 / macOS 13. On Big Sur / iOS 15 we
/// render the same layout manually as `HStack { Label · Spacer ·
/// Trailing }` — the visual is indistinguishable in the inset-grouped
/// `Form` rows where every call site lives. Two constructors mirror
/// the original (string convenience + view-builder content).
struct CompatLabeledContent<Label: View, Content: View>: View {
    let label: Label
    let content: Content

    init(
        @ViewBuilder content: () -> Content,
        @ViewBuilder label: () -> Label
    ) {
        self.label = label()
        self.content = content()
    }

    var body: some View {
        if #available(iOS 16, macOS 13, *) {
            LabeledContent {
                content
            } label: {
                label
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                label
                Spacer(minLength: 8)
                content
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}

extension CompatLabeledContent where Label == Text, Content == Text {
    init(_ title: String, value: String) {
        self.label = Text(title)
        self.content = Text(value)
    }
}

extension CompatLabeledContent where Label == Text {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.label = Text(title)
        self.content = content()
    }
}

/// `NavigationStack` is iOS 16 / macOS 13. On older OSes we drop
/// back to `NavigationView` with the stack style so the visual
/// behaviour stays "push from the right" — `.navigationDestination`
/// modifiers are gated separately at the call sites where they live.
struct CompatNavigationStack<Root: View>: View {
    @ViewBuilder let root: () -> Root
    var body: some View {
        if #available(iOS 16, macOS 13, *) {
            NavigationStack { root() }
        } else {
            NavigationView { root() }
                #if os(iOS)
                .navigationViewStyle(.stack)
                #endif
        }
    }
}

/// `ContentUnavailableView` arrived in iOS 17 / macOS 14. On older
/// OSes we render an equivalent VStack with the same three pieces:
/// title, SF Symbol, optional description. Same call-site API.
struct CompatContentUnavailableView: View {
    let title: String
    let systemImage: String
    let description: Text?

    init(_ title: String, systemImage: String, description: Text? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
    }

    var body: some View {
        if #available(iOS 17, macOS 14, *) {
            if let description {
                ContentUnavailableView(title, systemImage: systemImage, description: description)
            } else {
                ContentUnavailableView(title, systemImage: systemImage)
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.title3.weight(.semibold))
                if let description {
                    description
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
///
/// Xcode 26 unified the preview pipeline with Playgrounds and now
/// sets `XCODE_RUNNING_FOR_PLAYGROUNDS=1` in the injected dylib's
/// environment (the older `XCODE_RUNNING_FOR_PREVIEWS` is gone). We
/// check both so the same code keeps working on Xcode 15/16.
///
/// Use this to short-circuit network calls and bookmark resolution
/// that would crash or hang in the preview sandbox.
var isSwiftUIPreview: Bool {
    let env = ProcessInfo.processInfo.environment
    return env["XCODE_RUNNING_FOR_PLAYGROUNDS"] == "1"
        || env["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
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
