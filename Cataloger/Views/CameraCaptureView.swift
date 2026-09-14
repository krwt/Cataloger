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
    }

    @objc private func retakeTapped() {
        pendingImage = nil
        reviewImageView.image = nil
        reviewImageView.isHidden = true
        retakeButton.isHidden = true
        useButton.isHidden = true
        shutterButton.isHidden = false
        cancelButton.isHidden = false
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
