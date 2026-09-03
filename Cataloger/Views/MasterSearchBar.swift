import SwiftUI

struct MasterSearchBar: View {
    @Environment(AppStore.self) private var store
    @FocusState.Binding var isSearchFocused: Bool
    @State private var showScanner = false
    @State private var showContextMenu = false
    @State private var showAddSheet = false
    @State private var exportedFileURL: URL?
    @State private var showLegacyImporter = false
    @State private var showImgurSettings = false

    var body: some View {
        @Bindable var store = store

        HStack(spacing: 12) {
            Button {
                showContextMenu = true
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .popover(isPresented: $showContextMenu) {
                ContextMenuPanel(
                    onExportCSV: { closeMenuThen { exportCSV() } },
                    onImportLegacy: { closeMenuThen { showLegacyImporter = true } },
                    onImgurSettings: { closeMenuThen { showImgurSettings = true } }
                )
                .frame(minWidth: 260)
            }

            HStack {
                Image(systemName: "magnifyingglass")
                TextField("Search Items, SKUs, or Tags...", text: $store.searchText)
                    .focused($isSearchFocused)
                    .textFieldStyle(.plain)
                Spacer()
                Button {
                    showScanner = true
                } label: {
                    Image(systemName: "camera")
                }
            }
            .padding(8)
            .background(Color(uiColor: .systemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Button {
                showAddSheet = true
            } label: {
                Image(systemName: "plus")
            }
        }
        .padding(.horizontal)
        .sheet(isPresented: $showScanner) {
            QRScannerView(
                onCode: { code in
                    store.searchText = code
                    showScanner = false
                },
                onCancel: { showScanner = false }
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showAddSheet) {
            ItemAddView(prefillName: store.searchHasNoMatches ? store.searchText : "")
        }
        .fileImporter(isPresented: $showLegacyImporter, allowedContentTypes: [.data]) { result in
            guard case .success(let url) = result else { return }
            Task {
                _ = try? await store.importLegacy(fileURL: url)
            }
        }
        .sheet(isPresented: $showImgurSettings) {
            ImgurSettingsView()
        }
        .alert("Exported", isPresented: .constant(exportedFileURL != nil), presenting: exportedFileURL) { _ in
            Button("OK") { exportedFileURL = nil }
        } message: { url in
            Text("Saved to \(url.lastPathComponent)")
        }
    }

    /// Closes the `•••` popover first, then runs `action` after its
    /// dismissal animation actually finishes. Without this delay, firing
    /// another presentation (file importer, sheet) in the same tap as the
    /// popover's dismissal causes "already presenting" UIKit conflicts,
    /// since SwiftUI's popover dismissal isn't synchronous.
    private func closeMenuThen(_ action: @escaping () -> Void) {
        showContextMenu = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            action()
        }
    }

    private func exportCSV() {
        do {
            exportedFileURL = try store.exportCSV()
        } catch {
            store.lastError = error.localizedDescription
        }
    }
}

/// Content of the `•••` contextual menu panel.
struct ContextMenuPanel: View {
    var onExportCSV: () -> Void
    var onImportLegacy: () -> Void
    var onImgurSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("Imgur Account Settings", systemImage: "person.crop.circle", action: onImgurSettings)
            Button("Export to .csv (readable file)", systemImage: "square.and.arrow.up", action: onExportCSV)
            Divider()
            Button("Import Legacy .mcs File", systemImage: "tray.and.arrow.down", action: onImportLegacy)
        }
        .buttonStyle(.borderless)
        .padding()
    }
}

struct ImgurSettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var isLoggingIn = false
    @State private var isCreatingAlbum = false
    @State private var loginError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Imgur Account") {
                    if store.imgurIsLoggedIn {
                        LabeledContent("Logged in as", value: store.imgurUserName ?? "Unknown")
                        Button("Log Out", role: .destructive) {
                            store.imgurLogOut()
                        }
                    } else {
                        Button {
                            Task {
                                isLoggingIn = true
                                defer { isLoggingIn = false }
                                do {
                                    try await store.imgurLogIn()
                                } catch {
                                    loginError = "Login failed: \(error.localizedDescription)"
                                }
                            }
                        } label: {
                            if isLoggingIn {
                                ProgressView()
                            } else {
                                Text("Log In with Imgur")
                            }
                        }
                        .disabled(isLoggingIn)
                    }
                }

                if store.imgurIsLoggedIn {
                    Section("Upload Album") {
                        LabeledContent("Album ID", value: store.imgurAlbumId ?? "None yet — created on first upload")

                        Button {
                            Task {
                                isCreatingAlbum = true
                                defer { isCreatingAlbum = false }
                                do {
                                    _ = try await store.imgurCreateNewAlbum()
                                } catch {
                                    loginError = "Couldn't create album: \(error.localizedDescription)"
                                }
                            }
                        } label: {
                            if isCreatingAlbum {
                                ProgressView()
                            } else {
                                Text("Create New Album")
                            }
                        }
                        .disabled(isCreatingAlbum)

                        Text("New uploads go to the new album. Photos already uploaded stay in the old one on Imgur.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Imgur Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Imgur", isPresented: .constant(loginError != nil), presenting: loginError) { _ in
                Button("OK") { loginError = nil }
            } message: { message in
                Text(message)
            }
        }
    }
}
