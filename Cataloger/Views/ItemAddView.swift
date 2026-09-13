import SwiftUI
import UIKit

struct ItemAddView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var asset: Asset
    @FocusState private var focusedField: AssetField?
    @State private var showScanner = false
    @State private var showQRConflictAlert = false
    @State private var showCamera = false
    @State private var isUploadingImage = false
    @State private var showDuplicateDetail: Asset?
    @State private var showSavedConfirmation = false

    init(prefillName: String = "") {
        _asset = State(initialValue: Asset(name: prefillName))
    }

    private var duplicateMatches: [Asset] {
        store.nameMatches(asset.name)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Item Name", text: $asset.name)
                        .focused($focusedField, equals: .name)
                        .onSubmit { focusedField = .description }
                        .focusBorder(focusedField == .name)

                    if !duplicateMatches.isEmpty {
                        ForEach(duplicateMatches) { match in
                            Button {
                                showDuplicateDetail = match
                            } label: {
                                Label("Possible duplicate: \(match.name)", systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }

                    TextField("Description", text: $asset.itemDescription, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($focusedField, equals: .description)
                        .onSubmit { focusedField = .container }
                        .onChange(of: asset.itemDescription) { _, newValue in
                            // Hardware Tab inserts a literal tab character
                            // into multi-line TextFields instead of moving
                            // focus. Strip it and advance manually.
                            if newValue.contains("\t") {
                                asset.itemDescription = newValue.replacingOccurrences(of: "\t", with: "")
                                focusedField = .container
                            }
                        }
                        .focusBorder(focusedField == .description)

                    TextField("Container Location", text: $asset.containerLocation)
                        .focused($focusedField, equals: .container)
                        // Container is the last field bound to
                        // `focusedField`. It deliberately does NOT set
                        // focus to `.qrScan` anymore — that's a plain
                        // Button, so assigning it just nils focus out.
                        // Return commits the item; Tab falls through to
                        // the tag field natively.
                        .onSubmit { save() }
                        .onChange(of: asset.containerLocation) { _, newValue in
                            if newValue.contains("\t") {
                                asset.containerLocation = newValue.replacingOccurrences(of: "\t", with: "")
                            }
                        }
                        .focusBorder(focusedField == .container)
                }

                TagEditorSection(tags: $asset.tags)

                Section("QR Label") {
                    Button {
                        showScanner = true
                    } label: {
                        HStack {
                            Text(asset.qrLabelDisplayText)
                            Spacer()
                            Image(systemName: "qrcode.viewfinder")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    // No `.focused(...)` — a plain Button can't take
                    // keyboard focus on iOS, so binding one here just
                    // created an AssetField value nothing could hold.
                    // Reachable via Cmd+1 instead.
                }

                Section("Photo") {
                    Button {
                        showCamera = true
                    } label: {
                        Label("Take Photo", systemImage: "camera")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // Reachable via Cmd+2 — see note on the QR button above.
                    .disabled(isUploadingImage)

                    if isUploadingImage {
                        ProgressView("Uploading...")
                    }
                }
            }
            .navigationTitle("New Item")
            .onAppear { focusedField = .name } // rapid-onboarding: focus Name on launch
            .onChange(of: focusedField) { oldValue, newValue in
                print("🔎 focusedField: \(String(describing: oldValue)) -> \(String(describing: newValue))")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(asset.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .overlay(alignment: .top) {
                if showSavedConfirmation {
                    Text("Saved — ready for next item")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.green.opacity(0.9), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .sheet(isPresented: $showScanner) {
                QRScannerView(onCode: handleScannedCode, onCancel: { showScanner = false })
                    .ignoresSafeArea()
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraCaptureView(
                    onCapture: { image in
                        showCamera = false
                        Task { await handleCapturedPhoto(image) }
                    },
                    onCancel: { showCamera = false }
                )
                .ignoresSafeArea()
            }
            .sheet(item: $showDuplicateDetail) { existing in
                NavigationStack { ItemDetailView(asset: existing) }
            }
            .alert("QR Code Already Assigned", isPresented: $showQRConflictAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("That code is already linked to another item. Scan a different label.")
            }
            // MARK: Keyboard actions for the button-based fields.
            //
            // These used to be `.onKeyPress(.tab)` / `.onKeyPress(.return)`
            // handlers that switched on `focusedField == .qrScan / .image
            // / .save`. That approach can't work here: all three are
            // `.buttonStyle(.plain)` Buttons, which aren't keyboard-
            // focusable on iOS, so `focusedField` never actually holds
            // those values. Tab out of Container goes to the *next
            // focusable view* (the tag field), and `focusedField` nils
            // out — confirmed by the "container -> nil" focus log.
            //
            // Hidden Button + `.keyboardShortcut` is the one mechanism
            // that works window-wide regardless of what currently holds
            // focus — the same pattern already used for Cmd+F in
            // ItemListView. Save keeps its existing Cmd+S.
            .background {
                VStack {
                    Button("") { showScanner = true }
                        .keyboardShortcut("1", modifiers: .command)
                    Button("") { showCamera = true }
                        .keyboardShortcut("2", modifiers: .command)
                        .disabled(isUploadingImage)
                }
                .opacity(0)
            }
        }
    }

    /// Saves the current item, then — matching v1's batch-entry workflow —
    /// keeps the sheet open and clears everything except Container Location,
    /// since items are usually added in batches to the same shelf/bin.
    private func save() {
        Task {
            _ = await store.save(asset)

            let keptContainer = asset.containerLocation
            withAnimation { showSavedConfirmation = true }

            asset = Asset(name: "", containerLocation: keptContainer)
            focusedField = .name

            try? await Task.sleep(nanoseconds: 1_200_000_000)
            withAnimation { showSavedConfirmation = false }
        }
    }

    private func handleScannedCode(_ code: String) {
        showScanner = false
        if store.assetOwningQRCode(code, excluding: asset.id) != nil {
            showQRConflictAlert = true
            return
        }
        asset.qrcodeUUID = code
    }

    private func handleCapturedPhoto(_ image: UIImage) async {
        isUploadingImage = true
        defer { isUploadingImage = false }
        let imgurURL = await ImageStore.dualUpload(
            image: image,
            assetID: asset.id,
            title: asset.name,
            description: asset.itemDescription
        )
        asset.imgurURLString = imgurURL
    }
}

private extension View {
    /// Thin green border indicating this control currently has keyboard focus.
    func focusBorder(_ isActive: Bool) -> some View {
        padding(6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isActive ? Color.green : Color.clear, lineWidth: 1.5)
            )
    }
}
