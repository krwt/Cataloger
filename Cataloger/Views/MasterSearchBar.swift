import SwiftUI
import UniformTypeIdentifiers

struct MasterSearchBar: View {
    @Binding var isAddSheetPresented: Bool
    @Environment(AppStore.self) private var store
    @FocusState.Binding var isSearchFocused: Bool
    /// The compact layout hides the navigation bar, so the filter control
    /// moves here — into the row that already owns the other list-level
    /// actions. Off by default so the iPad content column, which keeps a
    /// real sidebar column, doesn't show a redundant button.
    var showFilterButton: Bool = false
    var isFilterActive: Bool = false
    var onFilterTap: () -> Void = {}
    /// Local, unobserved draft the TextField binds to. Typing into this
    /// costs nothing beyond a plain `@State` update — it doesn't touch
    /// `store.searchText`, which is what actually drives `visibleAssets`
    /// filtering/sorting and a full row re-render of `ItemListView` on
    /// every `@Observable` mutation. `store.searchText` is only updated
    /// ~150ms after the user pauses typing, via `searchDebounceTask` below.
    @State private var searchDraft = ""
    @State private var searchDebounceTask: Task<Void, Never>?
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

    // Labels Module State Variables
    @State private var showLabelPagePrompt = false
    @State private var labelPageCountString = "1"
    @State private var generatedLabelsURL: URL? = nil

    var body: some View {
        @Bindable var store = store

        HStack(spacing: 12) {
            Button {
                showContextMenu = true
            } label: {
                Image(systemName: "ellipsis.circle")
            }            .popover(isPresented: $showContextMenu) {
                ContextMenuPanel(
                    onExportCSV: { closeMenuThen { exportCSV() } },
                    onRestoreCSV: { closeMenuThen { showCSVRestoreImporter = true } },
                    onImportLegacy: { closeMenuThen { showLegacyImporter = true } },
                    onImgurSettings: { closeMenuThen { showImgurSettings = true } },
                    onGenerateLabels: { closeMenuThen { showLabelPagePrompt = true } },
                    onDeleteAll: { closeMenuThen { showDeleteAllWarning1 = true } }
                ).environment(store)
                .frame(minWidth: 260)
            }

            if showFilterButton {
                Button {
                    onFilterTap()
                } label: {
                    Image(systemName: isFilterActive
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Filter")
            }

            HStack {
                Image(systemName: "magnifyingglass")
                HStack {
                    TextField("Search Items, SKUs, or Tags...", text: $searchDraft)
                        .focused($isSearchFocused)
                        .textFieldStyle(.plain)
                        .onChange(of: searchDraft) { _, newValue in
                            searchDebounceTask?.cancel()
                            searchDebounceTask = Task {
                                try? await Task.sleep(nanoseconds: 150_000_000)
                                guard !Task.isCancelled else { return }
                                store.searchText = newValue
                            }
                        }
                    Button {
                        searchDebounceTask?.cancel()
                        searchDraft = ""
                        store.searchText = ""
                    } label: {
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
        .onAppear { searchDraft = store.searchText }
        .sheet(isPresented: $showScanner) {
            QRScannerView(
                onCode: { code in
                    searchDebounceTask?.cancel()
                    searchDraft = code
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
        // MARK: Label Prompt and Automated Handling
        .alert("Generate Amazon Labels", isPresented: $showLabelPagePrompt) {
            TextField("Number of Pages", text: $labelPageCountString)
                .keyboardType(.numberPad)
            
            Button("Cancel", role: .cancel) { }
            Button("Generate", action: handleLabelGenerationAction) // <-- CLEANED UP: Moved long logic to external helper function below
        } message: {
            Text("Enter how many 20-label matrix pages (4x6 format) you want to generate.")
        }
        .sheet(item: $generatedLabelsURL) { url in
            ShareSheetWrapper(activityItems: [url])
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

    // MARK: - Isolated Helper Functions

    /// Separating this complex logic into an independent function dramatically relieves SwiftUI compiler type-checking bottlenecks.
    private func handleLabelGenerationAction() {
        let cleanCount = Int(labelPageCountString) ?? 1
        let pdfDoc = LabelGenerator.generateLabels(totalPages: cleanCount, logoImageName: "cataloger-reverse")
        
        let isMac = ProcessInfo.processInfo.isMacCatalystApp || ProcessInfo.processInfo.isiOSAppOnMac
        
        if isMac {
            print("🚀 MAC RUNTIME DETECTED: Triggering Direct Print Panel.")
            LabelGenerator.printDirectly(pdfDocument: pdfDoc, jobName: "Amazon Thermal Labels")
        } else {
            print("📱 MOBILE RUNTIME DETECTED: Opening Share Sheet wrapper.")
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("AmazonLabels.pdf")
            do {
                try pdfDoc.dataRepresentation()?.write(to: tempURL)
                self.generatedLabelsURL = tempURL
            } catch {
                store.lastError = error.localizedDescription
            }
        }
    }

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
    @Environment(AppStore.self) private var store
    var onExportCSV: () -> Void
    var onRestoreCSV: () -> Void
    var onImportLegacy: () -> Void
    var onImgurSettings: () -> Void
    var onGenerateLabels: () -> Void // <-- ADDED for qrcode labels
    var onDeleteAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Button("Imgur Account Settings", systemImage: "person.crop.circle", action: onImgurSettings)
            Divider()
            Button("Generate Amazon Labels", systemImage: "printer", action: onGenerateLabels)
            Divider()
            Button("Export to .csv (readable file)", systemImage: "square.and.arrow.up", action: onExportCSV)
            Divider()
            Button("Restore from Backup (.csv)", systemImage: "arrow.clockwise.icloud", action: onRestoreCSV)
            Button("Import Legacy .mcs File", systemImage: "tray.and.arrow.down", action: onImportLegacy)
            Divider()
            Toggle(isOn: Binding(
                          get: { store.preloadAllImages },
                          set: { store.preloadAllImages = $0 }
                      )) {
                          Label("Preload All Images in List", systemImage: "photo.stack")
                      }
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

// Extends URL to work natively with SwiftUI .sheet(item:) mechanics
extension URL: Identifiable {
    public var id: String { self.absoluteString }
}

// Bridges UIKit UIActivityViewController cleanly into SwiftUI layouts
struct ShareSheetWrapper: UIViewControllerRepresentable {
    let activityItems: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        return UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
