#if os(iOS)
import UIKit

enum ReaderTapAction: Equatable {
    case toggleChrome
    case turnPage(forward: Bool)
    case scrollScreen(forward: Bool)
    case none

    static func resolve(point: CGPoint, in bounds: CGRect, isPaginated: Bool,
                        scrollsScreenOnEdgeTap: Bool = false) -> ReaderTapAction {
        guard bounds.contains(point) else { return .none }
        // Reader controls use the familiar three vertical zones: a middle
        // column toggles chrome anywhere along the readable page, while the
        // left and right columns turn pages in paginated mode. Depending on
        // y made a tap in the visual middle near the top or bottom turn pages
        // unexpectedly.
        let middleColumn = bounds.insetBy(dx: bounds.width / 3, dy: 0)
        if middleColumn.contains(point) {
            return .toggleChrome
        }
        if isPaginated { return .turnPage(forward: point.x >= bounds.midX) }
        // A paginated chapter that fell back to scrolling (a fragment taller than a page) still answers the edge
        // columns: a screen of scrolling takes the place of the page turn instead of silently doing nothing.
        return scrollsScreenOnEdgeTap ? .scrollScreen(forward: point.x >= bounds.midX) : .none
    }
}

enum ReaderLoadingLayoutMetrics {
    static let coverAspectRatio: CGFloat = 1.5
    static let preferredCoverWidthFraction: CGFloat = 0.42
    static let maximumCoverWidthFraction: CGFloat = 0.60
    static let maximumCoverHeightFraction: CGFloat = 0.42
    static let minimumVerticalMargin: CGFloat = 24
    static let preferredTopSpacing: CGFloat = 48
}

struct ReaderViewportConfiguration: Equatable {
    let allowsVerticalScrolling: Bool
    let allowsChapterSwipes: Bool
    let usesPaginatedTextHeight: Bool
    let showsPageIndicator: Bool
    let usesScreenEdges: Bool

    static func resolve(
        layout: ReaderLayout,
        chromeHidden: Bool,
        showsPageNumbers: Bool
    ) -> ReaderViewportConfiguration {
        let paginated = layout == .paginated
        return ReaderViewportConfiguration(
            allowsVerticalScrolling: !paginated,
            allowsChapterSwipes: !paginated,
            usesPaginatedTextHeight: paginated,
            // The indicator owns a reserved strip below the text, so it stays when the chrome hides.
            showsPageIndicator: paginated && showsPageNumbers,
            // Immersive mode removes reader chrome, not the system safe
            // area. Keeping text inside it prevents content from extending
            // under the status bar or home indicator during a reflow.
            usesScreenEdges: false
        )
    }
}

enum ReaderTextViewFactory {
    /// The reader intentionally uses NSLayoutManager for pagination, glyph
    /// positions, and page-boundary calculations. Build it with TextKit 1 so
    /// those accesses do not force UIKit to switch a TextKit 2 view at runtime.
    static func make() -> UITextView {
        let storage = NSTextStorage()
        let layoutManager = ReaderPlaybackLayoutManager()
        let textContainer = NSTextContainer(size: .zero)
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        return ReaderSelectionTextView(frame: .zero, textContainer: textContainer)
    }
}

#endif
