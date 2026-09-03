import SwiftUI
import PhotosUI
import UIKit

struct ItemAddView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var asset: Asset
    @FocusState private var focusedField: AssetField?
    @State private var showScanner = false
    @State private var showQRConflictAlert = false
    @State private var newTagText = ""
    @State private var photoPickerItem: PhotosPickerItem?
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

                    TextField("Container Location", text: $asset.containerLocation)
                        .focused($focusedField, equals: .container)
                        .onSubmit { focusedField = .qrScan }
                }

                Section("QR Label") {
                    Button {
                        showScanner = true
                    } label: {
                        HStack {
                            Text(asset.qrLabelDisplayText)
                            Spacer()
                            Image(systemName: "qrcode.viewfinder")
                        }
                    }
                    .focused($focusedField, equals: .qrScan)
                }

                Section("Photo") {
                    Button {
                        showCamera = true
                    } label: {
                        Label("Take Photo", systemImage: "camera")
                    }
                    .focused($focusedField, equals: .image)
                    .disabled(isUploadingImage)

                    PhotosPicker("Choose from Library", selection: $photoPickerItem, matching: .images)
                        .disabled(isUploadingImage)

                    if isUploadingImage {
                        ProgressView("Uploading...")
                    }
                }
            }
            .navigationTitle("New Item")
            .onAppear { focusedField = .name } // rapid-onboarding: focus Name on launch
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .focused($focusedField, equals: .save)
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
            .onChange(of: photoPickerItem) { _, newItem in
                guard let newItem else { return }
                Task { await handlePickedPhoto(newItem) }
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
            photoPickerItem = nil
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

    private func handlePickedPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }
        await handleCapturedPhoto(image)
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
