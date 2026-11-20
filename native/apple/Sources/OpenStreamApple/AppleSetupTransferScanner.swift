#if os(iOS)
import AVFoundation
import SwiftUI
import VisionKit

/// Transfer To's camera: reads the QR code on the other device's Transfer
/// From screen. VisionKit's scanner where the device has it, else a plain
/// capture session.
struct AppleSetupTransferScanner: View {
    let onLink: (AppleSetupTransferLink) -> Void
    let onDenied: () -> Void
    @State private var authorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized

    /// Without a camera usage description in the app's Info.plist, touching
    /// the camera terminates the app, so the scanner is simply not offered.
    static var canScan: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil
            && AVCaptureDevice.default(for: .video) != nil
            && ![.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .video))
    }

    var body: some View {
        ZStack {
            Color.black
            if authorized {
                if DataScannerViewController.isSupported {
                    AppleDataScannerView(onPayload: open)
                } else {
                    AppleCaptureScannerView(onPayload: open)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("QR code scanner")
        .accessibilityIdentifier("setup.transfer.scanner")
        .task {
            guard !authorized else { return }
            authorized = await AVCaptureDevice.requestAccess(for: .video)
            if !authorized { onDenied() }
        }
    }

    private func open(_ payload: String) {
        guard let link = URL(string: payload).flatMap(AppleSetupTransferLink.init(url:)) else { return }
        onLink(link)
    }
}

private struct AppleDataScannerView: UIViewControllerRepresentable {
    let onPayload: @MainActor (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onPayload = onPayload
        guard !scanner.isScanning else { return }
        do { try scanner.startScanning() } catch { appleTraceFailure("setup transfer: scanner did not start") }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onPayload: onPayload) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onPayload: @MainActor (String) -> Void

        init(onPayload: @escaping @MainActor (String) -> Void) { self.onPayload = onPayload }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for case .barcode(let code) in addedItems {
                if let payload = code.payloadStringValue { onPayload(payload) }
            }
        }
    }
}

private struct AppleCaptureScannerView: UIViewRepresentable {
    let onPayload: @MainActor (String) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = context.coordinator.session
        context.coordinator.start()
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        context.coordinator.onPayload = onPayload
    }

    static func dismantleUIView(_ view: PreviewView, coordinator: AppleQRCaptureSession) {
        coordinator.stop()
    }

    func makeCoordinator() -> AppleQRCaptureSession { AppleQRCaptureSession(onPayload: onPayload) }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

/// The capture session is configured, started and stopped on its own queue,
/// as Apple's camera samples do; codes are delivered on the main queue.
private final class AppleQRCaptureSession: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "openstream.setup-transfer.scanner")
    /// Main queue only.
    var onPayload: @MainActor (String) -> Void
    /// The session reports a code on every frame it stays in view.
    private var lastPayload: String?

    init(onPayload: @escaping @MainActor (String) -> Void) { self.onPayload = onPayload }

    func start() {
        queue.async { [self] in
            guard let camera = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            session.startRunning()
        }
    }

    func stop() {
        queue.async { [session] in session.stopRunning() }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard let payload = metadataObjects.lazy.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first
        else { return }
        // The delegate queue is `.main` (`start()`).
        MainActor.assumeIsolated {
            guard payload != lastPayload else { return }
            lastPayload = payload
            onPayload(payload)
        }
    }
}
#endif
