import SwiftUI
import UIKit
import AVFoundation

/// Native photo capture built on `AVCapturePhotoOutput`.
///
/// Replaces the previous `UIImagePickerController` implementation. That API
/// works fine on iPhone, where `sourceType = .camera` drives the real photo
/// pipeline and `info[.originalImage]` is a full-resolution still. But when an
/// iPad app runs on macOS there's no native camera, so the picker routes to
/// Continuity Camera operating as a *video* device — and returned 640×480
/// stills, roughly 1/40th the pixels of an iPhone capture. No compression
/// setting can recover from that; the pixels were never captured.
///
/// `AVCaptureSession` with `sessionPreset = .photo` plus an explicit
/// `maxPhotoDimensions` request asks the device for its still-image
/// resolution instead of accepting a video-grade default.
///
/// Keeps the same `onCapture` / `onCancel` interface as before, so
/// `ItemAddView` and `ItemDetailView` need no changes.
struct CameraCaptureView: UIViewControllerRepresentable {
    var onCapture: (UIImage) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> CameraCaptureController {
        let controller = CameraCaptureController()
        controller.onCapture = onCapture
        controller.onCancel = onCancel
        return controller
    }

    func updateUIViewController(_ uiViewController: CameraCaptureController, context: Context) {}
}

final class CameraCaptureController: UIViewController, AVCapturePhotoCaptureDelegate {
    var onCapture: ((UIImage) -> Void)?
    var onCancel: (() -> Void)?

    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var captureDevice: AVCaptureDevice?
    private var hasCaptured = false

    private let shutterButton = UIButton(type: .custom)
    private let cancelButton = UIButton(type: .system)
    private let statusLabel = UILabel()

