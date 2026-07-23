import SwiftUI

/// Soft-failure surface used when the on-device parser couldn't extract
/// chapters from an EPUB (rare — usually a corrupted ZIP or a DRM-locked
/// file). Used to say "Reader needs the backend"; that copy was wrong
/// because EPUB parsing is fully local in this app — `BookOpenView`
/// runs `EpubMetadataReader` + `PythonBridge.parseEpub` (iOS) or
/// `MacEpubParser` (macOS) before ever needing a server.
///
/// The view shows the file path (selectable) and a small retry CTA;
/// the host (`BookOpenView.errorView`) supplies the actual retry
/// button. We keep the file path visible so power users can rule out
/// the import path (e.g. a stale security-scoped bookmark).
struct LocalEpubReaderView: View {
    let fileURL: URL
    let book: BookEntity

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(localized: "localEpubReader.couldntRead")
                .font(.title2.weight(.semibold))
            Text(L10n.string("localEpubReader.noChapters", book.resolvedTitle))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(localized: "localEpubReader.fileOnDisk").font(.caption).foregroundStyle(.secondary)
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
