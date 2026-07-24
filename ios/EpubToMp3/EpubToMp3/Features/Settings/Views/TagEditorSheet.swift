import SwiftUI

#if os(iOS)
struct TagEditorSheet: View {
    let book: BookEntity

    var body: some View {
        EmptyView()
    }
}
#else
struct TagEditorSheet: View {
    let book: BookEntity
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var newTag = ""

    var body: some View {
        CompatNavigationStack {
            Form {
                Section(L10n.string("tagEditor.tags")) {
                    ForEach(book.tags, id: \.self) { tag in
                        HStack {
                            Label(tag, systemImage: "tag.fill")
                            Spacer()
                            Button {
                                library.removeTag(tag, from: book.id)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L10n.string("tagEditor.removeTag", tag))
                        }
                    }
                    HStack {
                        TextField(L10n.string("tagEditor.newTag"), text: $newTag)
                            .onSubmit { addCurrentTag() }
                        Button(L10n.string("tagEditor.add")) { addCurrentTag() }
                            .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                if !suggestedTags.isEmpty {
                    Section(L10n.string("tagEditor.existingTags")) {
                        suggestedTagsContent
                    }
                }
            }
            .navigationTitle(L10n.string("library.editTags"))
            .compatInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("general.done")) { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var suggestedTagsContent: some View {
        let tags = suggestedTags
        if #available(iOS 16, macOS 13, *) {
            FlowLayout(spacing: 8) {
                ForEach(tags, id: \.self) { tag in
                    suggestedTagButton(tag)
                }
            }
        } else {
            ForEach(tags, id: \.self) { tag in
                suggestedTagButton(tag)
            }
        }
    }

    private func suggestedTagButton(_ tag: String) -> some View {
        Button {
            library.addTag(tag, to: book.id)
        } label: {
            Text(tag)
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.tint.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var suggestedTags: [String] {
        library.allTags.filter { !book.tags.contains($0) }
    }

    private func addCurrentTag() {
        let trimmed = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        library.addTag(trimmed, to: book.id)
        newTag = ""
    }
}
#endif

@available(iOS 16, macOS 13, *)
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        return (CGSize(width: maxWidth, height: y + rowHeight), positions)
    }
}

#if DEBUG
#Preview("Tag Editor") {
    TagEditorSheet(book: BookEntity(
        id: "preview-1", title: "Foundation", bookmark: Data(),
        displayFilename: "foundation.epub", addedAt: Date(), tags: ["sci-fi", "classic"]
    ))
    .environmentObject(LibraryStore.previewPopulated)
}
#endif
