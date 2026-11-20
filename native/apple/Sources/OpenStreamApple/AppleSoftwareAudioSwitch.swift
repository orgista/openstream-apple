import Observation

@Observable
final class AppleSoftwareAudioSwitch {
    struct Selection: Equatable {
        let trackID: Int
        var position: Double
    }

    static let timeout: Duration = .seconds(30)
    private(set) var selection: Selection?
    private(set) var pauseRequested = false
    private(set) var awaitsLatePlayback = false
    private var restoring = false

    func begin(trackID: Int, position: Double, paused: Bool) {
        selection = Selection(trackID: trackID, position: position)
        pauseRequested = paused
        awaitsLatePlayback = false
        restoring = false
    }

    func play() {
        pauseRequested = false
        awaitsLatePlayback = false
    }

    /// A rejected selection cannot defer Pause behind a frame that will never arrive.
    func pause(activeTrackID: Int?, isLoading: Bool = false) -> Bool {
        pauseRequested = true
        return selection == nil || (!isLoading && selection?.trackID != activeTrackID)
    }

    func userSeek(to seconds: Double) {
        selection?.position = seconds
        restoring = false
    }

    func restore(activeTrackID: Int?, hasClock: Bool) -> Selection? {
        guard !restoring, let selection, selection.trackID == activeTrackID,
              hasClock else { return nil }
        restoring = true
        return selection
    }

    func finish(awaitingLatePlayback: Bool = false) -> Bool {
        guard selection != nil else { return false }
        selection = nil
        awaitsLatePlayback = awaitingLatePlayback && pauseRequested
        restoring = false
        return pauseRequested
    }

    func timeOut() -> Bool {
        guard selection != nil else { return false }
        pauseRequested = true
        return finish(awaitingLatePlayback: true)
    }

    func consumeLatePause() -> Bool {
        guard awaitsLatePlayback else { return false }
        awaitsLatePlayback = false
        return pauseRequested
    }

    func reset() {
        _ = finish()
        pauseRequested = false
        awaitsLatePlayback = false
    }
}
