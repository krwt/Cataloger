import SwiftUI
import AVFoundation

/// A native, zero-dependency camera overlay that scans QR / barcode metadata
/// and returns the decoded string via `onCode`.
///
/// Like `CameraCaptureView`, this asks for a high-resolution feed explicitly
/// rather than accepting whatever `AVCaptureSession` defaults to. An
/// unconfigured session on Continuity Camera lands on a video-grade preset —
/// blurry preview, and small or distant codes that never resolve enough detail
/// to decode.
struct QRScannerView: UIViewControllerRepresentable {
    var onCode: (String) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let vc = ScannerViewController()
        vc.onCode = onCode
        vc.onCancel = onCancel
        return vc
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}
}

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasScanned = false
    private let statusLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .white
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.isHidden = true
        view.addSubview(statusLabel)

        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.setTitleColor(.white, for: .normal)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        view.addSubview(cancelButton)
        NSLayoutConstraint.activate([
            cancelButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            cancelButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() }
        }
        // Key commands are only delivered to the first responder.
        becomeFirstResponder()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning { session.stopRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Without this the preview keeps the bounds it had at configuration
        // time — which is the pre-layout size — and `resizeAspectFill` then
        // scales a mis-sized layer up, softening everything on screen.
        previewLayer?.frame = view.layer.bounds
    }

    // MARK: - Keyboard

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        let escape = UIKeyCommand(
            title: "Cancel",
            action: #selector(cancelTapped),
            input: UIKeyCommand.inputEscape
        )
        // Otherwise the system claims Escape to dismiss the presented sheet.
        escape.wantsPriorityOverSystemBehavior = true
        return [escape]
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

        guard let device = bestAvailableDevice(),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            showStatus("No camera available")
            return
        }
        session.addInput(input)

        // Preset selection has to happen *after* the input is attached.
        // `canSetSessionPreset` has no device to validate against on an empty
        // session and answers yes to almost anything, so asking first picks a
        // preset the camera can't actually deliver — Continuity Camera then
        // produces no frames at all and the preview stays black.
        //
        // 1080p is the ceiling here on purpose: it's already far more detail
        // than a code needs, and 4K costs real CPU when metadata detection is
        // running on every frame. `.photo` is left out too — detection reads
        // the video feed, and a photo preset can hand back a lower-rate
        // stream on some devices.
        let presets: [AVCaptureSession.Preset] = [.hd1920x1080, .high]
        if let preset = presets.first(where: { session.canSetSessionPreset($0) }) {
            session.sessionPreset = preset
        }

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            showStatus("Camera output unavailable")
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr, .ean13, .ean8, .code128, .upce, .pdf417]

        session.commitConfiguration()

        configure(device: device)

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = view.layer.bounds
        preview.videoGravity = .resizeAspectFill
        // Shared with CameraCaptureView — see `correctRotationForHost(device:)`.
        preview.correctRotationForHost(device: device)
        view.layer.insertSublayer(preview, at: 0)
        previewLayer = preview

        observeRuntimeErrors()
    }

    /// Device-level tuning, applied after `commitConfiguration` so the active
    /// format reflects the preset chosen above.
    private func configure(device: AVCaptureDevice) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }

        // Continuity Camera (iPad app running on Mac) sometimes starts at a
        // non-1x zoom/crop factor, making the preview look zoomed in.
        // Explicitly reset to the device's minimum zoom.
        if device.videoZoomFactor != device.minAvailableVideoZoomFactor {
            device.videoZoomFactor = device.minAvailableVideoZoomFactor
        }

        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        // Codes are held close to the lens, so restricting focus to the near
        // range stops the camera hunting out to infinity between frames. Only
        // for the built-in camera though: with Continuity Camera the phone is
        // across the desk and the code is held toward it at arm's length,
        // which can sit outside the near range entirely.
        if device.isAutoFocusRangeRestrictionSupported && !isRemoteCamera(device) {
            device.autoFocusRangeRestriction = .near
        }
        // Smooth autofocus ramps slowly — good for video, bad for locking onto
        // a barcode the moment it enters frame.
        if device.isSmoothAutoFocusSupported {
            device.isSmoothAutoFocusEnabled = false
        }

        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        print("📐 Scanner feed: \(dims.width) × \(dims.height) — preset \(session.sessionPreset.rawValue)")
    }

    private func isRemoteCamera(_ device: AVCaptureDevice) -> Bool {
        guard #available(iOS 17.0, *) else { return false }
        return device.deviceType == .continuityCamera || device.deviceType == .external
    }

    /// A session that fails after it starts just stops producing frames, and
    /// the preview goes black with nothing on screen to explain it. Catch that
    /// and drop to the most conservative preset rather than leaving the user
    /// staring at a black rectangle.
    private func observeRuntimeErrors() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionRuntimeError),
            name: .AVCaptureSessionRuntimeError,
            object: session
        )
    }

    @objc private func sessionRuntimeError(_ note: Notification) {
        let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
        print("⚠️ Scanner session error: \(error?.localizedDescription ?? "unknown")")

        guard session.sessionPreset != .high, session.canSetSessionPreset(.high) else {
            showStatus("Camera unavailable")
            return
        }
        session.beginConfiguration()
        session.sessionPreset = .high
        session.commitConfiguration()
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.startRunning()
        }
    }

    private func showStatus(_ message: String) {
        statusLabel.text = message
        statusLabel.isHidden = false
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !hasScanned,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue else { return }
        hasScanned = true
        session.stopRunning()
        onCode?(value)
    }

    @objc private func cancelTapped() {
        session.stopRunning()
        onCancel?()
    }
}
