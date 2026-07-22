import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

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

    /// Hide the system back affordance on iOS so in-reader horizontal
    /// swipes remain page-turn gestures and book dismissal is only the
    /// explicit in-book X button. No-op on macOS.
    @ViewBuilder
    func compatReaderBackButtonHidden() -> some View {
        #if os(iOS)
        self.navigationBarBackButtonHidden(true)
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
}

/// `ViewThatFits` requires iOS 16 / macOS 13. We support iOS 15 / macOS 12,
/// so legacy OSes get the preferred horizontal layout only — the Dynamic
/// Type XXXL fallback that motivates the wrapper only matters on newer
/// systems which already have the API.
@ViewBuilder
func CompatViewThatFitsHV<Horizontal: View, Vertical: View>(
    @ViewBuilder horizontal: () -> Horizontal,
    @ViewBuilder vertical: () -> Vertical
) -> some View {
    if #available(iOS 16.0, macOS 13.0, *) {
        ViewThatFits(in: .horizontal) {
            horizontal()
            vertical()
        }
    } else {
        horizontal()
    }
}

extension View {
}

extension View {

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
                case .escape: key = .escape
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
    case leftArrow, rightArrow, pageUp, pageDown, space, home, end, escape, j, k
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
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }
}

extension View {
    /// HIG-aligned horizontal padding for content that needs to live
    /// inside the safe area on every device. Adds the system-default
    /// content margin (16pt iPhone, 20pt iPad/macOS) on top of any
    /// existing safe area inset coming from the notch or Dynamic
    /// Island in landscape orientation.
    ///
    /// Use this on bars/strips that draw a background full-width
    /// (`.thinMaterial`, etc.) so the *content* inside the bar still
    /// stays clear of the notch — the background can extend behind
    /// the notch (that's the iOS HIG pattern) but the controls inside
    /// must not.
    ///
    /// iOS 17+ ships `safeAreaPadding(_:)` which composes with the
    /// existing safe area; on iOS 15-16 / macOS 12 we fall back to
    /// the auto-applied default which, while less precise, still
    /// avoids the cropped-by-notch failure mode because SwiftUI
    /// applies an implicit safe-area inset to root content. The
    /// 16pt baseline padding compounds correctly in both paths.
    @ViewBuilder
    func compatHorizontalSafeAreaPadding(_ amount: CGFloat = 16) -> some View {
        if #available(iOS 17, macOS 14, *) {
            self.safeAreaPadding(.horizontal, amount)
        } else {
            self.padding(.horizontal, amount)
        }
    }

    /// Vertical-axis analogue of `compatHorizontalSafeAreaPadding`. Use
    /// this on floating elements or full-bleed content that must stay
    /// clear of the notch / Dynamic Island at the top and the home
    /// indicator at the bottom in **portrait** orientation.
    ///
    /// Why this exists: SwiftUI's automatic safe-area handling is
    /// reliable for first-party chrome (NavigationStack toolbar, tab
    /// bar) but anything we draw ourselves inside a `ZStack` with
    /// `.ignoresSafeArea`, or inside a non-NavigationStack root, will
    /// silently bleed into the home indicator on iPhone X-and-later
    /// devices. The portrait failure mode is much worse than the
    /// landscape one because the home indicator is ~34pt tall and
    /// users actively swipe through it.
    ///
    /// iOS 17+ uses `safeAreaPadding(.vertical, _:)` which composes
    /// with the system inset. iOS 15-16 falls back to plain padding
    /// applied **on top of** the system safe area — the parent view
    /// must already be inside the safe area for this to compose
    /// correctly. Pair with `.safeAreaInset(edge: .bottom)` on the
    /// container if you are docking a floating bar.
    @ViewBuilder
    func compatVerticalSafeAreaPadding(_ amount: CGFloat = 8) -> some View {
        if #available(iOS 17, macOS 14, *) {
            self.safeAreaPadding(.vertical, amount)
        } else {
            self.padding(.vertical, amount)
        }
    }
}

#if canImport(UIKit)
private typealias PlatformImage = UIImage
#else
private typealias PlatformImage = NSImage
#endif

/// Process-wide NSCache for decoded book covers. `platformImage(from:)`
/// used to re-decode the PNG bytes on EVERY SwiftUI body evaluation
/// (FullPlayerSheet, MiniPlayerBar, LibraryView grid, …). For a
/// library of 50 books × 100-500 KB cover PNGs that's a measurable
/// main-thread hog during scroll (Instruments captured 5-15 ms per
/// decode on iPhone SE). Cache keyed on `Data.hashValue` so different
/// books' covers don't collide — cheap to compute, stable across
/// process lifetime.
private enum _CoverImageCache {
    nonisolated(unsafe) static let cache: NSCache<NSNumber, PlatformImage> = {
        let c = NSCache<NSNumber, PlatformImage>()
        // ~64 covers × ~2 MB decoded ≈ 128 MB ceiling. NSCache
        // evicts under memory pressure automatically.
        c.countLimit = 64
        return c
    }()
}

func platformImage(from data: Data) -> Image? {
    let key = NSNumber(value: data.hashValue)
    if let cached = _CoverImageCache.cache.object(forKey: key) {
        #if canImport(UIKit)
        return Image(uiImage: cached)
        #else
        return Image(nsImage: cached)
        #endif
    }
    #if canImport(UIKit)
    guard let ui = UIImage(data: data) else { return nil }
    _CoverImageCache.cache.setObject(ui, forKey: key)
    return Image(uiImage: ui)
    #else
    guard let ns = NSImage(data: data) else { return nil }
    _CoverImageCache.cache.setObject(ns, forKey: key)
    return Image(nsImage: ns)
    #endif
}

struct HideFocusRingModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, iOS 17.0, *) {
            content.focusEffectDisabled()
        } else {
            content
        }
    }
}

