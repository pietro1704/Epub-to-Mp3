import SwiftUI

struct SearchResult: Identifiable, Equatable {
    let id = UUID()
    let chapterIndex: Int
    let chapterTitle: String
    let snippet: String
    let range: Range<String.Index>
}

struct ReaderSearchOverlay: View {
    let chapters: [EbookFulltext.Chapter]
    var onJumpToChapter: ((Int) -> Void)?
    @Binding var isPresented: Bool

    @State private var query = ""
    @State private var results: [SearchResult] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(L10n.string("instantReader.searchInBook"), text: $query)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .onSubmit { search() }
                if !query.isEmpty {
                    Button { query = ""; results = [] } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Button(L10n.string("general.done")) { isPresented = false }
                    .font(.callout.weight(.medium))
            }
            .padding(12)
            .background(.thinMaterial)

            if results.isEmpty && !query.isEmpty {
                Text(localized: "search.noResults")
                    .foregroundStyle(.secondary)
                    .padding(.top, 40)
                    .frame(maxWidth: .infinity)
            } else {
                List(results) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.chapterTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(result.snippet)
                            .font(.body)
                            .lineLimit(3)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onJumpToChapter?(result.chapterIndex)
                        isPresented = false
                    }
                }
                .listStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("instantReader.searchInBook"))
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { results = []; return }
        let lowered = q.lowercased()
        var found: [SearchResult] = []
        for ch in chapters {
            let text = ch.text
            let lower = text.lowercased()
            var searchStart = lower.startIndex
            while let range = lower.range(of: lowered, range: searchStart..<lower.endIndex) {
                let snippetStart = text.index(range.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
                let snippetEnd = text.index(range.upperBound, offsetBy: 40, limitedBy: text.endIndex) ?? text.endIndex
                let snippet = "…" + text[snippetStart..<snippetEnd]
                    .replacingOccurrences(of: "\n", with: " ") + "…"
                found.append(SearchResult(
                    chapterIndex: ch.index,
                    chapterTitle: ch.displayTitle,
                    snippet: snippet,
                    range: range
                ))
                searchStart = range.upperBound
                if found.count >= 100 { break }
            }
            if found.count >= 100 { break }
        }
        results = found
    }
}

#if DEBUG
#Preview("Search overlay") {
    ReaderSearchOverlay(
        chapters: EbookFulltext.previewSample.chapters,
        isPresented: .constant(true)
    )
}
#endif
