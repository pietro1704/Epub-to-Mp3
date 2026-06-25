import CoreGraphics

/// Pure layout arithmetic for the paginated reader, extracted so the
/// safe-area / column-inset / corridor math is unit-testable without
/// standing up SwiftUI or a device. The page controller pins its text
/// view to the RAW view edges and uses these insets, because a
/// UIKit child controller hosted under SwiftUI cannot trust its own
/// `safeAreaLayoutGuide` (the host frequently zeroes it) — so the safe
/// area is folded into the corridor here from SwiftUI's known values.
enum ReaderLayoutMath {

    /// Symmetric horizontal inset that brackets the (possibly narrower)
    /// column within the container. On a phone the column fills
    /// `width - 2*margin` so this is just `margin`; on a wide iPad it
    /// centres the column. Never returns less than `margin`.
    static func sideInset(containerWidth: CGFloat, columnWidth: CGFloat, margin: CGFloat) -> CGFloat {
        max(margin, (containerWidth - columnWidth) / 2)
    }

    /// Top corridor: the safe-area top (status bar / notch) PLUS the host's
    /// top chrome PLUS a breathing pad, minus any compaction applied when
    /// chrome is hidden. Clamped at 0 so it can never push text upward.
    static func topCorridor(safeAreaTop: CGFloat, chromeTop: CGFloat, pad: CGFloat, hiddenCompaction: CGFloat) -> CGFloat {
        max(0, safeAreaTop + chromeTop + pad - hiddenCompaction)
    }

    /// Bottom corridor: the safe-area bottom (home indicator) PLUS the
    /// host's bottom chrome PLUS the page-number footer strip PLUS a pad.
    static func bottomCorridor(safeAreaBottom: CGFloat, chromeBottom: CGFloat, footer: CGFloat, pad: CGFloat) -> CGFloat {
        max(0, safeAreaBottom + chromeBottom + footer + pad)
    }
}
