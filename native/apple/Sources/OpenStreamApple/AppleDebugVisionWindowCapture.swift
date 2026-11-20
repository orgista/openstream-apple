#if DEBUG && os(visionOS) && targetEnvironment(simulator)
import UIKit

/// A flat window capture when the simulator compositor cannot supply frames to simctl.
@MainActor
enum AppleDebugVisionWindowCapture {
    static func run(scene: UIWindowScene) async throws {
        guard UserDefaults.standard.bool(forKey: "OpenStreamVisionWindowCapture") else { return }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let request = caches.appendingPathComponent("vision-capture-request")
        while !Task.isCancelled {
            if let data = try? Data(contentsOf: request),
               let value = String(data: data, encoding: .utf8), let id = UUID(uuidString: value),
               let window = scene.keyWindow {
                try? FileManager.default.removeItem(at: request)
                do {
                    let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
                    let png = renderer.pngData { _ in
                        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                    }
                    try png.write(to: caches.appendingPathComponent("vision-capture-\(id.uuidString).png"), options: .atomic)
                } catch {
                    appleTrace("vision window capture write failed")
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
#endif
