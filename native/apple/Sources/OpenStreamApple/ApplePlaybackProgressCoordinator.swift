@preconcurrency import AVFoundation
import Foundation

/// Coordinates bounded periodic progress writes for one player. The observer
/// uses a weak capture, so the player/session can still be released normally.
@MainActor
public final class ApplePlaybackProgressCoordinator {
    nonisolated static func shouldSaveOnClose(hasPlayed: Bool, route: ApplePlaybackPresentationRoute,
                                            isLive: Bool, position: Double, duration: Double) -> Bool {
        hasPlayed && route == .surface && !isLive
            && position.isFinite && position > 0 && duration.isFinite && duration > 0
    }

    /// Positions under this are the player's zero, not the viewer's place.
    nonisolated static let resumeFloor: Double = 1

    /// A write that would replace the saved resume point with the player's
    /// zero. After an item failure or an engine rebuild the player reports 0
    /// before any frame: Apple TV 2026-11-04, AVFoundation -11819 on a resume
    /// at 1649 s saved `pos=0`, and the next resume started from the
    /// beginning. A session that opened at the start may still write 0.
    nonisolated static func keepsResumePoint(position: Double, resumedFrom: Double?) -> Bool {
        position < resumeFloor && (resumedFrom ?? 0) >= resumeFloor
    }

    static func saveProgressOnClose(coordinator: ApplePlaybackCoordinator, request: ApplePlaybackRequest, hasPlayed: Bool) {
        let position = coordinator.engine.position
        let duration = coordinator.engine.duration ?? 0
        guard !coordinator.progressEnded, coordinator.phase != .ended,
              !keepsResumePoint(position: position, resumedFrom: coordinator.resumedFrom) else { return }
        guard shouldSaveOnClose(hasPlayed: hasPlayed, route: coordinator.route, isLive: request.isLive,
                                position: position, duration: duration) else { return }
        if let writer = coordinator.progressWriter {
            writer(position, duration)
        } else {
            ApplePlaybackStore().save(request: request, position: position, duration: duration)
        }
    }

    public let mediaIdentity: String
    /// The episode (or resolved film id) the saved position belongs to, so a
    /// series resumes the part it was actually watching.
    public let partID: String?

    private let store: ApplePlaybackStore
    public var writer: (@MainActor (Double, Double) -> Void)?
    /// Where this session opened; see `keepsResumePoint`.
    var resumedFrom: Double?
    private let saveInterval: Double
    private weak var player: AVPlayer?
    private var periodicTimeObserver: Any?
    private var lastRecord: (position: Double, duration: Double)?
    private var finished = false

    public init(
        store: ApplePlaybackStore,
        mediaIdentity: String,
        partID: String? = nil,
        saveInterval: Double = 15
    ) {
        self.store = store
        self.mediaIdentity = mediaIdentity
        self.partID = partID
        self.saveInterval = max(1, saveInterval)
    }

    public func startObserving(_ player: AVPlayer) {
        guard self.player !== player else { return }
        stopObserving(saveCurrentProgress: false)
        self.player = player
        let interval = CMTime(seconds: saveInterval, preferredTimescale: 600)
        periodicTimeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self, weak player] time in
            MainActor.assumeIsolated {
                // A failed item reports 0, not where the viewer was.
                guard let self, let player, self.player === player, player.currentItem?.error == nil else { return }
                self.record(position: time.seconds, duration: player.currentItem?.duration.seconds ?? 0,
                            isPlaying: player.rate > 0)
            }
        }
    }

    public func saveCurrentProgress() {
        guard let player, player.currentItem?.error == nil else { return }
        record(
            position: player.currentTime().seconds,
            duration: player.currentItem?.duration.seconds ?? 0,
            isPlaying: player.rate > 0
        )
    }

    func beginPlaySession() {
        finished = false
        lastRecord = nil
    }

    public func record(position: Double, duration: Double, isPlaying: Bool = false) {
        guard position.isFinite, position >= 0, duration.isFinite, duration > 0,
              !Self.keepsResumePoint(position: position, resumedFrom: resumedFrom) else { return }
        if finished, isPlaying, position < duration { beginPlaySession() }
        guard !finished else { return }
        let position = min(position, duration)
        guard lastRecord?.position != position || lastRecord?.duration != duration else { return }
        lastRecord = (position, duration)
        if let writer { writer(position, duration) }
        else { store.save(mediaID: mediaIdentity, position: position, duration: duration, partID: partID) }
        if position == duration { finished = true }
    }

    public func markComplete() {
        finished = true
        store.clear(mediaID: mediaIdentity)
    }

    func finish(duration: Double) {
        record(position: duration, duration: duration)
        finished = true
        stopObserving(saveCurrentProgress: false)
    }

    public func stopObserving(saveCurrentProgress: Bool = true) {
        if saveCurrentProgress { self.saveCurrentProgress() }
        if let periodicTimeObserver, let player {
            player.removeTimeObserver(periodicTimeObserver)
        }
        periodicTimeObserver = nil
        player = nil
    }
}
