import Foundation
import CoreGraphics
import SwiftUI

/// The two reflow representations share the same inline-image contract.
enum EpubInlineImageRepresentation: Equatable {
    case paginated
    case scrolling
}

struct EpubInlineImageSource: Equatable {
    let identifier: String
    let pixelSize: CGSize

    init(identifier: String, pixelSize: CGSize) {
        self.identifier = identifier
        self.pixelSize = pixelSize
    }
}

struct EpubInlineImageLayout: Equatable {
    let sourceIdentifier: String
    let displaySize: CGSize
    let representation: EpubInlineImageRepresentation
}

/// Calculates a width-constrained, aspect-preserving image frame.
struct EpubInlineImageRenderer {
    let maxWidth: CGFloat

    init(maxWidth: CGFloat) {
        self.maxWidth = max(0, maxWidth)
    }

    func layout(
        _ source: EpubInlineImageSource,
        representation: EpubInlineImageRepresentation
    ) -> EpubInlineImageLayout {
        let sourceWidth = max(source.pixelSize.width, 1)
        let sourceHeight = max(source.pixelSize.height, 0)
        let width = min(maxWidth, sourceWidth)
        let height = width * sourceHeight / sourceWidth
        return EpubInlineImageLayout(
            sourceIdentifier: source.identifier,
            displaySize: CGSize(width: width, height: height),
            representation: representation
        )
    }
}

enum EpubImageZoomPresentation: Equatable {
    case none
    case zoomed(sourceIdentifier: String)
}

/// Presentation state is deliberately independent of SwiftUI sheets so a host
/// can choose a sheet, full-screen cover, or an in-tree viewer.
final class EpubImageZoomModel {
    private(set) var presentation: EpubImageZoomPresentation = .none

    func tap(_ source: EpubInlineImageSource) {
        presentation = .zoomed(sourceIdentifier: source.identifier)
    }

    func dismiss() {
        presentation = .none
    }
}

struct EpubInlineImageView: View {
    let image: Image
    let source: EpubInlineImageSource
    let representation: EpubInlineImageRepresentation
    let maxWidth: CGFloat
    let onZoom: (EpubInlineImageSource) -> Void

    var body: some View {
        let layout = EpubInlineImageRenderer(maxWidth: maxWidth).layout(source, representation: representation)
        image
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: layout.displaySize.width, height: layout.displaySize.height)
            .contentShape(Rectangle())
            .onTapGesture { onZoom(source) }
    }
}

enum EpubFontChoice: Equatable {
    case book
    case georgia
    case system
    case custom(family: String)

    var displayName: String {
        switch self {
        case .book: return L10n.string("readerSettings.font.book")
        case .georgia: return "Georgia"
        case .system: return "SF"
        case .custom(let family): return family
        }
    }

    /// Used by a font picker preview; nil means the EPUB's own family.
    var previewFamilyName: String? {
        switch self {
        case .book: return nil
        case .georgia: return "Georgia"
        case .system: return ".SFUI-Regular"
        case .custom(let family): return family
        }
    }
}

struct EpubTextTraits: OptionSet, Equatable {
    let rawValue: Int
    static let bold = Self(rawValue: 1 << 0)
    static let italic = Self(rawValue: 1 << 1)
    static let heading = Self(rawValue: 1 << 2)
    static let underline = Self(rawValue: 1 << 3)
    static let link = Self(rawValue: 1 << 4)
}

struct EpubResolvedFont: Equatable {
    let family: String
    let pointSize: CGFloat
    let traits: EpubTextTraits
}

/// Family replacement changes only the family. EPUB semantic traits remain
/// attached to each attributed run, including headings and links.
enum EpubFontResolver {
    static func resolve(
        family: EpubFontChoice,
        size: CGFloat,
        preserving traits: EpubTextTraits
    ) -> EpubResolvedFont {
        EpubResolvedFont(
            family: family.previewFamilyName ?? "EPUB book family",
            pointSize: size,
            traits: traits
        )
    }
}

enum EpubFontRegistrationSource: Equatable {
    case bundled
    case custom
}

struct EpubFontRegistrationMetadata: Equatable {
    let resourceName: String
    let fileExtension: String
    let source: EpubFontRegistrationSource

    var registrationKey: String {
        "\(source == .bundled ? "bundled" : "custom"):\(resourceName).\(fileExtension.lowercased())"
    }
}

enum EpubTypographyAlignment: Equatable {
    case left
    case justified
}

struct EpubTypographySettings: Equatable {
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    let margins: CGFloat
    let alignment: EpubTypographyAlignment
}

enum EpubReaderDocumentKind {
    case epub
    case pdf
}

enum EpubTypographyControl: CaseIterable {
    case fontChoice
    case fontSize
    case lineSpacing
    case margins
    case alignment
}

struct EpubReaderSettingsPolicy {
    let documentKind: EpubReaderDocumentKind

    var preservesOriginalLayout: Bool { documentKind == .pdf }

    func allows(_ control: EpubTypographyControl) -> Bool {
        documentKind == .epub
    }
}

/// Pure state machine for a reader font pinch. The view can feed its
/// `MagnificationGesture` values here and apply `commitIfSettled` from its
/// existing debounce task without coupling this contract to SwiftUI.
struct EpubFontPinchController: Equatable {
    let minimumSize: CGFloat
    let maximumSize: CGFloat
    let debounce: TimeInterval
    private(set) var committedSize: CGFloat

    private var gestureBaseSize: CGFloat
    private var pendingSize: CGFloat?
    private var lastUpdateAt: Date?

    init(
        initialSize: CGFloat,
        minimumSize: CGFloat = 14,
        maximumSize: CGFloat = 28,
        debounce: TimeInterval = 0.25
    ) {
        let lower = min(minimumSize, maximumSize)
        let upper = max(minimumSize, maximumSize)
        self.minimumSize = lower
        self.maximumSize = upper
        self.debounce = max(0, debounce)
        let clampedInitial = min(max(initialSize, lower), upper)
        self.committedSize = clampedInitial
        self.gestureBaseSize = clampedInitial
    }

    mutating func begin(at _: Date) {
        gestureBaseSize = committedSize
        pendingSize = nil
        lastUpdateAt = nil
    }

    @discardableResult
    mutating func update(scale: CGFloat, at date: Date) -> CGFloat {
        let safeScale = max(scale, 0)
        let next = min(max(gestureBaseSize * safeScale, minimumSize), maximumSize)
        pendingSize = next
        lastUpdateAt = date
        return next
    }

    @discardableResult
    mutating func commitIfSettled(at date: Date) -> CGFloat? {
        guard let pendingSize, let lastUpdateAt,
              date.timeIntervalSince(lastUpdateAt) >= debounce else { return nil }
        committedSize = pendingSize
        self.pendingSize = nil
        self.lastUpdateAt = nil
        return committedSize
    }
}
