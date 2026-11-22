import SwiftUI
import WidgetKit

extension View {
    @ViewBuilder
    func homeWidgetBackground() -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            containerBackground(.fill.tertiary, for: .widget)
        } else {
#if os(iOS)
            background(Color(uiColor: .secondarySystemBackground))
#elseif os(macOS)
            background(Color(nsColor: .windowBackgroundColor))
#endif
        }
    }
}

func formatWidgetTime(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
    if m > 0 { return "\(m)m" }
    return "\(s)s"
}

// MARK: - Cross-platform UIImage/NSImage shim

#if canImport(UIKit)
import UIKit
private typealias WidgetCoverImage = UIImage
extension Image {
    init(platformImage img: UIImage) { self.init(uiImage: img) }
}
#elseif canImport(AppKit)
import AppKit
private typealias WidgetCoverImage = NSImage
extension Image {
    init(platformImage img: NSImage) { self.init(nsImage: img) }
}
#endif

// MARK: - Deep-link URL helpers

enum WidgetDeepLinks {
    static func open(bookId: String?) -> URL {
        guard let id = bookId else { return URL(string: "epubtomp3://library")! }
        return URL(string: "epubtomp3://open?bookId=\(id)")!
    }

    static func player(bookId: String?) -> URL {
        guard let id = bookId else { return URL(string: "epubtomp3://library")! }
        return URL(string: "epubtomp3://player?bookId=\(id)")!
    }

}

// MARK: - Cover image helper

@ViewBuilder
func coverImage(from data: Data?, size: CGFloat = 28) -> some View {
    if let data, let img = WidgetCoverImage(data: data) {
        Image(platformImage: img)
            .resizable()
            .scaledToFit()
    } else {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [Color(white: 0.15), Color(white: 0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: size, weight: .light))
                    .foregroundStyle(.white.opacity(0.25))
            }
    }
}

/// The cover takes its parent's bounds. The artwork and its inset cannot grow
/// the card or displace an adjacent text column.
func boundedWidgetCover(from data: Data?, inset: CGFloat, placeholderSize: CGFloat = 28) -> some View {
    Color.clear.overlay {
        coverImage(from: data, size: placeholderSize)
            .padding(inset)
    }
}
