#if os(tvOS)
import AVFoundation
import Observation

/// Owns streams, never view state. Stopping cancels every open/observation;
/// resuming uses the same pure session, including insertion order and focus.
@MainActor
@Observable
final class AppleTVMultiviewSession {
    private(set) var policy: AppleMultiviewPolicy.Session
    private(set) var tiles: [AppleTVMultiviewTile] = []
    var notice: String?
    var captionsEnabled: Bool
    @ObservationIgnored private var channels: [String: AppleIPTVChannel]
    @ObservationIgnored private var active = false
    @ObservationIgnored private var providerLimits: [UUID: Int] = [:]
    @ObservationIgnored private let audioSession = AppleAudioSessionCoordinator()

    init(channels: [AppleIPTVChannel]) {
        self.channels = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        policy = .init(channels: channels.map(\.id))
        captionsEnabled = AppleSettingsStore().captionsPreference != .off
        reconcile()
    }

    var audioChannel: AppleIPTVChannel? { policy.audioID.flatMap { channels[$0] } }
    var displayTiles: [AppleTVMultiviewTile] {
        policy.displayOrder.compactMap { id in tiles.first { $0.id == id } }
    }

    func resume() async {
        providerLimits = await AppleIPTVAccountLimits.shared.snapshot()
        var retained: [String: UUID] = [:]
        for id in policy.channels {
            guard let channel = channels[id] else { continue }
            if AppleMultiviewPolicy.providerLimitReached(sourceID: channel.sourceID,
                                                         sources: retained, limits: providerLimits) {
                _ = policy.remove(id)
                notice = providerLimitMessage(channel.sourceID)
            } else { retained[id] = channel.sourceID }
        }
        try? await audioSession.prepareForPlayback()
        guard !Task.isCancelled else { return }
        active = true
        reconcile()
        for tile in tiles { tile.start() }
        appleTrace("multiview resume tiles=\(tiles.count) audio=\(policy.audioID ?? "none") layout=\(policy.layout.rawValue)")
    }

    func suspend() {
        active = false
        for tile in tiles { tile.stop() }
        appleTrace("multiview suspended tiles=\(tiles.count)")
    }

    func focus(_ id: String) {
        guard policy.channels.contains(id), policy.audioID != id else { return }
        policy.focus(id)
        applyRoles()
        appleTrace("multiview audio=\(id) othersMuted=true testMute=\(AppleTestAudioMute.isActive)")
    }

    func select(_ id: String) {
        policy.select(id)
        applyRoles()
        applyFullscreenPauses()
    }

    func returnToGrid() { _ = policy.back(); applyFullscreenPauses() }

    func add(_ channel: AppleIPTVChannel) {
        guard !providerLimitReached(channel) else { notice = providerLimitMessage(channel.sourceID); return }
        if let refusal = policy.add(channel.id, thermal: Self.thermal) { notice = refusal.message; return }
        channels[channel.id] = channel
        reconcile()
    }

    func replace(_ id: String, with channel: AppleIPTVChannel) {
        guard !providerLimitReached(channel, replacing: id) else { notice = providerLimitMessage(channel.sourceID); return }
        guard policy.replace(id, with: channel.id) else { notice = AppleMultiviewPolicy.Refusal.duplicate.message; return }
        channels[channel.id] = channel
        reconcile()
    }

    func remove(_ id: String) -> AppleIPTVChannel? {
        let exitID = policy.remove(id)
        reconcile()
        return exitID.flatMap { channels[$0] }
    }

    func promote(_ id: String) { policy.promote(id); applyRoles() }

    private func providerLimitReached(_ channel: AppleIPTVChannel, replacing: String? = nil) -> Bool {
        AppleMultiviewPolicy.providerLimitReached(sourceID: channel.sourceID,
            sources: Dictionary(uniqueKeysWithValues: policy.channels.compactMap { id in
                channels[id].map { (id, $0.sourceID) }
            }), limits: providerLimits, replacing: replacing)
    }

    private func providerLimitMessage(_ sourceID: UUID) -> String {
        "This provider allows \(providerLimits[sourceID] ?? 1) simultaneous streams"
    }
    func toggleLayout() {
        policy.layout = policy.layout == .grid ? .bigAndSmalls : .grid
        applyRoles()
    }
    func toggleCaptions() { captionsEnabled.toggle(); applyRoles() }

    /// A notification sheds one oldest non-audio stream, keeping audio intact.
    func thermalChanged() -> AppleIPTVChannel? {
        guard policy.shed(thermal: Self.thermal) != nil else { return nil }
        notice = "Apple TV is too warm. A channel was removed."
        reconcile()
        return policy.channels.count == 1 ? audioChannel : nil
    }

    private func reconcile() {
        for tile in tiles where !policy.channels.contains(tile.id) { tile.stop() }
        tiles.removeAll { !policy.channels.contains($0.id) }
        for id in policy.channels where !tiles.contains(where: { $0.id == id }) {
            if let channel = channels[id] { tiles.append(AppleTVMultiviewTile(channel: channel)) }
        }
        applyRoles()
        if active { for tile in tiles { tile.start() } }
        applyFullscreenPauses()
    }

    private func applyFullscreenPauses() {
        for tile in tiles { tile.setFullscreenPaused(policy.pausedChannelIDs.contains(tile.id)) }
    }

    private func applyRoles() {
        // Mute every outgoing owner first; dictionary/order iteration must never
        // produce two audible players, even for the duration of one actor turn.
        for tile in tiles where tile.id != policy.audioID {
            tile.configure(audible: false, uncapped: tile.id == bigTileID, captions: false)
        }
        if let audio = tiles.first(where: { $0.id == policy.audioID }) {
            audio.configure(audible: true, uncapped: true, captions: captionsEnabled)
        }
    }

    private var bigTileID: String? {
        policy.channels.count == 3 || policy.layout == .bigAndSmalls ? policy.bigID : nil
    }

    static var thermal: AppleMultiviewPolicy.Thermal {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .serious
        }
    }

    func traceMetrics() {
        for tile in tiles {
            let engine = tile.coordinator.engine
            let dropped = (engine as? AetherPlaybackEngine)?.aetherEngine.liveTelemetry?.droppedFrameCount
                ?? engine.avPlayer?.currentItem?.accessLog()?.events.reduce(0) { $0 + $1.numberOfDroppedVideoFrames }
            appleTrace("multiview metrics id=\(tile.id) engine=\(engine.kind.rawValue) phase=\(tile.coordinator.phase) dropped=\(dropped.map(String.init) ?? "unknown")")
        }
    }
}
#endif
