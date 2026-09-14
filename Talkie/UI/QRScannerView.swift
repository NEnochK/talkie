import AVFoundation
import SwiftUI
import TalkieCore

/// Live camera QR scanner. Reports the first valid channel link it sees, once.
struct QRScannerView: UIViewControllerRepresentable {
	let onFound: (Channel) -> Void

	func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

	func makeUIViewController(context: Context) -> ScannerController {
		let controller = ScannerController()
		controller.coordinator = context.coordinator
		return controller
	}

	func updateUIViewController(_ controller: ScannerController, context: Context) {}

	final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
		private let onFound: (Channel) -> Void
		/// Codes arrive many times a second; act on exactly one.
		private var hasReported = false

		init(onFound: @escaping (Channel) -> Void) {
			self.onFound = onFound
		}

		func metadataOutput(
			_ output: AVCaptureMetadataOutput,
			didOutput objects: [AVMetadataObject],
			from connection: AVCaptureConnection
		) {
			guard !hasReported else { return }
			for object in objects {
				guard let readable = object as? AVMetadataMachineReadableCodeObject,
				      let raw = readable.stringValue,
				      let url = URL(string: raw),
				      let channel = Channel(url: url) else { continue }
				hasReported = true
				DispatchQueue.main.async { self.onFound(channel) }
				return
			}
		}
	}

	final class ScannerController: UIViewController {
		weak var coordinator: Coordinator?

		private let session = AVCaptureSession()
		private var preview: AVCaptureVideoPreviewLayer?
		/// Camera setup blocks; keep it off the main thread.
		private let sessionQueue = DispatchQueue(label: "com.talkie.scanner")

		override func viewDidLoad() {
			super.viewDidLoad()
			view.backgroundColor = .black
			configure()
		}

		override func viewDidLayoutSubviews() {
			super.viewDidLayoutSubviews()
			preview?.frame = view.bounds
		}

		override func viewWillDisappear(_ animated: Bool) {
			super.viewWillDisappear(animated)
			sessionQueue.async { [session] in
				if session.isRunning { session.stopRunning() }
			}
		}

		private func configure() {
			guard let device = AVCaptureDevice.default(for: .video),
			      let input = try? AVCaptureDeviceInput(device: device),
			      session.canAddInput(input) else { return }

			session.addInput(input)

			let output = AVCaptureMetadataOutput()
			guard session.canAddOutput(output) else { return }
			session.addOutput(output)
			output.setMetadataObjectsDelegate(coordinator, queue: .main)
			// Must be set after the output is attached, or .qr is not yet available.
			output.metadataObjectTypes = [.qr]

			let layer = AVCaptureVideoPreviewLayer(session: session)
			layer.videoGravity = .resizeAspectFill
			layer.frame = view.bounds
			view.layer.addSublayer(layer)
			preview = layer

			sessionQueue.async { [session] in
				if !session.isRunning { session.startRunning() }
			}
		}
	}
}
