import AVFoundation
import Foundation
@testable import OpenStreamApple

@MainActor
final class FakePlaybackEngine: ApplePlaybackEngine {
    var scriptedPhases: [ApplePlaybackEnginePhase] = []
    var scriptedRoute: ApplePlaybackPresentationRoute = .avPlayer
    var failOnLoad: ApplePlaybackFailure?
    var loadedRequests: [ApplePlaybackRequest] = []
    /// When set, `load(_:)` delegates to this handler instead of the
    /// scripted/failOnLoad path so each request can succeed or fail
    /// independently.
    var loadHandler: (@MainActor (ApplePlaybackRequest) async throws -> Void)?
    var seeks: [Double] = []
    var selectedAudio: [Int] = []
    var selectedSubtitle: [Int?] = []
    var externalSubtitleTracks: [AppleExternalSubtitleTrack] = []
    var stopCount: Int = 0

    var kind: ApplePlaybackEngineKind = .openStream
    var phase: ApplePlaybackEnginePhase = .idle
    var route: ApplePlaybackPresentationRoute { scriptedRoute }
    var position: Double = 0
    var duration: Double? = nil
    var audioTracks: [ApplePlaybackTrack] = []
    var subtitleTracks: [ApplePlaybackTrack] = []
    var subtitleCues: [AppleSubtitleCue] = []
    var failure: ApplePlaybackFailure? = nil
    var avPlayer: AVPlayer? { nil }

    private var continuations: [AsyncStream<ApplePlaybackEngineEvent>.Continuation] = []

    var events: AsyncStream<ApplePlaybackEngineEvent> {
        AsyncStream { continuation in
            continuations.append(continuation)
        }
    }

    func script(_ phases: [ApplePlaybackEnginePhase]) {
        scriptedPhases = phases
    }

    func emit(_ event: ApplePlaybackEngineEvent) {
        for continuation in continuations {
            continuation.yield(event)
        }
    }

    func load(_ request: ApplePlaybackRequest) async throws {
        loadedRequests.append(request)
        if let loadHandler {
            try await loadHandler(request)
            return
        }
        if let failure = failOnLoad {
            self.failure = failure
            phase = .error(failure.message)
            emit(.failure(failure))
            throw failure
        }
        for scriptedPhase in scriptedPhases {
            phase = scriptedPhase
            emit(.phase(scriptedPhase))
        }
    }

    func play() { phase = .playing }
    func pause() { phase = .paused }
    func stop() { stopCount += 1; phase = .idle }

    func seek(to seconds: Double) async {
        seeks.append(seconds)
    }

    func selectAudioTrack(id: Int) {
        selectedAudio.append(id)
    }

    func selectSubtitleTrack(id: Int?) {
        selectedSubtitle.append(id)
    }

    func addExternalSubtitleTracks(_ tracks: [AppleExternalSubtitleTrack]) {
        externalSubtitleTracks.append(contentsOf: tracks)
    }
}
