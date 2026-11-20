/// One playback attempt. Pause, buffering and background intervals do not
/// count, and qualifying once cannot continually reorder the history.
struct AppleLiveWatchSession: Sendable {
    private(set) var watchedSeconds: Double = 0
    private var recorded = false

    mutating func advance(seconds: Double, playing: Bool) -> Bool {
        guard !recorded, playing, seconds.isFinite, seconds > 0 else { return false }
        watchedSeconds += seconds
        guard watchedSeconds >= AppleLiveWatchHistory.minimumWatchSeconds else { return false }
        recorded = true
        return true
    }
}
