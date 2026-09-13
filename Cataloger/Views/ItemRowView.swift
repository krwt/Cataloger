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
            Image(systemName: "photo")
                .foregroundStyle(Color.secondary)
        } else {
            Image(systemName: "questionmark")
                .foregroundStyle(Color.secondary)
        }
    }
}

/// Full-screen image viewer with pinch-to-zoom, pan, and double-tap.
/// Shared by the list row thumbnail and the detail view's photo.
struct FullScreenImagePreview: View {
    let asset: Asset
    @Environment(\.dismiss) private var dismiss

    /// Committed zoom/pan, updated when a gesture ends.
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    /// Live gesture values. `@GestureState` auto-resets when the gesture
    /// ends, so the in-progress transform is kept separate from the
    /// committed one rather than being written on every delta.
    @GestureState private var pinchScale: CGFloat = 1
    @GestureState private var dragTranslation: CGSize = .zero

    private let minScale: CGFloat = 1
    private let maxScale: CGFloat = 6
    private let doubleTapScale: CGFloat = 3

    private var effectiveScale: CGFloat {
        min(max(scale * pinchScale, minScale), maxScale)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                Color.black.ignoresSafeArea()

                ThumbnailView(asset: asset)
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(effectiveScale)
                    .offset(
                        x: offset.width + dragTranslation.width,
                        y: offset.height + dragTranslation.height
                    )
                    .gesture(magnifyGesture(in: geo.size))
                    // Simultaneous so pinching and repositioning can happen
                    // in one continuous motion instead of requiring the
                    // user to lift and start over.
                    .simultaneousGesture(dragGesture(in: geo.size))
                    .onTapGesture(count: 2) { toggleZoom(in: geo.size) }
                    .animation(.interactiveSpring, value: scale)
                    .animation(.interactiveSpring, value: offset)

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                        .foregroundStyle(.white)
                        .shadow(radius: 3)
                }
                .padding()
            }
        }
    }

    private func magnifyGesture(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .updating($pinchScale) { value, state, _ in
                state = value.magnification
            }
            .onEnded { value in
                scale = min(max(scale * value.magnification, minScale), maxScale)
                // Zooming back out re-centers, so the image can't be left
                // parked off-screen at 1x with no way to bring it back.
                offset = scale <= minScale ? .zero : clamped(offset, scale: scale, in: size)
            }
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture()
            .updating($dragTranslation) { value, state, _ in
                // Only pan when actually zoomed in — otherwise dragging a
                // fit-to-screen image just slides it around pointlessly.
                guard scale > minScale else { return }
                state = value.translation
            }
            .onEnded { value in
                guard scale > minScale else { return }
                offset = clamped(
                    CGSize(
                        width: offset.width + value.translation.width,
                        height: offset.height + value.translation.height
                    ),
                    scale: scale,
                    in: size
                )
            }
    }

    private func toggleZoom(in size: CGSize) {
        if scale > minScale {
            scale = minScale
            offset = .zero
        } else {
            scale = doubleTapScale
        }
    }

    /// Keeps the image from being dragged past its own edges, so you can't
    /// fling it into empty space and lose it.
    private func clamped(_ proposed: CGSize, scale: CGFloat, in size: CGSize) -> CGSize {
        let maxX = max((size.width * (scale - 1)) / 2, 0)
        let maxY = max((size.height * (scale - 1)) / 2, 0)
        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }
}
