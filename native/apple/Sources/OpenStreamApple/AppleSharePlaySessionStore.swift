import AVFoundation
@preconcurrency import Combine
import Foundation
@preconcurrency import GroupActivities
import Observation

struct AppleLiveWatchingActivity: GroupActivity, Sendable {
    static let activityIdentifier = "com.orgista.openstream.watch-live"
    let channel: AppleSharePlayChannel

    var metadata: GroupActivityMetadata {
        var value = GroupActivityMetadata()
        value.type = .watchTogether
        value.title = channel.title
        value.subtitle = "Live TV in OpenStream"
        return value
    }
}

@MainActor
@Observable
final class AppleSharePlaySessionStore {
    static let shared = AppleSharePlaySessionStore()
    static var isSupportedInApp: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    private(set) var channel: AppleSharePlayChannel?
    private(set) var revision = 0
    private(set) var participantCount = 0
    private(set) var isStarting = false
    private(set) var canStartInCurrentCall = false
    var message: String?
    var isActive: Bool { session != nil }

    @ObservationIgnored private var session: GroupSession<AppleLiveWatchingActivity>?
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var subscriptions = Set<AnyCancellable>()
    @ObservationIgnored private var playback: AppleSharePlayPlaybackBinding?
    @ObservationIgnored private var hasJoined = false
    @ObservationIgnored private var eligibilityObserver: GroupStateObserver?
    @ObservationIgnored private var eligibilitySubscription: AnyCancellable?

    func startListening() {
        guard Self.isSupportedInApp, listener == nil else { return }
        let observer = GroupStateObserver()
        eligibilityObserver = observer
        canStartInCurrentCall = observer.isEligibleForGroupSession
        eligibilitySubscription = observer.$isEligibleForGroupSession.sink { [weak self] eligible in
            Task { @MainActor [weak self] in self?.canStartInCurrentCall = eligible }
        }
        listener = Task { @MainActor [weak self] in
            for await session in AppleLiveWatchingActivity.sessions() {
                guard !Task.isCancelled else { break }
                self?.receive(session)
            }
        }
    }

    func start(channel: AppleIPTVChannel) async {
        guard Self.isSupportedInApp, !isStarting else { return }
        startListening()
        guard eligibilityObserver?.isEligibleForGroupSession == true else {
            message = "SharePlay needs an active FaceTime call."
            return
        }
        isStarting = true
        defer { isStarting = false }
        do {
            let activity = AppleLiveWatchingActivity(channel: try AppleSharePlayChannel(channel: channel))
            switch await activity.prepareForActivation() {
            case .activationPreferred:
                let activated = try await activity.activate()
                if !activated { message = "SharePlay activation was not accepted." }
            case .activationDisabled:
                message = "No one else is in this SharePlay session."
            case .cancelled:
                break
            @unknown default:
                message = "SharePlay is unavailable right now."
            }
        } catch is CancellationError {
        } catch {
            message = "SharePlay could not start because the FaceTime connection failed."
        }
    }

    /// A user-selected channel change is a group activity change. Each member
    /// independently resolves the new identity using their configured sources.
    func selected(_ local: AppleIPTVChannel) {
        guard let session else { return }
        guard let next = try? AppleSharePlayChannel(channel: local) else {
            leave()
            message = "This channel cannot be shared on this device."
            return
        }
        guard next.channelKey != channel?.channelKey else { return }
        playback?.invalidate()
        playback = nil
        channel = next
        session.activity = AppleLiveWatchingActivity(channel: next)
        revision &+= 1
    }

    func refreshPlayback(_ owner: ApplePlaybackCoordinator, channel local: AppleSharePlayChannel) {
        guard let session, let channel, local.channelKey == channel.channelKey else { return }
        guard owner.route != .none, owner.engine.failure == nil else { return }
        if let playback, playback.matches(owner: owner, identifier: channel.playbackIdentifier) {
            playback.refreshReadiness()
            return
        }
        guard owner.engine.avPlayer?.currentItem != nil || owner.phase == .playing || owner.phase == .paused else { return }
        let shouldStart = !hasJoined && session.isLocallyInitiated && owner.engine.phase != .paused
        playback?.invalidate()
        let binding = AppleSharePlayPlaybackBinding(owner: owner, identifier: channel.playbackIdentifier)
        playback = binding
        binding.coordinate(with: session)
        session.join()
        hasJoined = true
        if shouldStart { binding.play() }
    }

    func leave() {
        let current = session
        current?.leave()
        clearSession()
    }

    func endForEveryone() {
        let current = session
        current?.end()
        clearSession()
    }

    private func receive(_ next: GroupSession<AppleLiveWatchingActivity>) {
        guard session?.id != next.id else { return }
        leave()
        session = next
        channel = next.activity.channel
        participantCount = next.activeParticipants.count
        revision &+= 1
        let sessionID = next.id
        next.$activity.sink { [weak self] activity in
            Task { @MainActor [weak self] in
                guard let self, self.session?.id == sessionID, self.channel != activity.channel else { return }
                self.playback?.invalidate()
                self.playback = nil
                self.channel = activity.channel
                self.revision &+= 1
            }
        }.store(in: &subscriptions)
        next.$state.sink { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.session?.id == sessionID else { return }
                if case .invalidated = state { self.clearSession() }
            }
        }.store(in: &subscriptions)
        next.$activeParticipants.sink { [weak self] participants in
            let count = participants.count
            Task { @MainActor [weak self] in
                guard let self, self.session?.id == sessionID else { return }
                self.participantCount = count
            }
        }.store(in: &subscriptions)
    }

    private func clearSession() {
        playback?.invalidate(keepPlaying: true)
        playback = nil
        subscriptions.removeAll()
        session = nil
        hasJoined = false
        channel = nil
        participantCount = 0
        revision &+= 1
    }

    isolated deinit {
        listener?.cancel()
        playback?.invalidate()
        session?.leave()
    }
}
