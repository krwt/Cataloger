import SwiftUI
import PhotosUI
import UIKit

/// Shared field-focus order used by both the Detail and Add views so
/// Tab-cycling behaves identically across both.
enum AssetField: Hashable {
    case name, description, container, qrScan, image, save
}

struct ItemDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State var asset: Asset
    @FocusState private var focusedField: AssetField?
    @State private var showScanner = false
    @State private var showQRConflictAlert = false
    @State private var showDeleteConfirm = false
    @State private var deleteConfirmArmed = false
    @State private var newTagText = ""
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var isUploadingImage = false

    var body: some View {
        Form {
            Section {
                TextField("Item Name", text: $asset.name)
                    .focused($focusedField, equals: .name)
                    .onSubmit { focusedField = .description }

                TextField("Description", text: $asset.itemDescription, axis: .vertical)
                    .lineLimit(3...8)
                    .focused($focusedField, equals: .description)
                    .onSubmit { focusedField = .container }

                TextField("Container Location", text: $asset.containerLocation)
                    .focused($focusedField, equals: .container)
                    .onSubmit { focusedField = .qrScan }

                Toggle("Checked Out", isOn: $asset.isCheckedOut)
            }

            Section("Tags") {
                TagCloudView(tags: $asset.tags)
                HStack {
                    TextField("Add tag", text: $newTagText)
                    Button("Add") {
                        let tag = Asset.normalizeTag(newTagText)
                        if !tag.isEmpty && !asset.tags.contains(where: { Asset.normalizeTag($0) == tag }) {
                            asset.tags.append(tag)
                        }
                        newTagText = ""
                    }
                }
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
                ThumbnailView(asset: asset)
                    .frame(height: 160)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

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
        .navigationTitle(asset.name.isEmpty ? "New Item" : asset.name)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .destructiveAction) {
                Button("Delete", role: .destructive) { showDeleteConfirm = true }
                    .foregroundStyle(.red)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .focused($focusedField, equals: .save)
                    .keyboardShortcut("s", modifiers: .command)
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
        .alert("QR Code Already Assigned", isPresented: $showQRConflictAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("That code is already linked to another item. Scan a different label.")
        }
        .confirmationDialog(
            "Delete this item? This cannot be undone.",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    await store.delete(assetID: asset.id)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: photoPickerItem) { _, newItem in
            guard let newItem else { return }
            Task { await handlePickedPhoto(newItem) }
        }
        // Cmd+Delete secure deletion shortcut, confirmed via Tab-to-highlight or a second Cmd+Delete.
        .onKeyPress(.delete, phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            if showDeleteConfirm && deleteConfirmArmed {
                Task {
                    await store.delete(assetID: asset.id)
                    dismiss()
                }
                return .handled
            }
            showDeleteConfirm = true
            deleteConfirmArmed = true
            return .handled
        }
    }

    private func save() {
        Task {
            let saved = await store.save(asset)
            asset = saved
            dismiss()
        }
    }

    private func handleScannedCode(_ code: String) {
        showScanner = false
        if let conflict = store.assetOwningQRCode(code, excluding: asset.id), conflict.id != asset.id {
            // Reject: clear any partial value and warn, per spec.
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

/// Tag cloud with wrapping capsules and per-tag delete (xmark).
struct TagCloudView: View {
    @Binding var tags: [String]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                HStack(spacing: 4) {
                    Text(tag).font(.caption)
                    Button {
                        tags.removeAll { $0 == tag }
                    } label: {
                        Image(systemName: "xmark").font(.caption2)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.15))
                .clipShape(Capsule())
            }
        }
    }
}

/// Minimal wrapping flow layout for tag capsules.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
