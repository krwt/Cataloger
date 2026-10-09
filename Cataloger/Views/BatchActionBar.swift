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

    /// Shared by the Move button and the field's own Return key.
    ///
    /// Trimmed before saving so " a1 " doesn't become a container distinct
    /// from "a1" — `normalizedContainerKey` treats them as one for filtering,
    /// but what's stored on the asset is the raw string, and `allContainers`
    /// shows the first-seen casing.
    private func applyMove() {
        let target = moveTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        Task {
            await store.batchMove(ids: selectedIDs, toContainer: target)
            showMoveSheet = false
            moveTarget = ""
        }
    }

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
        // A typed field rather than a button-per-container confirmation
        // dialog. The dialog listed every known container as a full-width
        // row — unusable once there are more than a handful — and could only
        // ever offer containers that already exist, so moving items into a
        // new one wasn't possible here at all.
        .sheet(isPresented: $showMoveSheet) {
            NavigationStack {
                Form {
                    TextField("Container", text: $moveTarget)
                        // Containers are short codes like "A1"; autocorrect
                        // and autocapitalization both mangle them, and
                        // matching is case-insensitive anyway.
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit(applyMove)
                }
                .navigationTitle("Move \(selectedIDs.count) items")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            showMoveSheet = false
                            moveTarget = ""
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Move", action: applyMove)
                            .disabled(moveTarget.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
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
