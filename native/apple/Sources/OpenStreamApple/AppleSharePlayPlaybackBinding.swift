import AVFoundation
import Foundation
import ObjectiveC
@preconcurrency import GroupActivities

struct AppleSharedPlaybackTiming: Equatable, Sendable {
    let itemTime: Double
    let hostTime: Double
    let rate: Float

    func position(at now: Double) -> Double? {
        guard itemTime.isFinite, itemTime >= 0, hostTime.isFinite,
              now.isFinite, rate.isFinite, rate > 0 else { return nil }
        let value = itemTime + max(0, now - hostTime) * Double(rate)
        return value.isFinite ? value : nil
    }
}

final class AppleSharedCommandCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable () -> Void)?
    init(_ callback: @escaping @Sendable () -> Void) { self.callback = callback }
    var isFinished: Bool { lock.withLock { callback == nil } }
    func finish() {
        let action = lock.withLock { let action = callback; callback = nil; return action }
        action?()
    }
}

enum AppleSharedPlaybackCommand: Sendable {
    case play(AppleSharedPlaybackTiming)
    case pause(prepare: Bool, rate: Float)
    case seek(Double, prepare: Bool, rate: Float)
    case buffer(rate: Float)
}

/// Retained by the player, independently of a session binding. Leaving a
/// session must never briefly restore AVFoundation's URL-based identity.
private final class AppleSharedPlayerIdentity: NSObject, AVPlayerPlaybackCoordinatorDelegate, @unchecked Sendable {
    let identifier: String
    init(_ identifier: String) { self.identifier = identifier }
    func playbackCoordinator(_ coordinator: AVPlayerPlaybackCoordinator, identifierFor playerItem: AVPlayerItem) -> String { identifier }
}

/// AVKit coordinates native players itself. The delegating coordinator applies
/// the same group commands to the engine's surface route, including host timing.
@MainActor
final class AppleSharePlayPlaybackBinding: NSObject, AVPlaybackCoordinatorPlaybackControlDelegate {
    private static var identityAssociationKey: UInt8 = 0
    nonisolated let identifier: String
    private weak var owner: ApplePlaybackCoordinator?
    private let nativePlayer: AVPlayer?
    private let nativeItem: AVPlayerItem?
    private var delegating: AVDelegatingPlaybackCoordinator?
    private var localSuspension: AVCoordinatedPlaybackSuspension?
    private var stallSuspension: AVCoordinatedPlaybackSuspension?
    private var speedSuspension: AVCoordinatedPlaybackSuspension?
    private var needsSupportedSpeed = false
    private var commandTask: Task<Void, Never>?
    private var valid = true
    private var isApplyingCommand = false
    private var audioInterrupted = false
    private var requiresUserResume = false

