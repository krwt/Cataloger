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
                ThumbnailView(asset: asset, allowRemoteLoad: store.preloadAllImages)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain) // tapping the thumbnail must NOT trigger row navigation

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(asset.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if !asset.containerLocation.isEmpty {
                        Text(asset.containerLocation)
                            .font(.body.weight(.medium))
                            .foregroundStyle(Color.primary)
                            .lineLimit(1)
                    }
                }
                if !asset.itemDescription.isEmpty {
                    Text(asset.itemDescription)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }
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
    /// When false, skips the network fetch entirely and shows the local
    /// cache or placeholder instead — used by list rows (opt-in via the
    /// "Preload All Images" setting) since fetching every row's remote
    /// image as it scrolls into view can be a lot of network activity for
    /// a large collection. Detail view and the full-screen preview always
    /// pass `true` (the default) since those are explicit navigations
    /// where showing the real image is expected.
    var allowRemoteLoad: Bool = true
    /// When false, a failed remote load shows an explicit "unavailable"
    /// state instead of quietly substituting the local copy. The preview's
    /// source toggle needs this: silently falling back would make the two
    /// options look identical even when Imgur is unreachable, which defeats
    /// the point of comparing them.
    var allowsFallback: Bool = true
    @State private var localImage: UIImage?
    /// Distinguishes "haven't looked on disk yet" from "looked, found
    /// nothing" — without it the placeholder can't tell whether to keep
    /// waiting or show the final fallback icon.
    @State private var didAttemptLocalLoad = false

    var body: some View {
        Group {
            if allowRemoteLoad, let urlString = asset.imgurURLString, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .failure:
                        if allowsFallback { fallbackOrPlaceholder } else { unavailablePlaceholder }
                    case .empty:
                        ProgressView()
                    @unknown default:
                        if allowsFallback { fallbackOrPlaceholder } else { unavailablePlaceholder }
                    }
                }
            } else {
                fallbackOrPlaceholder
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        // Loads the local HEIC copy off the main thread. This used to be a
        // synchronous `Data(contentsOf:)` + `UIImage(data:)` call directly
        // inside `fallbackOrPlaceholder` — i.e. blocking disk I/O and an
        // image decode running in a view body, once per row, on every
        // render pass. Combined with the (previously uncached) iCloud
        // container lookup behind `ImageStore.localURL`, that's what made
        // typing stall and the keyboard freeze.
        .task(id: asset.id) {
            if let cached = ImageStore.cachedImage(assetID: asset.id) {
                localImage = cached
                didAttemptLocalLoad = true
                return
            }
            localImage = await ImageStore.loadImage(assetID: asset.id)
            didAttemptLocalLoad = true
        }
    }

    /// Shown when the requested source specifically can't be displayed and
    /// substituting the other one would be misleading.
    @ViewBuilder
    private var unavailablePlaceholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
            Text("Not available from this source")
                .font(.caption2)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(Color.secondary)
        .padding(8)
    }

    @ViewBuilder
    private var fallbackOrPlaceholder: some View {
        if let localImage {
            Image(uiImage: localImage).resizable().aspectRatio(contentMode: .fill)
        } else if !didAttemptLocalLoad {
            // Still reading from disk — show neutral empty space rather
            // than flashing the "no image" icon and then replacing it.
            Color.clear
        } else if let urlString = asset.imgurURLString, !urlString.isEmpty {
            // The item does have an image — it just isn't showing right now
            // (network issue, or preload-off skipped fetching it). Distinct
            // from "no image was ever attached" below.
            if allowsFallback {
                Image(systemName: "photo")
                    .foregroundStyle(Color.secondary)
            } else {
                // Local source was explicitly requested and there's no local
                // copy — say so rather than showing a generic photo icon.
                unavailablePlaceholder
            }
        } else {
            Image(systemName: "questionmark")
                .foregroundStyle(Color.secondary)
        }
    }
}

/// Full-screen image viewer with zoom, and a toggle between the two stored
/// copies of the photo.
struct FullScreenImagePreview: View {
    let asset: Asset
    @Environment(\.dismiss) private var dismiss

    /// Which copy is being displayed. The two are encoded differently —
    /// local is HEIC at 0.8, Imgur is JPEG at 0.8 — so they don't look
    /// identical, and flipping between them makes it possible to check that
    /// an upload landed and how it fared.
    @State private var useRemoteSource = true
    @State private var hasLocalCopy = false
    @State private var image: UIImage?
    @State private var isLoading = true

    private var hasRemoteCopy: Bool {
        !(asset.imgurURLString ?? "").isEmpty
    }

    /// Only worth showing when there are genuinely two sources to switch
    /// between.
    private var canToggleSource: Bool {
        hasRemoteCopy && hasLocalCopy
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            if let image {
                // Full-resolution UIImage handed to UIScrollView, so zooming
                // samples the original pixels instead of magnifying a
                // screen-sized raster the way .scaleEffect did.
                ZoomableImageView(image: image)
                    .ignoresSafeArea()
            } else if isLoading {
                ProgressView()
                    .tint(.white)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("Not available from this source")
                        .font(.callout)
                }
                .foregroundStyle(.secondary)
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(.white)
                    .shadow(radius: 3)
            }
            .padding()

            if canToggleSource {
                VStack {
                    Spacer()
                    Picker("Image source", selection: $useRemoteSource) {
                        Text("Local (HEIC)").tag(false)
                        Text("Imgur (JPEG)").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 280)
                    .padding(.bottom, 24)
                }
            }
        }
        .task {
            hasLocalCopy = await ImageStore.hasLocalCopy(assetID: asset.id)
            // Nothing on Imgur — start on the copy that exists rather than
            // showing an error state first.
            if !hasRemoteCopy { useRemoteSource = false }
            await loadImage()
        }
        .onChange(of: useRemoteSource) { _, _ in
            Task { await loadImage() }
        }
    }

    private func loadImage() async {
        isLoading = true
        defer { isLoading = false }

        if useRemoteSource, let urlString = asset.imgurURLString, !urlString.isEmpty {
            image = await ImageStore.loadRemoteImage(urlString: urlString)
        } else {
            image = await ImageStore.loadImage(assetID: asset.id)
        }
    }
}
