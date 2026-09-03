import SwiftUI

struct ItemListView: View {
    @Environment(AppStore.self) private var store
    @State private var navigationPath = NavigationPath()
    @State private var selectedRowIndex: Int?
    @FocusState private var isSearchFocused: Bool
    @State private var isSelectMode = false

    /// When non-nil, tapping a row calls this instead of pushing onto this
    /// view's own NavigationStack. WidescreenContainer passes a closure that
    /// updates `selectedAssetIDs` (driving the separate detail column);
    /// on iPhone this stays nil, so rows push normally in this single-column
    /// stack. Deliberately explicit rather than inferred from
    /// horizontalSizeClass — inside a NavigationSplitView, the content
    /// column reports its own (often .compact) size class regardless of
    /// the overall device/window, which made that inference unreliable.
    var onSelect: ((String) -> Void)?

    var body: some View {
        @Bindable var store = store

        NavigationStack(path: $navigationPath) {
            VStack(spacing: 0) {
                MasterSearchBar(isSearchFocused: $isSearchFocused)
                    .padding(.vertical, 8)

                List(selection: $store.selectedAssetIDs) {
                    ForEach(Array(store.visibleAssets.enumerated()), id: \.element.id) { index, asset in
                        ZStack {
                            // Zebra striping: alternating background shade.
                            (index.isMultiple(of: 2)
                                ? Color(uiColor: .systemBackground)
                                : Color.secondary.opacity(0.03))

                            // Plain tap gesture (not Button) so it doesn't
                            // compete with the long-press gesture below for
                            // the same touch — a Button's own tap recognizer
                            // was consuming the touch before long-press could
                            // ever fire.
                            ItemRowView(asset: asset)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectRow(asset.id)
                                }
                                .simultaneousGesture(
                                    LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                                        isSelectMode = true
                                        store.selectedAssetIDs.insert(asset.id)
                                    }
                                )
                        }
                        .listRowInsets(EdgeInsets())
                        .tag(asset.id)
                    }
                }
                .listStyle(.plain)
                .environment(\.editMode, .constant(isSelectMode ? .active : .inactive))
                .refreshable { await store.refresh() }
                .overlay(alignment: .bottom) {
                    if store.selectedAssetIDs.count > 1 {
                        BatchActionBar(selectedIDs: store.selectedAssetIDs)
                    }
                }
            }
            .navigationDestination(for: String.self) { assetID in
                if let asset = store.assets.first(where: { $0.id == assetID }) {
                    ItemDetailView(asset: asset)
                }
            }
            .navigationTitle("Inventory")
            .toolbar {
                if isSelectMode {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            isSelectMode = false
                            store.selectedAssetIDs.removeAll()
                        }
                    }
                }
            }
        }
        // MARK: Desktop-class keyboard shortcuts (iPad & Mac hardware keyboard)
        .onKeyPress(.init("f"), phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            isSearchFocused = true
            return .handled
        }
        .onKeyPress(.escape) {
            if isSelectMode {
                isSelectMode = false
                store.selectedAssetIDs.removeAll()
                return .handled
            }
            if isSearchFocused {
                store.searchText = ""
                isSearchFocused = false
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.upArrow) {
            moveSelection(-1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(1)
            return .handled
        }
        .onKeyPress(.return) {
            guard let index = selectedRowIndex, store.visibleAssets.indices.contains(index) else { return .ignored }
            selectRow(store.visibleAssets[index].id)
            return .handled
        }
    }

    private func selectRow(_ assetID: String) {
        if isSelectMode {
            if store.selectedAssetIDs.contains(assetID) {
                store.selectedAssetIDs.remove(assetID)
                if store.selectedAssetIDs.isEmpty { isSelectMode = false }
            } else {
                store.selectedAssetIDs.insert(assetID)
            }
            return
        }
        if let onSelect {
            onSelect(assetID)
        } else {
            navigationPath.append(assetID)
        }
    }

    private func moveSelection(_ delta: Int) {
        let count = store.visibleAssets.count
        guard count > 0 else { return }
        let current = selectedRowIndex ?? -1
        selectedRowIndex = min(max(current + delta, 0), count - 1)
    }
}
