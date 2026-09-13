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

    /// Select All operates on `visibleAssets`, not `assets` — with a filter
    /// or search active, "all" means what's on screen. Selecting hidden
    /// items the user can't see and then batch-deleting them would be a
    /// nasty surprise.
    private var visibleIDs: Set<String> {
        Set(store.visibleAssets.map(\.id))
    }

    private var areAllVisibleSelected: Bool {
        let visible = visibleIDs
        return !visible.isEmpty && visible.isSubset(of: store.selectedAssetIDs)
    }

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
                    isAddSheetPresented: $isAddSheetPresented,
                    isSearchFocused: $isSearchFocused,
                    showFilterButton: needsFilterButton,
                    isFilterActive: isFilterActive,
                    onFilterTap: { isFilterSheetPresented = true }
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
                .overlay {
                    // `isLoading` was set by bootstrap() but read by nothing,
                    // so a cold launch rendered an empty list with no
                    // indication anything was happening — it read as "no
                    // items" rather than "still loading".
                    if store.isLoading && store.visibleAssets.isEmpty {
                        ProgressView("Loading items…")
                    } else if store.visibleAssets.isEmpty {
                        ContentUnavailableView(
                            store.searchText.isEmpty ? "No Items" : "No Matches",
                            systemImage: store.searchText.isEmpty ? "shippingbox" : "magnifyingglass"
                        )
                    }
                }
                // Refreshing is deliberately non-blocking — rows from the
                // disk cache are already usable, so this is a quiet hint
                // rather than a spinner over the top of them.
                .overlay(alignment: .top) {
                    if store.isRefreshing && !store.visibleAssets.isEmpty {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Updating…")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 4)
                        .transition(.opacity)
                    }
                }
                .animation(.default, value: store.isRefreshing)
                .overlay(alignment: .bottom) {
                    // Shown for the WHOLE of select mode, not just at 2+
                    // selected. With the navigation bar hidden this bar owns
                    // Done, so gating it on a selection count would strand
                    // the user in select mode with no way out.
                    if isSelectMode || store.selectedAssetIDs.count > 1 {
                        BatchActionBar(
                            selectedIDs: store.selectedAssetIDs,
                            areAllVisibleSelected: areAllVisibleSelected,
                            onToggleSelectAll: { toggleSelectAll() },
                            onDone: {
                                isSelectMode = false
                                store.selectedAssetIDs.removeAll()
                            }
                        )
                    }
                }
            }
            .navigationDestination(for: String.self) { assetID in
                if let asset = store.assets.first(where: { $0.id == assetID }) {
                    ItemDetailView(asset: asset)
                }
            }
            .navigationTitle("Inventory")
            // Hidden entirely on the compact path: its controls now live
            // where they belong — filter in the search row, Done and Select
            // All in the batch bar — so the bar was pure overhead. Applied
            // to this screen only (not the NavigationStack), so pushed
            // destinations like ItemDetailView keep their own bar and back
            // button.
            .toolbar(needsFilterButton ? .hidden : .visible, for: .navigationBar)
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
        // Cmd+A selects everything visible, but ONLY in select mode and only
        // when the search field isn't focused — otherwise it would hijack
        // the text field's own select-all while typing.
        .background(
            Button("") { toggleSelectAll() }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(!isSelectMode || isSearchFocused)
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

    private func toggleSelectAll() {
        let visible = visibleIDs
        if visible.isSubset(of: store.selectedAssetIDs) {
            // Subtract rather than removeAll: anything selected that isn't
            // currently visible (selected before a filter was applied) stays
            // selected, so deselecting what's on screen can't silently drop
            // it from the batch.
            store.selectedAssetIDs.subtract(visible)
        } else {
            store.selectedAssetIDs.formUnion(visible)
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
