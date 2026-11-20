import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class ApplePlaybackStartup {
    enum Phase: Equatable { case idle, resolving, starting, ready, timedOut }

    private static let startupLog = OSLog(subsystem: "com.orgista.openstream", category: "PlaybackStartup")

    static let connectionFeedbackDelay: Duration = .seconds(5)
    static let timeout: Duration = .seconds(30)

    let id = UUID()
    private(set) var requestID: UUID?
    private(set) var phase: Phase
    private(set) var isPresented = false
    private(set) var showsConnectionStatus = false

    init(starting: Bool = false) {
        phase = starting ? .starting : .idle
        requestID = starting ? UUID() : nil
    }

    var isLoading: Bool { phase == .resolving || phase == .starting }
    var isAwaitingFirstFrame: Bool { isLoading || phase == .timedOut }
    var hasPresentedFrame: Bool { phase == .ready }
    var resolutionID: UUID? { phase == .resolving ? requestID : nil }

    func needsPresentation(hasPlayer: Bool) -> Bool {
        hasPlayer || isLoading || phase == .timedOut
    }

    func coversPicture(phase: ApplePlaybackPhase, isClosing: Bool = false) -> Bool {
        isClosing || isLoading || (!hasPresentedFrame && phase == .idle)
    }

    func showsReconnecting(_ reconnecting: Bool) -> Bool {
        reconnecting && hasPresentedFrame
    }

    func presentationWillAppear() { isPresented = true }
    func presentationDidDismiss() { isPresented = false }

    func begin(_ requestID: UUID) {
        self.requestID = requestID
        showsConnectionStatus = false
        phase = .resolving
        presentationWillAppear()
        os_signpost(.event, log: Self.startupLog, name: "PlaybackResolving")
        appleTrace("playback startup resolving")
        AppleForegroundOpening.hold(for: AppleForegroundOpening.playerHold)
    }

    func handOff() {
        if requestID == nil { requestID = UUID() }
        phase = .starting
        presentationWillAppear()
        os_signpost(.event, log: Self.startupLog, name: "PlaybackEngineHandoff")
        appleTrace("playback startup engine handoff")
        AppleForegroundOpening.hold(for: AppleForegroundOpening.playerHold)
    }

    @discardableResult
    func showConnectionStatus(for requestID: UUID?) -> Bool {
        guard requestID == self.requestID, isLoading else { return false }
        showsConnectionStatus = true
        return true
    }

    @discardableResult
    func timeOut(for requestID: UUID?) -> Bool {
        guard requestID == self.requestID, isLoading else { return false }
        phase = .timedOut
        appleTrace("playback startup timed out")
        return true
    }

    func waitForTimeout(for requestID: UUID?, after timeout: Duration = ApplePlaybackStartup.timeout) async -> Bool {
        do { try await Task.sleep(for: timeout) } catch { return false }
        return timeOut(for: requestID)
    }

    func observe(_ phase: ApplePlaybackPhase, route: ApplePlaybackPresentationRoute,
                 readyForDisplay: Bool, for requestID: UUID?) {
        guard requestID == self.requestID, isAwaitingFirstFrame else { return }
        switch phase {
        case .loading, .waiting, .playing, .paused:
            let audioReady = route == .audioOnly && (phase == .playing || phase == .paused)
            if audioReady || (route != .none && route != .audioOnly && readyForDisplay) {
                self.phase = .ready
                if !audioReady {
                    os_signpost(.event, log: Self.startupLog, name: "PlaybackFirstVideoFrame")
                    appleTrace("first frame, route=\(route)")
                }
                appleTrace("playback startup first frame ready")
                AppleForegroundOpening.release()
            }
        case .failed, .ended:
            cancel()
        case .idle, .resolving:
            break
        }
    }

    func cancel() {
        appleTrace("playback startup closed phase=\(phase)")
        phase = .idle
        showsConnectionStatus = false
        requestID = nil
    }
}
