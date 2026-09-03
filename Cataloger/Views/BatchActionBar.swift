import SwiftUI

/// Bottom overlay bar shown when 2+ assets are selected. Batch Move and
/// Batch Tag require an explicit confirmation step; Batch Checkout is a
/// fast, reversible toggle and does not require confirmation.
struct BatchActionBar: View {
    @Environment(AppStore.self) private var store
    let selectedIDs: Set<String>

    @State private var showMoveSheet = false
    @State private var showTagSheet = false
    @State private var moveTarget = ""
    @State private var tagInput = ""

    var body: some View {
        HStack(spacing: 20) {
            Text("\(selectedIDs.count) selected")
                .font(.footnote)
                .foregroundStyle(Color.secondary)

            Spacer()

            Button("Move") { showMoveSheet = true }
            Button("Checkout") {
                Task { await store.batchToggleCheckout(ids: selectedIDs) }
            }
            Button("Tag") { showTagSheet = true }
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
