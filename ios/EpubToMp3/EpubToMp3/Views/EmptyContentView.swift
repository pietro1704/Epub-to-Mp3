import SwiftUI

/// HIG empty-state view: an SF Symbol illustration, a title, and a
/// short description, vertically centred. Wraps Apple's
/// `ContentUnavailableView` on iOS 17+ / macOS 14+; falls back to a
/// hand-laid VStack on the earlier deployment targets we still
/// support (iOS 15 / macOS 12).
///
/// Used for "this book had no readable content", "library is empty",
/// "no search results" — anywhere the surface would otherwise show a
/// bare sentence. The native variant gets free Dynamic Type sizing,
/// VoiceOver grouping, and the correct platform-default illustration
/// treatment; the fallback approximates the same layout so the UX
/// degrades gracefully on iOS 15/16 without diverging visually.
struct EmptyContentView: View {
    let title: String
    let message: String?
    let systemImage: String

    init(title: String, message: String? = nil, systemImage: String) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
    }

    var body: some View {
        if #available(iOS 17, macOS 14, *) {
            if let message {
                ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
            } else {
                ContentUnavailableView(title, systemImage: systemImage)
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                if let message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .frame(maxWidth: 480)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        }
    }
}

#if DEBUG
#Preview("EmptyContentView") {
    EmptyContentView(
        title: "No content available",
        message: "This book couldn't be read by the parser. Try re-importing the file or pick a different book.",
        systemImage: "doc.text.magnifyingglass"
    )
}
#endif
