import SwiftUI

struct ItemListView: View {
    @Environment(AppStore.self) private var store
    @State private var navigationPath = NavigationPath()
    @State private var selectedRowIndex: Int?
    @FocusState private var isSearchFocused: Bool
    @State private var isSelectMode = false
    @State private var isAddSheetPresented = false
    @State private var isFilterSheetPresented = false

    /// True when the sidebar taxonomy isn't reachable any other way — i.e.
    /// the compact/iPhone path, where this view is rendered standalone
    /// rather than as the content column of a NavigationSplitView. Keyed
    /// off `onSelect` for the same reason the row-tap behavior is: inside
    /// a split view the content column reports its own (often .compact)
    /// size class, so `horizontalSizeClass` can't distinguish the two.
    private var needsFilterButton: Bool { onSelect == nil }

    /// Whether a non-default filter is currently narrowing the list —
    /// drives the filled/unfilled toolbar icon so it's obvious at a glance
    /// that the list isn't showing everything.
    private var isFilterActive: Bool { (store.activeSidebarFilter ?? .all) != .all }

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
                MasterSearchBar(
                    isAddSheetPresented: $isAddSheetPresented, isSearchFocused: $isSearchFocused
                ).padding(.vertical, 8)

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
                if needsFilterButton {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            isFilterSheetPresented = true
                        } label: {
                            Image(systemName: isFilterActive
                                  ? "line.3.horizontal.decrease.circle.fill"
                                  : "line.3.horizontal.decrease.circle")
                        }
                        .accessibilityLabel("Filter")
                    }
                }
                if isSelectMode {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            isSelectMode = false
                            store.selectedAssetIDs.removeAll()
                        }
                    }
                }
            }
            .sheet(isPresented: $isFilterSheetPresented) {
                FilterSheet()
            }
        }
        // MARK: Desktop-class keyboard shortcuts (iPad & Mac hardware keyboard)
        // Uses a hidden Button + .keyboardShortcut rather than .onKeyPress:
        // onKeyPress only reliably fires when something within its subtree
        // already has focus, so it wasn't catching Cmd+F when nothing (or
        // a different view entirely) currently held focus. .keyboardShortcut
        // on a Button works window-wide regardless of current focus.
        .background(
            Button("") { isSearchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        )
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
            // Mirrors WidescreenContainer's escape-clears-filter behavior,
            // so the two paths behave the same on a hardware keyboard.
            if isFilterActive {
                store.activeSidebarFilter = .all
                return .handled
            }
            return .ignored
        }
        // Arrow keys move the row selection only when the list is actually
        // the active context. These used to return `.handled`
        // unconditionally, which swallowed arrows meant for other views —
        // and because a presented sheet shares the same focus ring as its
        // presenter here (Tab from the Add sheet walks right into this
        // view's search field), "some other view" includes views inside
        // the Add sheet. Returning `.ignored` lets the event fall through
        // to whoever should actually get it.
        .onKeyPress(.upArrow) {
            guard !isAddSheetPresented, !isSearchFocused else { return .ignored }
            moveSelection(-1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard !isAddSheetPresented, !isSearchFocused else { return .ignored }
            moveSelection(1)
            return .handled
        }
        .onKeyPress(.return) {
            guard !isAddSheetPresented, !isSearchFocused else { return .ignored }
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
