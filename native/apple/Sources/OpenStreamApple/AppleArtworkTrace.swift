import CoreGraphics
import Foundation
import os
import Synchronization

enum AppleArtworkTrace {
    private static let log = OSLog(subsystem: "com.orgista.openstream", category: .pointsOfInterest)
    private static let transfers = Mutex(0)

    static func identifier(_ url: URL) -> String {
        String(AppleArtworkDiskCachePolicy.fileName(for: url, variant: "raw").prefix(16))
    }

    static func record(_ detail: @autoclosure () -> String) {
        guard AppleInteractionTrace.isEnabled else { return }
        let detail = detail()
        AppleInteractionTrace.record(.network, "artwork \(detail)")
        os_signpost(.event, log: log, name: "Artwork", "%{public}@", detail as NSString)
    }

    static func begin(_ name: StaticString, url: URL) -> OSSignpostID {
        guard AppleInteractionTrace.isEnabled else { return .invalid }
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id, "%{public}@", identifier(url) as NSString)
        return id
    }

    static func end(_ name: StaticString, id: OSSignpostID) {
        guard id != .invalid else { return }
        os_signpost(.end, log: log, name: name, signpostID: id)
    }

    static func transferStarted(url: URL) {
        let active = transfers.withLock { $0 += 1; return $0 }
        guard AppleInteractionTrace.isEnabled else { return }
        let size = AppleTMDBClient.isResizableArtworkURL(url)
            ? String(url.path.split(separator: "/").dropFirst(2).first ?? "unknown") : "source"
        record("fetch image=\(identifier(url)) size=\(size) active=\(active)")
    }

    static func transferEnded() {
        transfers.withLock { $0 -= 1 }
    }

    static func ready(url: URL?, size: CGSize, scale: CGFloat, image: CGImage) {
        guard let url else { return }
        record("ready image=\(identifier(url)) display=\(Int(size.width * scale))x\(Int(size.height * scale)) decoded=\(image.width)x\(image.height)")
    }
}