    // Review step — shown after the shutter fires so the photo can be
    // checked before it's committed. UIImagePickerController provided this
    // for free; building on AVCapture means providing it explicitly.
    private let hintLabel = UILabel()
    private let reviewImageView = UIImageView()
    private let retakeButton = UIButton(type: .system)
    private let useButton = UIButton(type: .system)
    private var pendingImage: UIImage?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
        configureControls()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [session] in
                session.startRunning()
            }
        }
        // Key commands are only delivered to the first responder.
        becomeFirstResponder()
    }

    // MARK: - Keyboard

    override var canBecomeFirstResponder: Bool { true }

    /// Return and Escape are context-sensitive: they act on the shutter while
    /// the preview is live, and on the review buttons once a photo is taken.
    /// Two keys covering four actions, matching what the on-screen buttons
    /// show at that moment.
    override var keyCommands: [UIKeyCommand]? {
        let isReviewing = pendingImage != nil

        let returnCommand = UIKeyCommand(
            title: isReviewing ? "Use Photo" : "Take Photo",
            action: #selector(returnKeyPressed),
            input: "\r"
        )
        let escapeCommand = UIKeyCommand(
            title: isReviewing ? "Retake" : "Cancel",
            action: #selector(escapeKeyPressed),
            input: UIKeyCommand.inputEscape
        )
        // Without this the system can claim these first — Escape in
        // particular is used to dismiss presented content.
        returnCommand.wantsPriorityOverSystemBehavior = true
        escapeCommand.wantsPriorityOverSystemBehavior = true
        return [returnCommand, escapeCommand]
    }

    @objc private func returnKeyPressed() {
        if pendingImage != nil {
            useTapped()
        } else {
            captureTapped()
        }
    }

    @objc private func escapeKeyPressed() {
        if pendingImage != nil {
            retakeTapped()
        } else {
            cancelTapped()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning { session.stopRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.layer.bounds
    }

    // MARK: - Session

    /// Picks the best available capture device.
    ///
    /// `AVCaptureDevice.default(for: .video)` is enough on iPhone, but on Mac
    /// the Continuity Camera shows up as an external/continuity device type,
    /// so those are included explicitly rather than relying on the default.
    private func bestAvailableDevice() -> AVCaptureDevice? {
        var deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(iOS 17.0, *) {
            deviceTypes.append(contentsOf: [.external, .continuityCamera])
        }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.first ?? AVCaptureDevice.default(for: .video)
    }

    private func configureSession() {
        session.beginConfiguration()

        // `.photo` requests the device's still-image resolution rather than a
        // video preset. This is the single most important line here — it's
        // what the UIImagePickerController path was effectively missing.
        if session.canSetSessionPreset(.photo) {
            session.sessionPreset = .photo
        } else {
            session.sessionPreset = .high
        }

        guard let device = bestAvailableDevice(),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            showStatus("No camera available")
            return
        }
        captureDevice = device
        session.addInput(input)

        guard session.canAddOutput(photoOutput) else {
            session.commitConfiguration()
            showStatus("Camera output unavailable")
            return
        }
        session.addOutput(photoOutput)

        // Explicitly request the largest still the active format supports.
        // Without this the output defaults to a smaller dimension even when
        // the device can do better.
        if #available(iOS 16.0, *) {
            let supported = device.activeFormat.supportedMaxPhotoDimensions
            if let largest = supported.max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
                photoOutput.maxPhotoDimensions = largest
                print("📐 Max photo dimensions available: \(largest.width) × \(largest.height)")
            }
        }

        session.commitConfiguration()

        // Continuity Camera sometimes starts at a non-1x zoom/crop factor,
        // making the preview look cropped in. Same workaround as QRScannerView.
        if device.videoZoomFactor != device.minAvailableVideoZoomFactor {
            try? device.lockForConfiguration()
            device.videoZoomFactor = device.minAvailableVideoZoomFactor
            device.unlockForConfiguration()
        }

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.layer.bounds
        preview.correctGeometryForHost(device: device)
        view.layer.insertSublayer(preview, at: 0)
        previewLayer = preview
    }

    // MARK: - Controls

    private func configureControls() {
        shutterButton.translatesAutoresizingMaskIntoConstraints = false
        shutterButton.backgroundColor = .white
        shutterButton.layer.cornerRadius = 34
        shutterButton.layer.borderWidth = 4
        shutterButton.layer.borderColor = UIColor.white.withAlphaComponent(0.5).cgColor
        shutterButton.accessibilityLabel = "Take Photo"
        shutterButton.addTarget(self, action: #selector(captureTapped), for: .touchUpInside)
        view.addSubview(shutterButton)

        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.setTitleColor(.white, for: .normal)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        view.addSubview(cancelButton)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .white
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.isHidden = true
        view.addSubview(statusLabel)

        // Keyboard shortcuts are invisible otherwise. Shown only where a
        // hardware keyboard is a given, so it isn't clutter on iPhone.
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        hintLabel.font = .systemFont(ofSize: 12, weight: .medium)
        hintLabel.textAlignment = .center
        hintLabel.isHidden = !hasHardwareKeyboard
        view.addSubview(hintLabel)
        updateHint()

        reviewImageView.translatesAutoresizingMaskIntoConstraints = false
        reviewImageView.contentMode = .scaleAspectFit
        reviewImageView.backgroundColor = .black
        reviewImageView.isHidden = true
        view.addSubview(reviewImageView)

        retakeButton.translatesAutoresizingMaskIntoConstraints = false
        retakeButton.setTitle("Retake", for: .normal)
        retakeButton.setTitleColor(.white, for: .normal)
        retakeButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .medium)
        retakeButton.isHidden = true
        retakeButton.addTarget(self, action: #selector(retakeTapped), for: .touchUpInside)
        view.addSubview(retakeButton)

        useButton.translatesAutoresizingMaskIntoConstraints = false
        useButton.setTitle("Use Photo", for: .normal)
        useButton.setTitleColor(.white, for: .normal)
        useButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        useButton.isHidden = true
        useButton.addTarget(self, action: #selector(useTapped), for: .touchUpInside)
        view.addSubview(useButton)

        NSLayoutConstraint.activate([
            shutterButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            shutterButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -28),
            shutterButton.widthAnchor.constraint(equalToConstant: 68),
            shutterButton.heightAnchor.constraint(equalToConstant: 68),

            cancelButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            cancelButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),

            hintLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hintLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),

            reviewImageView.topAnchor.constraint(equalTo: view.topAnchor),
            reviewImageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            reviewImageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            reviewImageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            retakeButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            retakeButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -32),

            useButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            useButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -32)
        ])
    }

    private var hasHardwareKeyboard: Bool {
        ProcessInfo.processInfo.isiOSAppOnMac || ProcessInfo.processInfo.isMacCatalystApp
    }

    private func updateHint() {
        hintLabel.text = pendingImage == nil
            ? "⏎ Take Photo   ·   esc Cancel"
            : "⏎ Use Photo   ·   esc Retake"
    }

    private func showStatus(_ message: String) {
        statusLabel.text = message
        statusLabel.isHidden = false
        shutterButton.isHidden = true
    }

    @objc private func captureTapped() {
        guard !hasCaptured, session.isRunning else { return }

        var settings = AVCapturePhotoSettings()
        // HEVC where supported — better quality per byte than JPEG. The image
        // is decoded to a UIImage here either way, so this only affects the
        // intermediate representation.
        if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        }
        if #available(iOS 16.0, *) {
            settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        }
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    @objc private func cancelTapped() {
        session.stopRunning()
        onCancel?()
    }

    // MARK: - Capture delegate

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            print("⚠️ Photo capture failed: \(error?.localizedDescription ?? "no data")")
            onCancel?()
            return
        }
        print("📐 Captured: \(image.size.width * image.scale) × \(image.size.height * image.scale)")
        pendingImage = image
        showReview(image)
    }

    // MARK: - Review step

    private func showReview(_ image: UIImage) {
        // Freeze the live preview behind the still so the two can't be
        // confused for one another.
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.stopRunning()
        }
        reviewImageView.image = image
        reviewImageView.isHidden = false
        retakeButton.isHidden = false
        useButton.isHidden = false
        shutterButton.isHidden = true
        cancelButton.isHidden = true
        // Bring review chrome above the full-bleed image view.
        view.bringSubviewToFront(retakeButton)
        view.bringSubviewToFront(useButton)
        updateHint()
        view.bringSubviewToFront(hintLabel)
    }

    @objc private func retakeTapped() {
        pendingImage = nil
        reviewImageView.image = nil
        reviewImageView.isHidden = true
        retakeButton.isHidden = true
        useButton.isHidden = true
        shutterButton.isHidden = false
        cancelButton.isHidden = false
        updateHint()
        if !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [session] in
                session.startRunning()
            }
        }
    }

    @objc private func useTapped() {
        guard let image = pendingImage, !hasCaptured else { return }
        hasCaptured = true
        onCapture?(image)
    }
}

