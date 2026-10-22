import SwiftUI

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
typealias PlatformImage = UIImage
extension Image {
    init(platformImage img: UIImage) { self.init(uiImage: img) }
}
#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
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
    if let data, let img = PlatformImage(data: data) {
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
