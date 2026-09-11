import SwiftUI

/// Reusable tag editor: shows current tags as a removable cloud, an input
/// field with an Add button, and live autocomplete suggestions drawn from
/// every tag already used elsewhere in the collection.
///
/// All normalization (trim whitespace, lowercase, dedupe) goes through
/// `Asset.normalizeTag` — the same helper `AppStore.save()` uses — so
/// what you see here always matches what actually gets persisted.
struct TagEditorSection: View {
    @Environment(AppStore.self) private var store
    @Binding var tags: [String]
    @State private var draftText = ""
    @State private var highlightedIndex: Int?

    /// Existing tags matching the current draft, already-added tags
    /// excluded, prefix matches ranked above mid-string matches.
    private var suggestions: [String] {
        let query = Asset.normalizeTag(draftText)
        guard !query.isEmpty else { return [] }
        let alreadyAdded = Set(tags.map(Asset.normalizeTag))

        return store.allTagsWithCounts
            .map(\.tag)
            .filter { $0.contains(query) && !alreadyAdded.contains($0) }
            .sorted { lhs, rhs in
                let lhsPrefix = lhs.hasPrefix(query)
                let rhsPrefix = rhs.hasPrefix(query)
                if lhsPrefix != rhsPrefix { return lhsPrefix }
                return lhs < rhs
            }
            .prefix(5)
            .map { $0 }
    }

    var body: some View {
        Section("Tags") {
            TagCloudView(tags: $tags)

            HStack {
                TextField("Add tag", text: $draftText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { commitDraft() }
                    // Up/Down cycle through suggestion chips — Left/Right
                    // are deliberately left alone so they still move the
                    // text cursor normally while typing.
                    .onKeyPress(.downArrow) {
                        moveHighlight(by: 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        moveHighlight(by: -1)
                        return .handled
                    }
                Button("Add") { commitDraft() }
                    .disabled(draftText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .onChange(of: draftText) { _, _ in
                highlightedIndex = nil
            }

            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(suggestions.enumerated()), id: \.element) { index, suggestion in
                            let isHighlighted = index == highlightedIndex
                            Button {
                                addTag(suggestion)
                            } label: {
                                Text(suggestion)
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(isHighlighted ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12))
                                    .overlay(
                                        Capsule().stroke(isHighlighted ? Color.accentColor : Color.clear, lineWidth: 1)
                                    )
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func moveHighlight(by delta: Int) {
        guard !suggestions.isEmpty else { return }
        let current = highlightedIndex ?? (delta > 0 ? -1 : suggestions.count)
        let next = (current + delta + suggestions.count) % suggestions.count
        highlightedIndex = next
    }

    /// Commits the highlighted suggestion if there is one, otherwise the
    /// literally-typed draft text. Called from both the Add button and the
    /// TextField's onSubmit (Return key) — kept as a single path rather
    /// than adding a competing onKeyPress(.return) handler, since stacking
    /// onSubmit and onKeyPress for the same key on the same field is
    /// exactly what caused the earlier focus-cascade bugs elsewhere in
    /// this app.
    private func commitDraft() {
        if let highlightedIndex, suggestions.indices.contains(highlightedIndex) {
            addTag(suggestions[highlightedIndex])
        } else {
            addTag(draftText)
        }
    }

    private func addTag(_ raw: String) {
        let clean = Asset.normalizeTag(raw)
        guard !clean.isEmpty else { return }
        if !tags.contains(where: { Asset.normalizeTag($0) == clean }) {
            tags.append(clean)
        }
        draftText = ""
        highlightedIndex = nil
    }
}
