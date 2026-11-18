import AVFoundation
import SwiftUI
import UIKit

/// The camera view that reads the home server's pairing code. It reports the
/// first QR code whose text starts with `myna://` and then stops.
struct PairingScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> PairingScannerController {
        let controller = PairingScannerController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: PairingScannerController, context: Context) {}
}

final class PairingScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?

    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var reported = false
    private let message = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        message.textColor = .white
        message.font = .systemFont(ofSize: 14, weight: .light)
        message.numberOfLines = 0
        message.textAlignment = .center
        message.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(message)
        NSLayoutConstraint.activate([
            message.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            message.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            message.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.configure() } else { self?.showDenied() }
                }
            }
        default:
            showDenied()
        }
    }

    private func showDenied() {
        message.text = "Myna can't use the camera. Allow it in Settings › Myna › Camera, or paste the pairing link instead."
    }

    private func configure() {
        guard let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else {
            message.text = "No camera is available. Paste the pairing link instead."
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        if output.availableMetadataObjectTypes.contains(.qr) {
            output.metadataObjectTypes = [.qr]
        }

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)
        preview = layer

        let capture = self.session
        DispatchQueue.global(qos: .userInitiated).async { capture.startRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let capture = self.session
        DispatchQueue.global(qos: .userInitiated).async {
            if capture.isRunning { capture.stopRunning() }
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !reported else { return }
        for object in metadataObjects {
            guard let code = object as? AVMetadataMachineReadableCodeObject,
                  let text = code.stringValue, text.hasPrefix("myna://") else { continue }
            reported = true
            onCode?(text)
            return
        }
    }
}