// MARK: - Shared camera helpers

/// Rotation the Mac preview needs, in degrees.
///
/// Determined by testing, not derived: the connection's own default leaves
/// the Continuity Camera feed turned, and 0/90/180 were each wrong in a
/// different way. There is no orientation signal available here to compute
/// this from — the Mac has no device orientation, and the phone's gyro
/// doesn't cross the Continuity link — so it's a fixed correction.
private let macPreviewRotationAngle: CGFloat = 270

/// True when this build is running on a Mac, where there's no device
/// rotation for the preview to track in the first place.
var isRunningOnMac: Bool {
    ProcessInfo.processInfo.isiOSAppOnMac || ProcessInfo.processInfo.isMacCatalystApp
}

extension AVCaptureVideoPreviewLayer {
    /// Fixes preview rotation and mirroring on Mac.
    ///
    /// Gated on the *host*, not the camera's device type — an earlier attempt
    /// keyed off `.continuityCamera` / `.external` and silently never ran,
    /// because the camera reports as neither.
    ///
    /// Only the preview is touched. The still image path is a separate
    /// connection and already produces correct output; forcing the two to
    /// agree is what broke handheld capture previously.
    func correctGeometryForHost(device: AVCaptureDevice) {
        guard #available(iOS 17.0, *), isRunningOnMac, let connection else { return }

        if connection.isVideoRotationAngleSupported(macPreviewRotationAngle) {
            connection.videoRotationAngle = macPreviewRotationAngle
        }

        // Continuity Camera previews arrive mirrored, like a selfie view.
        // That's right for a face and wrong for reading a label or a code,
        // and it breaks WYSIWYG since the still isn't mirrored.
        // `automaticallyAdjustsVideoMirroring` has to go first — while it's
        // on, `isVideoMirrored` is managed by the system and won't stick.
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }

        print("🔄 Preview: \(device.localizedName) → \(connection.videoRotationAngle)°, mirrored=\(connection.isVideoMirrored)")
    }
}

// MARK: - Presentation

extension View {
    /// Presents the camera windowed on Mac and full-screen everywhere else.
    ///
    /// A plain `.sheet` is windowed on Mac but renders as a page sheet on
    /// iPhone — inset card, drag-to-dismiss grabber, not edge to edge — which
    /// looks wrong for a camera. A plain `.fullScreenCover` is right on
    /// iPhone but takes over the entire display on Mac. This picks per
    /// platform, and applies the matching safe-area treatment: full-screen
    /// wants `.ignoresSafeArea()`, while a window needs the controls kept
    /// inside the visible card.
    func cameraPresentation<CameraContent: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> CameraContent
    ) -> some View {
        modifier(CameraPresentationModifier(isPresented: isPresented, cameraContent: content))
    }
}

private struct CameraPresentationModifier<CameraContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let cameraContent: () -> CameraContent

    /// Constant for the lifetime of the process, so branching on it doesn't
    /// cause view identity to churn.
    private var isWindowed: Bool {
        ProcessInfo.processInfo.isiOSAppOnMac || ProcessInfo.processInfo.isMacCatalystApp
    }

    func body(content: Content) -> some View {
        if isWindowed {
            content.sheet(isPresented: $isPresented) {
                cameraContent()
                    // Keeps the capture window usable rather than collapsing
                    // to the sheet's natural content-driven size.
                    .frame(minWidth: 480, minHeight: 640)
            }
        } else {
            content.fullScreenCover(isPresented: $isPresented) {
                cameraContent()
                    .ignoresSafeArea()
            }
        }
    }
}
