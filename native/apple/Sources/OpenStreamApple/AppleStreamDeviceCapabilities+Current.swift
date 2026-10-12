import AetherEngine
import Foundation
import Network
import Synchronization
#if canImport(UIKit)
import UIKit
#endif

extension AppleStreamDeviceCapabilities {
    /// This device and display right now, for `playbackOrder`.
    ///
    /// HDR and Dolby Vision come from the engine's display snapshot, the one
    /// its own routing reads (`AetherEngine.displayCapabilities`), so the
    /// picker never prefers a stream the engine would then tone-map. Automatic
    /// stops at 1080p on an iPhone, whose screen shows no more, and on a
    /// cellular or Low Data connection; everywhere else it reaches for 4K.
    @MainActor
    public static var current: AppleStreamDeviceCapabilities {
        let display = AetherEngine.displayCapabilities
        var cap = AppleStreamQualityTier.uhd
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone { cap = .fullHD }
        #endif
        if AppleNetworkCost.shared.isCostly { cap = min(cap, .fullHD) }
        return AppleStreamDeviceCapabilities(
            supportsHDR: display.supportsHDR,
            supportsDolbyVision: display.supportsDolbyVision,
            automaticTierCap: cap)
    }
}

/// Whether the current connection is metered: cellular, a personal hotspot,
/// or Low Data Mode. Starts watching on first use.
final class AppleNetworkCost: Sendable {
    static let shared = AppleNetworkCost()

    private let monitor = NWPathMonitor()
    private let state = Mutex(false)

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.state.withLock { $0 = path.isExpensive || path.isConstrained }
        }
        monitor.start(queue: DispatchQueue(label: "openstream.network-cost", qos: .utility))
    }

    var isCostly: Bool { state.withLock { $0 } }
}
