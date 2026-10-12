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
    @ObservationIgnored private let streamProbe: AppleIPTVStreamProbe

    init(coordinator: ApplePlaybackCoordinator = ApplePlaybackCoordinator(),
         streamProbe: AppleIPTVStreamProbe = AppleIPTVStreamProbe()) {
        self.coordinator = coordinator
        self.streamProbe = streamProbe
    }

    func request(for channel: AppleIPTVChannel, programme: AppleIPTVProgramme?) -> ApplePlaybackRequest {
        if let programme, let archive = AppleIPTVCatchUp.playbackRequest(for: channel, programme: programme) {
            return archive
        }
        return channel.playbackRequest()
    }

    func beginSelection(programme: AppleIPTVProgramme?, shareSelection: Bool) {
        if shareSelection { resumePending = false }
        coordinator.stop()
        pendingProbe = nil
        failedProbe = nil
        probeFailureMessage = nil
        self.programme = programme
    }

    func resolvePendingProbe() async -> ProbeOutcome {
        guard let request = pendingProbe else { return .superseded }
        do {
            let result = try await streamProbe.validate(channel: request.channel)
            try Task.checkCancellation()
            guard pendingProbe?.id == request.id else { return .superseded }
            appleTrace("live preflight: HTTP \(result.statusCode), \(result.mediaKind.rawValue)")
            probedKinds[request.channel.id] = result.mediaKind
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

    func resumeTarget(enabled: Bool, active: Bool, watchedIDs: [String], availableIDs: Set<String>) -> String? {
        guard resumePending else { return nil }
        guard enabled, !watchedIDs.isEmpty else { resumePending = false; return nil }
        guard let id = AppleLiveZappingPolicy.resumeTarget(enabled: enabled, liveTabActive: active,
            watchedIDs: watchedIDs, availableIDs: availableIDs) else { return nil }
        resumePending = false
        return id
    }

    func previousID(currentID: String, programme: AppleIPTVProgramme?, history: AppleLiveWatchHistory,
                    availableIDs: Set<String>) -> String? {
        guard programme == nil else { return nil }
        return history.previous(currentID: currentID, availableIDs: availableIDs)
    }

    func zapTarget(currentID: String, programme: AppleIPTVProgramme?, orderedIDs: [String],
                   direction: AppleLiveZappingPolicy.Direction) -> String? {
        guard programme == nil else { return nil }
        return AppleLiveZappingPolicy.target(currentID: currentID, orderedIDs: orderedIDs, direction: direction)
    }
}
