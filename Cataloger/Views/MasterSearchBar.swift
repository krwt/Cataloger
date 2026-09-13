import SwiftUI
import UniformTypeIdentifiers

struct MasterSearchBar: View {
    @Environment(AppStore.self) private var store
    @FocusState.Binding var isSearchFocused: Bool
    @State private var showScanner = false
    @State private var showContextMenu = false
    @State private var showAddSheet = false
    @State private var exportedFileURL: URL?
    @State private var showLegacyImporter = false
    @State private var legacyImportPreview: AppStore.LegacyImportPreview?
    @State private var showImgurSettings = false
    @State private var showCSVRestoreImporter = false
    @State private var restorePreview: CSVBackupManager.RestorePreview?
    @State private var showDeleteAllWarning1 = false
    @State private var showDeleteAllWarning2 = false

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
                    onRestoreCSV: { closeMenuThen { showCSVRestoreImporter = true } },
                    onImportLegacy: { closeMenuThen { showLegacyImporter = true } },
                    onImgurSettings: { closeMenuThen { showImgurSettings = true } },
                    onDeleteAll: { closeMenuThen { showDeleteAllWarning1 = true } }
                )
                .frame(minWidth: 260)
            }

            HStack {
                Image(systemName: "magnifyingglass")
                HStack{
                    TextField("Search Items, SKUs, or Tags...", text: $store.searchText)
                        .focused($isSearchFocused)
                        .textFieldStyle(.plain)
                    Button {
                        store.searchText = ""
                    } label:{
                        Image(systemName: "xmark.circle")
                    }
                }.padding()
                Spacer()
                Button {
                    showScanner = true
                } label: {
                    Image(systemName: "qrcode.viewfinder")
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
            do {
                legacyImportPreview = try store.previewLegacyImport(fileURL: url)
            } catch {
                store.lastError = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $showCSVRestoreImporter, allowedContentTypes: [.commaSeparatedText, .data]) { result in
            guard case .success(let url) = result else { return }
            do {
                restorePreview = try store.previewCSVRestore(fileURL: url)
            } catch {
                store.lastError = error.localizedDescription
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
        // MARK: Restore from backup.csv — preview, then confirm before committing.
        .confirmationDialog(
            "Restore from Backup",
            isPresented: .constant(restorePreview != nil),
            titleVisibility: .visible,
            presenting: restorePreview
        ) { preview in
            Button("Restore \(preview.assets.count) Items") {
                Task {
                    await store.commitCSVRestore(preview.assets)
                    restorePreview = nil
                }
            }
            Button("Cancel", role: .cancel) { restorePreview = nil }
        } message: { preview in
            Text("\(preview.updatedCount) existing item(s) will be updated, \(preview.createdCount) new item(s) will be added.\(preview.skippedRowCount > 0 ? " \(preview.skippedRowCount) row(s) couldn't be read and will be skipped." : "")")
        }
        // MARK: Import Legacy .mcs — same preview-then-confirm pattern.
        .confirmationDialog(
            "Import Legacy File",
            isPresented: .constant(legacyImportPreview != nil),
            titleVisibility: .visible,
            presenting: legacyImportPreview
        ) { preview in
            Button("Import \(preview.assets.count) Items") {
                Task {
                    await store.commitLegacyImport(preview.assets)
                    legacyImportPreview = nil
                }
            }
            Button("Cancel", role: .cancel) { legacyImportPreview = nil }
        } message: { preview in
            Text("\(preview.updatedCount) existing item(s) will be updated, \(preview.createdCount) new item(s) will be added.\(preview.skippedRowCount > 0 ? " \(preview.skippedRowCount) row(s) couldn't be read and will be skipped." : "")\(preview.duplicateIDsReassigned > 0 ? " \(preview.duplicateIDsReassigned) duplicate row(s) shared an ID with an earlier row and got a new one, so nothing was lost." : "")")
        }
        // MARK: Delete All — two separate warnings before anything happens.
        .confirmationDialog(
            "Delete All \(store.assets.count) Items?",
            isPresented: $showDeleteAllWarning1,
            titleVisibility: .visible
        ) {
            Button("Continue", role: .destructive) {
                closeMenuThen { showDeleteAllWarning2 = true }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every item from Cataloger on all your devices. This cannot be undone.")
        }
        .confirmationDialog(
            "Are you absolutely sure?",
            isPresented: $showDeleteAllWarning2,
            titleVisibility: .visible
        ) {
            Button("Permanently Delete All \(store.assets.count) Items", role: .destructive) {
                Task { await store.deleteAllAssets() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("There is no undo. Every item, photo reference, and tag will be gone from every device signed into this iCloud account.")
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
    var onRestoreCSV: () -> Void
    var onImportLegacy: () -> Void
    var onImgurSettings: () -> Void
    var onDeleteAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("Imgur Account Settings", systemImage: "person.crop.circle", action: onImgurSettings)
            Divider()
            Button("Export to .csv (readable file)", systemImage: "square.and.arrow.up", action: onExportCSV)
            Button("Restore from Backup (.csv)", systemImage: "arrow.clockwise.icloud", action: onRestoreCSV)
            Button("Import Legacy .mcs File", systemImage: "tray.and.arrow.down", action: onImportLegacy)
            Divider()
            Button("Delete All Items", systemImage: "trash", role: .destructive, action: onDeleteAll)
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
