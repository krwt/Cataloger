import SwiftUI

/// Bottom overlay bar shown for the whole of multi-select mode.
///
/// It now owns Done and Select All in addition to the batch actions, because
/// the compact layout hides the navigation bar entirely — without that, being
/// in select mode with fewer than two items selected would leave no way out.
/// Batch Move and Batch Tag require an explicit confirmation step; Batch
/// Checkout is a fast, reversible toggle and does not require confirmation.
struct BatchActionBar: View {
    @Environment(AppStore.self) private var store
    let selectedIDs: Set<String>
    /// True when everything currently visible is already selected — drives
    /// the Select All / Deselect All label.
    let areAllVisibleSelected: Bool
    let onToggleSelectAll: () -> Void
    let onDone: () -> Void

    @State private var showMoveSheet = false
    @State private var showTagSheet = false
    @State private var moveTarget = ""
    @State private var tagInput = ""

    /// Batch operations need something to operate on. Kept separate from
    /// whether the bar is shown at all, so the bar can stay up (with Done
    /// reachable) even at zero selected.
    private var hasSelection: Bool { !selectedIDs.isEmpty }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(selectedIDs.isEmpty ? "Select items" : "\(selectedIDs.count) selected")
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)

                Spacer()

                Button(areAllVisibleSelected ? "Deselect All" : "Select All") {
                    onToggleSelectAll()
                }
                .font(.footnote)

                Button("Done") { onDone() }
                    .font(.footnote.weight(.semibold))
            }

            Divider()

            HStack(spacing: 20) {
                Button("Move") { showMoveSheet = true }
                    .disabled(!hasSelection)
                Button("Checkout") {
                    Task { await store.batchToggleCheckout(ids: selectedIDs) }
                }
                .disabled(!hasSelection)
                Button("Tag") { showTagSheet = true }
                    .disabled(!hasSelection)
                Spacer()
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 4)
        .padding()
        .confirmationDialog("Move \(selectedIDs.count) items?", isPresented: $showMoveSheet, titleVisibility: .visible) {
            ForEach(store.allContainers, id: \.self) { container in
                Button(container) {
                    Task { await store.batchMove(ids: selectedIDs, toContainer: container) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showTagSheet) {
            NavigationStack {
                Form {
                    TextField("Tag name", text: $tagInput)
                }
                .navigationTitle("Batch Tag \(selectedIDs.count) items")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showTagSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Apply") {
                            Task {
                                await store.batchAddTag(ids: selectedIDs, tag: tagInput)
                                showTagSheet = false
                                tagInput = ""
                            }
                        }
                        .disabled(tagInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }
}
