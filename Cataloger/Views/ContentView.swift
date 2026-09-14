import SwiftUI

struct ContentView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if sizeClass == .compact {
                // Mobile Workspace (iPhone): single-column sliding stack.
                ItemListView()
            } else {
                // Widescreen Workspace (iPad & Mac): 3-column split view.
                WidescreenContainer()
            }
        }
        .overlay(alignment: .bottom) {
            if store.isSyncing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(store.syncStatusMessage)
                        .font(.footnote)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .shadow(radius: 4)
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.default, value: store.isSyncing)
            }
        }
        .alert("Notice", isPresented: .constant(store.lastError != nil), presenting: store.lastError) { _ in
            Button("OK") { store.lastError = nil }
        } message: { message in
            Text(message)
        }
    }
}

/// NavigationSplitView with Sidebar (data pools + tag taxonomy), Content
/// (asset list), and Inspector (detail without losing scroll position).
struct WidescreenContainer: View {
    @Environment(AppStore.self) private var store
    @State private var selectedAssetID: String?
    @State private var showInspector = false

    var body: some View {
        @Bindable var store = store

        NavigationSplitView {
            SidebarView()
                .navigationTitle("Cataloger")
        } content: {
            ItemListView(onSelect: { id in store.selectedAssetIDs = [id] })
        } detail: {
            if let id = selectedAssetID, let asset = store.assets.first(where: { $0.id == id }) {
                ItemDetailView(asset: asset)
                    .id(asset.id)
            } else {
                ContentUnavailableView("Select an Item", systemImage: "shippingbox")
            }
        }
        .onChange(of: store.selectedAssetIDs) { _, newValue in
            selectedAssetID = newValue.count == 1 ? newValue.first : nil
        }
        // Escape handling lives in ItemListView, which is present on both
        // the compact and widescreen paths. There used to be a second,
        // always-enabled Escape button here for clearing the sidebar filter;
        // because `.keyboardShortcut` fires window-wide, it swallowed every
        // Escape press — including ones meant to clear the search field, and
        // presses where it had nothing to clear at all.
    }
}

/// iPhone presentation of `SidebarView`.
///
/// On iPad/Mac the sidebar is a real column of `NavigationSplitView`, which
/// supplies its own show/hide toggle. The compact path renders `ItemListView`
/// alone with no split view, so the whole filter taxonomy (views, containers,
/// tags, stats) had no way to be reached at all. This presents the exact same
/// `SidebarView` as a sheet, so the two platforms can't drift apart — there's
/// only one sidebar implementation.
///
/// Dismisses as soon as a filter is chosen: on iPhone the list is behind the
/// sheet, so staying open would hide the result of the tap.
struct FilterSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SidebarView()
                .navigationTitle("Filter")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .onChange(of: store.activeSidebarFilter) { _, _ in
            dismiss()
        }
    }
}

/// Split out of WidescreenContainer's body: a single `List` builder mixing
/// multiple `ForEach`s, string-interpolated `Label`s, and enum `.tag(...)`
/// calls across several `Section`s is enough to blow past the type
/// checker's time budget. Isolating each section into its own small view
/// (with its own inferred type) fixes the "unable to type-check" error.
///
/// Uses native `List(selection:)` — same as before — so the sidebar keeps
/// the system's own selection highlight styling exactly. The "tap an
/// already-selected row again to deselect" behavior lives entirely in
/// `selectionBinding`'s custom `set`, not in the row views themselves,
/// which are back to plain `Label(...).tag(...)`.
struct SidebarView: View {
    @Environment(AppStore.self) private var store

    private var selectionBinding: Binding<AppStore.SidebarFilter?> {
        Binding(
            get: { store.activeSidebarFilter },
            set: { newValue in
                if let newValue, newValue == store.activeSidebarFilter {
                    // Re-tapped the already-selected row -> deselect.
                    store.activeSidebarFilter = .all
                } else {
                    store.activeSidebarFilter = newValue ?? .all
                }
            }
        )
    }

    var body: some View {
        List(selection: selectionBinding) {
            SidebarStatsSection(totalCount: store.assets.count, pendingSyncCount: store.pendingSyncCount)
            SidebarViewsSection()
            SidebarContainersSection(containers: store.allContainers)
            SidebarTagsSection(tags: store.allTagsWithCounts)
        }
        // Set explicitly rather than relying on the inferred style.
        // `Section(isExpanded:)` only renders its disclosure control in list
        // styles that support it — the NavigationSplitView sidebar column
        // infers `.sidebar` already, but this same view is also presented as
        // a sheet on iPhone (`FilterSheet`), where it wouldn't. Pinning it
        // keeps the collapse behavior identical in both places.
        .listStyle(.sidebar)
    }
}


private struct SidebarStatsSection: View {
    let totalCount: Int
    let pendingSyncCount: Int

    var body: some View {
        Section("Stats") {
            LabeledContent("Total Items", value: "\(totalCount)")
            if pendingSyncCount > 0 {
                LabeledContent("Awaiting Sync", value: "\(pendingSyncCount)")
                    .foregroundStyle(.orange)
            } else {
                LabeledContent("Awaiting Sync", value: "\(pendingSyncCount)")
            }
        }
    }
}

private struct SidebarViewsSection: View {
    var body: some View {
        Section("Views") {
            Label("All Items", systemImage: "square.grid.2x2")
                .tag(AppStore.SidebarFilter.all)
            Label("Checked Out", systemImage: "arrow.up.right.square")
                .tag(AppStore.SidebarFilter.checkedOut)
        }
    }
}

private struct SidebarContainersSection: View {
    let containers: [String]
    /// Persisted so the sidebar reopens the way you left it rather than
    /// re-expanding a long list on every launch.
    @AppStorage("sidebarContainersExpanded") private var isExpanded = true

    var body: some View {
        // Count stays in the header so a collapsed section still tells you
        // what's inside it.
        Section("Containers (\(containers.count))", isExpanded: $isExpanded) {
            ForEach(containers, id: \.self) { container in
                SidebarContainerRow(container: container)
            }
        }
    }
}

private struct SidebarContainerRow: View {
    let container: String

    var body: some View {
        Label(container, systemImage: "shippingbox")
            .tag(AppStore.SidebarFilter.container(container))
    }
}

private struct SidebarTagsSection: View {
    let tags: [(tag: String, count: Int)]
    @AppStorage("sidebarTagsExpanded") private var isExpanded = true

    var body: some View {
        Section("Tags (\(tags.count))", isExpanded: $isExpanded) {
            ForEach(tags, id: \.tag) { entry in
                SidebarTagRow(tag: entry.tag, count: entry.count)
            }
        }
    }
}

private struct SidebarTagRow: View {
    let tag: String
    let count: Int

    var body: some View {
        let labelText = "#\(tag) (\(count))"
        Label(labelText, systemImage: "number")
            .tag(AppStore.SidebarFilter.tag(tag))
    }
}
