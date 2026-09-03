import SwiftUI

struct ItemRowView: View {
    let asset: Asset
    @Environment(AppStore.self) private var store
    @State private var showImagePreview = false

    var body: some View {
        HStack(spacing: 12) {
            Button {
                showImagePreview = true
            } label: {
                ThumbnailView(asset: asset)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain) // tapping the thumbnail must NOT trigger row navigation

            VStack(alignment: .leading, spacing: 2) {
                Text(asset.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.primary)
                Text(asset.itemDescription)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                Text(asset.containerLocation)
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
            }

            Spacer()

            // One-tap checkout toggle — its own tap zone, separate from the
            // row's tap-to-open-detail gesture, same pattern as the
            // thumbnail's own tap zone above.
            Button {
                Task { await store.batchToggleCheckout(ids: [asset.id]) }
            } label: {
                Text(asset.isCheckedOut ? "Checked Out" : "Check Out")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(asset.isCheckedOut ? Color.orange.opacity(0.2) : Color.secondary.opacity(0.12))
                    .foregroundStyle(asset.isCheckedOut ? Color.orange : Color.secondary)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .sheet(isPresented: $showImagePreview) {
            FullScreenImagePreview(asset: asset)
        }
    }
}

/// Hybrid Imgur-primary / local-fallback thumbnail per the v1 image pipeline.
struct ThumbnailView: View {
    let asset: Asset
    @State private var localImage: UIImage?

    var body: some View {
        Group {
            if let urlString = asset.imgurURLString, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .failure:
                        fallbackOrPlaceholder
                    case .empty:
                        ProgressView()
                    @unknown default:
                        fallbackOrPlaceholder
                    }
                }
            } else {
                fallbackOrPlaceholder
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    @ViewBuilder
    private var fallbackOrPlaceholder: some View {
        if let data = ImageStore.loadLocalImage(assetID: asset.id), let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage).resizable().aspectRatio(contentMode: .fill)
        } else {
            Image(systemName: "shippingbox")
                .foregroundStyle(Color.secondary)
        }
    }
}

struct FullScreenImagePreview: View {
    let asset: Asset
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            ThumbnailView(asset: asset)
                .aspectRatio(contentMode: .fit)
                .padding()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(.white)
            }
            .padding()
        }
    }
}
