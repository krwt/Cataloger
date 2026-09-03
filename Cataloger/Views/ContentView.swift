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
    }
}

/// Split out of WidescreenContainer's body: a single `List` builder mixing
/// multiple `ForEach`s, string-interpolated `Label`s, and enum `.tag(...)`
/// calls across several `Section`s is enough to blow past the type
/// checker's time budget. Isolating each section into its own small view
/// (with its own inferred type) fixes the "unable to type-check" error.
struct SidebarView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store

        List(selection: $store.activeSidebarFilter) {
            SidebarViewsSection()
            SidebarContainersSection(containers: store.allContainers)
            SidebarTagsSection(tags: store.allTagsWithCounts)
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

    var body: some View {
        Section("Containers") {
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

    var body: some View {
        Section("Tags") {
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
