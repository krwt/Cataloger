import SwiftUI
import UIKit

/// `UIScrollView`-backed zoom, used by the full-screen image preview.
///
/// Replaces a SwiftUI `.scaleEffect` implementation that looked blurry when
/// zoomed. `.scaleEffect` is a geometry transform applied to an already-
/// rendered layer: SwiftUI rasterizes the image at its laid-out size (roughly
/// screen width) and then magnifies *that bitmap*, so at 3x you're looking at
/// a screen-resolution raster blown up 3x — the full-resolution pixels in the
/// decoded image are never used.
///
/// A `UIImageView` holding the full `UIImage` keeps the original `CGImage` as
/// its layer contents, so zooming samples from the full-resolution source and
/// stays sharp up to the image's native resolution. `UIScrollView` also
/// provides momentum panning, rubber-banding, and correct bounds for free,
/// replacing hand-rolled offset clamping.
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> ZoomableScrollView {
        let scrollView = ZoomableScrollView()
        scrollView.setImage(image)
        return scrollView
    }

    func updateUIView(_ uiView: ZoomableScrollView, context: Context) {
        // Only reset when the image actually changed (e.g. the source toggle
        // switched between the local and Imgur copies) — otherwise every
        // SwiftUI update would yank the user's zoom back to fit.
        if uiView.imageView.image !== image {
            uiView.setImage(image)
        }
    }
}

final class ZoomableScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    private var lastBoundsSize: CGSize = .zero
    private let doubleTapScale: CGFloat = 3

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 6
        bouncesZoom = true
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        backgroundColor = .black
        // The preview is full-bleed behind the status bar; without this the
        // image gets nudged by safe-area insets and won't center properly.
        contentInsetAdjustmentBehavior = .never

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // SwiftUI can report a zero-size bounds on first pass, so layout is
        // driven from here rather than from makeUIView.
        if bounds.size != lastBoundsSize {
            lastBoundsSize = bounds.size
            resetLayout()
        }
        centerImage()
    }

    func setImage(_ image: UIImage?) {
        imageView.image = image
        resetLayout()
    }

    private func resetLayout() {
        guard bounds.size != .zero else { return }
        zoomScale = 1
        imageView.frame = CGRect(origin: .zero, size: bounds.size)
        contentSize = bounds.size
        centerImage()
    }

    /// Keeps the image centered when it's smaller than the viewport, rather
    /// than pinned to the top-left corner as a scroll view would by default.
    private func centerImage() {
        let horizontal = max((bounds.width - contentSize.width) / 2, 0)
        let vertical = max((bounds.height - contentSize.height) / 2, 0)
        contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    // MARK: - UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }

    // MARK: - Double tap

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            // Zoom toward the tapped point rather than the center, so
            // double-tapping a detail brings that detail into view.
            let point = gesture.location(in: imageView)
            let size = CGSize(width: bounds.width / doubleTapScale, height: bounds.height / doubleTapScale)
            let rect = CGRect(
                x: point.x - size.width / 2,
                y: point.y - size.height / 2,
                width: size.width,
                height: size.height
            )
            zoom(to: rect, animated: true)
        }
    }
}