    init(owner: ApplePlaybackCoordinator, identifier: String, createsDelegatingCoordinator: Bool = true) {
        self.owner = owner
        self.identifier = identifier
        nativePlayer = owner.engine.avPlayer
        nativeItem = owner.engine.avPlayer?.currentItem
        super.init()
        if let nativePlayer {
            let identity = AppleSharedPlayerIdentity(identifier)
            objc_setAssociatedObject(nativePlayer, &Self.identityAssociationKey, identity, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            nativePlayer.playbackCoordinator.delegate = identity
        } else if createsDelegatingCoordinator {
            delegating = AVDelegatingPlaybackCoordinator(playbackControlDelegate: self)
            prepareCustomItem()
        }
        owner.sharedPlayback = self
    }

    private var systemCoordinator: AVPlaybackCoordinator? {
        nativePlayer?.playbackCoordinator ?? delegating
    }

    func matches(owner: ApplePlaybackCoordinator, identifier: String) -> Bool {
        valid && self.owner === owner && self.identifier == identifier
            && nativePlayer === owner.engine.avPlayer && nativeItem === owner.engine.avPlayer?.currentItem
    }

    func coordinate(with session: GroupSession<AppleLiveWatchingActivity>) {
        if let nativePlayer {
            nativePlayer.pause()
            nativePlayer.playbackCoordinator.coordinateWithSession(session)
        } else {
            delegating?.coordinateWithSession(session)
        }
    }

    private func prepareCustomItem() {
        if let delegating, let owner {
            var timebase: CMTimebase?
            CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
                                           sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
            if let timebase {
                CMTimebaseSetTime(timebase, time: CMTime(seconds: owner.engine.position, preferredTimescale: 600))
                CMTimebaseSetRate(timebase, rate: owner.engine.phase == .playing ? 1 : 0)
            }
            delegating.transitionToItem(withIdentifier: identifier, proposingInitialTimingBasedOn: timebase)
        }
    }

    func play() {
        guard valid else { return }
        clearUnsupportedSpeed()
        requiresUserResume = false
        localSuspension?.end()
        localSuspension = nil
        if let delegating { delegating.coordinateRateChange(to: 1, options: []) }
        else { owner?.engine.play() }
    }

    func pause() {
        guard valid else { return }
        if let delegating { delegating.coordinateRateChange(to: 0, options: []) }
        else { owner?.engine.pause() }
    }

    func seek(to seconds: Double) {
        guard valid, seconds.isFinite, seconds >= 0 else { return }
        if let delegating {
            delegating.coordinateSeek(to: CMTime(seconds: seconds, preferredTimescale: 600), options: [])
        } else {
            Task { @MainActor [weak self] in
                guard let self, self.valid else { return }
                await self.owner?.engine.seek(to: seconds)
            }
        }
    }

    func suspendForLocalTransition() {
        guard valid, localSuspension == nil else { return }
        localSuspension = systemCoordinator?.beginSuspension(for: .userActionRequired)
    }

    func setAudioInterrupted(_ interrupted: Bool, canResume: Bool = true) {
        audioInterrupted = interrupted
        if interrupted { suspendForLocalTransition() }
        else {
            requiresUserResume = !canResume
            refreshReadiness()
        }
    }

    func refreshReadiness() {
        guard valid, let owner else { return }
        guard !audioInterrupted, !isApplyingCommand, !needsSupportedSpeed else { return }
        if requiresUserResume, owner.engine.phase == .playing { requiresUserResume = false }
        guard !requiresUserResume else { return }
        switch owner.engine.phase {
        case .playing, .paused:
            if let localSuspension {
                self.localSuspension = nil
                localSuspension.end()
                delegating?.reapplyCurrentItemStateToPlaybackControlDelegate()
            }
            if let stallSuspension {
                self.stallSuspension = nil
                stallSuspension.end()
            }
        case .stalled, .rebuffering, .loading:
            if delegating != nil, stallSuspension == nil {
                stallSuspension = systemCoordinator?.beginSuspension(for: .stallRecovery)
            }
        default:
            break
        }
    }

    /// Keep local playback only after leaving/invalidating the actual session.
    /// For item replacement, stop the old native item before releasing its
    /// identity delegate so the coordinator never falls back to a private URL.
    func invalidate(keepPlaying: Bool = false) {
        guard valid else { return }
        suspendForLocalTransition()
        valid = false
        commandTask?.cancel()
        if owner?.sharedPlayback === self { owner?.sharedPlayback = nil }
        if !keepPlaying, nativePlayer == nil { owner?.engine.pause() }
        if !keepPlaying, nativePlayer?.currentItem === nativeItem {
            nativePlayer?.pause()
            nativePlayer?.replaceCurrentItem(with: nil)
        }
        delegating?.transitionToItem(withIdentifier: nil, proposingInitialTimingBasedOn: nil)
        localSuspension?.end()
        stallSuspension?.end()
        speedSuspension?.end()
        localSuspension = nil
        stallSuspension = nil
        speedSuspension = nil
    }

    private func enqueue(identifier expected: String, deadline: Date? = nil, completion: @escaping @Sendable () -> Void,
                         work: @escaping @MainActor (AppleSharePlayPlaybackBinding, ApplePlaybackCoordinator, AppleSharedCommandCompletion) async -> Void) {
        guard valid, identifier == expected, owner != nil else { completion(); return }
        let previous = commandTask
        let gate = AppleSharedCommandCompletion(completion)
        let deadlineTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, (deadline ?? Date().addingTimeInterval(10)).timeIntervalSinceNow))) }
            catch { return }
            guard !gate.isFinished else { return }
            self?.cannotFollowGroup()
            gate.finish()
        }
        commandTask = Task { @MainActor [weak self] in
            await previous?.value
            defer { deadlineTask.cancel(); gate.finish() }
            guard !Task.isCancelled, !gate.isFinished, let self, self.valid, self.identifier == expected, let owner = self.owner else { return }
            self.isApplyingCommand = true
            defer { self.isApplyingCommand = false }
            await work(self, owner, gate)
        }
    }

    private func cannotFollowGroup() {
        guard valid, stallSuspension == nil else { return }
        stallSuspension = systemCoordinator?.beginSuspension(for: .stallRecovery)
        owner?.engine.pause()
        owner?.update(.waiting("Waiting to sync with SharePlay…"))
    }

    private func supports(rate: Float, owner: ApplePlaybackCoordinator) -> Bool {
        guard rate.isFinite, rate > 0, rate <= owner.engine.maximumPlaybackRate else {
            needsSupportedSpeed = true
            if speedSuspension == nil { speedSuspension = systemCoordinator?.beginSuspension(for: .userActionRequired) }
            owner.engine.pause()
            owner.update(.waiting("This source cannot follow the shared speed. Choose Play to return to normal speed, or leave SharePlay."))
            return false
        }
        return true
    }

    private func clearUnsupportedSpeed() {
        needsSupportedSpeed = false
        speedSuspension?.end()
        speedSuspension = nil
    }

    private static func hostSeconds() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    nonisolated func playbackCoordinator(_ coordinator: AVDelegatingPlaybackCoordinator,
        didIssue command: AVDelegatingPlaybackCoordinatorPlayCommand,
        completionHandler: @escaping @Sendable () -> Void) {
        dispatch(.play(.init(itemTime: command.itemTime.seconds, hostTime: command.hostClockTime.seconds, rate: command.rate)),
                 identifier: command.expectedCurrentItemIdentifier, completion: completionHandler)
    }

    nonisolated func playbackCoordinator(_ coordinator: AVDelegatingPlaybackCoordinator,
        didIssue command: AVDelegatingPlaybackCoordinatorPauseCommand,
        completionHandler: @escaping @Sendable () -> Void) {
        dispatch(.pause(prepare: command.shouldBufferInAnticipationOfPlayback, rate: command.anticipatedPlaybackRate),
                 identifier: command.expectedCurrentItemIdentifier, completion: completionHandler)
    }

    nonisolated func playbackCoordinator(_ coordinator: AVDelegatingPlaybackCoordinator,
        didIssue command: AVDelegatingPlaybackCoordinatorSeekCommand,
        completionHandler: @escaping @Sendable () -> Void) {
        dispatch(.seek(command.itemTime.seconds, prepare: command.shouldBufferInAnticipationOfPlayback, rate: command.anticipatedPlaybackRate),
                 identifier: command.expectedCurrentItemIdentifier, deadline: command.completionDueDate, completion: completionHandler)
    }

    nonisolated func playbackCoordinator(_ coordinator: AVDelegatingPlaybackCoordinator,
        didIssue command: AVDelegatingPlaybackCoordinatorBufferingCommand,
        completionHandler: @escaping @Sendable () -> Void) {
        dispatch(.buffer(rate: command.anticipatedPlaybackRate), identifier: command.expectedCurrentItemIdentifier,
                 deadline: command.completionDueDate, completion: completionHandler)
    }

    private nonisolated func dispatch(_ command: AppleSharedPlaybackCommand, identifier: String, deadline: Date? = nil,
                                      completion: @escaping @Sendable () -> Void) {
        Task { @MainActor [weak self] in
            guard let self else { completion(); return }
            self.receive(command, identifier: identifier, deadline: deadline, completion: completion)
        }
    }

    /// The system delegate and deterministic tests enter the same command path.
    /// Completion is acknowledged once, including expiry and stale-item cases.
    func receive(_ command: AppleSharedPlaybackCommand, identifier: String, deadline: Date? = nil,
                 completion: @escaping @Sendable () -> Void) {
        enqueue(identifier: identifier, deadline: deadline, completion: completion) { binding, owner, gate in
            @MainActor func stillCurrent() -> Bool { binding.valid && !Task.isCancelled && !gate.isFinished }
            switch command {
            case .play(let timing):
                guard binding.supports(rate: timing.rate, owner: owner) else { return }
                guard let target = timing.position(at: Self.hostSeconds()) else { binding.cannotFollowGroup(); return }
                binding.clearUnsupportedSpeed()
                owner.engine.pause()
                await owner.engine.seek(to: target)
                guard stillCurrent() else { return }
                let wait = timing.hostTime - Self.hostSeconds()
                if wait > 0 {
                    guard wait <= 30 else { binding.cannotFollowGroup(); return }
                    do { try await Task.sleep(for: .seconds(wait)) } catch { return }
                }
                guard stillCurrent(), let corrected = timing.position(at: Self.hostSeconds()) else { return }
                if abs(owner.engine.position - corrected) > 0.25 { await owner.engine.seek(to: corrected) }
                guard stillCurrent() else { return }
                owner.engine.setPlaybackRate(timing.rate)
            case .pause(let prepare, let rate):
                if prepare, !binding.supports(rate: rate, owner: owner) { return }
                if prepare, !binding.canPrepare(rate: rate, owner: owner) { binding.cannotFollowGroup() }
                owner.engine.pause()
            case .seek(let seconds, let prepare, let rate):
                if prepare, !binding.supports(rate: rate, owner: owner) { return }
                guard seconds.isFinite, seconds >= 0 else { binding.cannotFollowGroup(); return }
                owner.engine.pause()
                await owner.engine.seek(to: seconds)
                guard stillCurrent() else { return }
                owner.engine.pause()
                if prepare, !binding.canPrepare(rate: rate, owner: owner) { binding.cannotFollowGroup() }
            case .buffer(let rate):
                guard binding.supports(rate: rate, owner: owner) else { return }
                if binding.canPrepare(rate: rate, owner: owner) {
                    owner.engine.pause()
                    owner.update(.waiting("Waiting for SharePlay…"))
                } else {
                    binding.cannotFollowGroup()
                }
            }
        }
    }

    private func canPrepare(rate: Float, owner: ApplePlaybackCoordinator) -> Bool {
        rate.isFinite && rate > 0 && rate <= owner.engine.maximumPlaybackRate
            && (owner.engine.phase == .playing || owner.engine.phase == .paused)
            && owner.engine.failure == nil
    }

    isolated deinit { commandTask?.cancel() }
}
