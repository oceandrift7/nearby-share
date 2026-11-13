import SwiftUI
import AVFoundation

struct QRScanner: UIViewControllerRepresentable {
    let scanned: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerController { ScannerController(scanned: scanned) }
    func updateUIViewController(_ uiViewController: ScannerController, context: Context) {}
    static func dismantleUIViewController(_ controller: ScannerController, coordinator: ()) { controller.stop() }
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let capture = AVCaptureSession()
    private let queue = DispatchQueue(label: "nearby.camera")
    private let scanned: (String) -> Void
    private var preview: AVCaptureVideoPreviewLayer?
    private var completed = false
    private let message = UILabel()
    init(scanned: @escaping (String) -> Void) { self.scanned = scanned; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        message.text = "Point at the Android pairing code. Swipe down to cancel."
        message.textColor = .white; message.numberOfLines = 0
        message.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        message.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(message)
        NSLayoutConstraint.activate([
            message.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            message.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            message.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20)
        ])
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            DispatchQueue.main.async {
                guard !self.completed else { return }
                if granted { self.configure() }
                else { self.message.text = "Allow Camera access in Settings to scan the pairing code. Swipe down to close." }
            }
        }
    }

    private func configure() {
        do {
            guard let camera = AVCaptureDevice.default(for: .video) else { throw TransferError.message("Camera unavailable.") }
            let input = try AVCaptureDeviceInput(device: camera)
            let output = AVCaptureMetadataOutput()
            guard capture.canAddInput(input), capture.canAddOutput(output) else { throw TransferError.message("Camera unavailable.") }
            capture.addInput(input); capture.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main); output.metadataObjectTypes = [.qr]
            let layer = AVCaptureVideoPreviewLayer(session: capture)
            layer.videoGravity = .resizeAspectFill; layer.frame = view.bounds
            view.layer.insertSublayer(layer, at: 0); preview = layer
            queue.async { self.capture.startRunning() }
        } catch { message.text = error.localizedDescription }
    }

    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    func stop() { completed = true; queue.async { self.capture.stopRunning() } }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !completed, let value = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        stop(); scanned(value)
    }
}
