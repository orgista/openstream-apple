import Foundation
import Observation

/// Playback selection and preflight shared by the inline and television
/// surfaces. Presenting a different surface keeps the same coordinator.
@MainActor
@Observable
final class AppleLiveSession {
    struct ProbeRequest {
        let id = UUID()
        let channel: AppleIPTVChannel
        let shareSelection: Bool
        let present: Bool
        var programme: AppleIPTVProgramme? = nil
    }
    enum ProbeOutcome { case ready(ProbeRequest), failed(ProbeRequest), superseded }

    var coordinator: ApplePlaybackCoordinator
    var channel: AppleIPTVChannel?
    var programme: AppleIPTVProgramme?
    var playbackRevision = 0
    var fullScreenRevision = 0
    var resumePending = false
    var multiviewChannels: [AppleIPTVChannel] = []
    var probedKinds: [String: AppleIPTVStreamProbeResult.MediaKind] = [:]
    var pendingProbe: ProbeRequest?
    var failedProbe: ProbeRequest?
    var probeFailureMessage: String?
    @ObservationIgnored private let hangMonitor: AppleHangMonitor
    @ObservationIgnored private let streamProbe: AppleIPTVStreamProbe
    @ObservationIgnored private var connectionWaitedChannelID: String?
    /// The channel being tuned and when, until its first picture.
    @ObservationIgnored private var tune: (id: String, startedAt: ContinuousClock.Instant)?
    /// Live resumes the last channel on its first entry per launch only.
    private static var launchEntryUsed = false

    init(coordinator: ApplePlaybackCoordinator = .forBrowsing(),
         streamProbe: AppleIPTVStreamProbe = AppleIPTVStreamProbe(),
         hangMonitor: AppleHangMonitor = .shared) {
        self.coordinator = coordinator
        self.streamProbe = streamProbe
        self.hangMonitor = hangMonitor
    }

    func request(for channel: AppleIPTVChannel, programme: AppleIPTVProgramme?) -> ApplePlaybackRequest {
        var request = programme.flatMap { AppleIPTVCatchUp.playbackRequest(for: channel, programme: $0) }
            ?? channel.playbackRequest()
        request.iptvConnectionWaited = connectionWaitedChannelID == channel.id
        return request
    }

    func beginSelection(programme: AppleIPTVProgramme?, shareSelection: Bool) {
        if shareSelection { resumePending = false }
        coordinator.stop()
        connectionWaitedChannelID = nil
        pendingProbe = nil
        failedProbe = nil
        probeFailureMessage = nil
        self.programme = programme
    }

    func closeFullScreen(maximumConnections: Int?) {
        guard maximumConnections == 1 else { return }
        coordinator.stop()
        connectionWaitedChannelID = nil
        pendingProbe = nil
        failedProbe = nil
        probeFailureMessage = nil
        channel = nil
        programme = nil
        fullScreenRevision = 0
        resumePending = false
    }

    /// F12: zap → first picture, one `live first picture` trace line per tune.
    /// The guide marks a tune before its preflight and the player again when
    /// it opens the stream; a recent earlier mark for the same channel stands.
    /// A tune left for another channel before its picture is logged as abandoned.
    func markTuneStarted(_ channel: AppleIPTVChannel) {
        let now = ContinuousClock.now
        if let tune {
            if tune.id == channel.id, now - tune.startedAt < .seconds(30) { return }
            if tune.id != channel.id {
                appleTrace("live first picture \(tune.id) abandoned \(Self.milliseconds(now - tune.startedAt)) ms")
            }
        }
        tune = (channel.id, now)
    }

    func notePlaybackPhase(_ phase: ApplePlaybackPhase) {
        guard let tune else { return }
        switch phase {
        case .playing:
            appleTrace("live first picture \(tune.id) \(Self.milliseconds(ContinuousClock.now - tune.startedAt)) ms")
            self.tune = nil
        case .failed:
            appleTrace("live first picture \(tune.id) failed")
            self.tune = nil
        default:
            break
        }
    }

    private static func milliseconds(_ duration: Duration) -> Int { Int(duration / .milliseconds(1)) }

    /// Arms the resume on the first Live entry of this launch only; later
    /// visits to the tab open on the guide (Paramount+).
    func enterLive() {
        refreshScreenLabel()
        AppleInteractionTrace.record(.screen, "live appeared")
        guard !Self.launchEntryUsed else { return }
        Self.launchEntryUsed = true
        resumePending = true
    }

    func refreshScreenLabel() {
        hangMonitor.screenAppeared("live")
    }

    func resolvePendingProbe() async -> ProbeOutcome {
        guard let request = pendingProbe else { return .superseded }
        do {
            try await coordinator.iptvAccounts.waitForAvailableConnection(sourceID: request.channel.sourceID,
                clock: coordinator.clock)
            try Task.checkCancellation()
            guard pendingProbe?.id == request.id else { return .superseded }
            let result = try await streamProbe.validate(channel: request.channel)
            try Task.checkCancellation()
            guard pendingProbe?.id == request.id else { return .superseded }
            appleTrace("live preflight: HTTP \(result.statusCode), \(result.mediaKind.rawValue)")
            probedKinds[request.channel.id] = result.mediaKind
            connectionWaitedChannelID = request.channel.id
            pendingProbe = nil
            programme = request.programme
            return .ready(ProbeRequest(channel: request.channel.withProbedMediaKind(result.mediaKind),
                shareSelection: request.shareSelection, present: request.present, programme: request.programme))
        } catch {
            guard !Task.isCancelled, pendingProbe?.id == request.id else { return .superseded }
            pendingProbe = nil
            failedProbe = request
            probeFailureMessage = error.localizedDescription
            appleTrace("live preflight failed: \(String(describing: type(of: error)))")
            return .failed(request)
        }
    }

    func resumeTarget(enabled: Bool, active: Bool, watchedIDs: [String], availableIDs: Set<String>,
                      lastWatchedAt: Date?, now: Date = Date()) -> String? {
        guard resumePending else { return nil }
        guard enabled, !watchedIDs.isEmpty,
              AppleLiveZappingPolicy.isWithinResumeWindow(lastWatchedAt, now: now) else {
            resumePending = false
            return nil
        }
        guard let id = AppleLiveZappingPolicy.resumeTarget(enabled: enabled, liveTabActive: active,
            watchedIDs: watchedIDs, availableIDs: availableIDs, lastWatchedAt: lastWatchedAt, now: now) else { return nil }
        resumePending = false
        return id
    }

    func previousID(currentID: String, programme: AppleIPTVProgramme?, history: AppleLiveWatchHistory,
                    availableIDs: Set<String>) -> String? {
        guard programme == nil else { return nil }
        return history.previous(currentID: currentID, availableIDs: availableIDs)
    }
}
