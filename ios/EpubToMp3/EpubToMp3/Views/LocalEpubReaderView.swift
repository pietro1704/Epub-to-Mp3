import SwiftUI

/// Last-resort reader for when the backend is unreachable. Surfaces
/// a friendly message + lets the user paste in a backend URL or wait
/// for the embedded sidecar. Doesn't render the EPUB locally — that
/// would require re-implementing the parser the backend already
/// provides via `/api/jobs/{id}/fulltext`. The point here is to NOT
/// crash, NOT lose the user's place, and tell them clearly what to do.
struct LocalEpubReaderView: View {
    let fileURL: URL
    let book: BookEntity

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.orange)
            Text("Reader needs the backend")
                .font(.title2.weight(.semibold))
            Text("To open \(book.resolvedTitle), the app needs to reach the conversion server. The embedded sidecar should be starting now — give it a moment, or check the URL in Settings.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 28)
            VStack(alignment: .leading, spacing: 4) {
                Text("File on disk").font(.caption).foregroundStyle(.secondary)
                Text(fileURL.path)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
            }
            .padding(.top, 12)
            Spacer()
        }
        .padding(.top, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if DEBUG
#Preview("LocalEpubReader") {
    LocalEpubReaderView(
        fileURL: URL(fileURLWithPath: "/tmp/foundation.epub"),
        book: BookEntity(
            id: "preview-1",
            title: "Foundation",
            author: "Asimov",
            bookmark: Data(),
            displayFilename: "foundation.epub",
            addedAt: Date(),
            lastOpenedAt: nil,
            lastChapterIndex: nil,
            lastPositionSeconds: nil,
            coverPNG: nil,
            lastJobId: nil,
            cachedOffline: false
        )
    )
}
#endif
