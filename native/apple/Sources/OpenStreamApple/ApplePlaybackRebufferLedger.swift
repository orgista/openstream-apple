import Foundation

/// The rebuffers of one playback, split the way Infuse splits them (REA round 4,
/// fix 3): a short one that clears within half a second draws nothing; a full
/// one shows the wait and is counted. The owner's phone traced 2 to 8
/// "rebuffering" lines a session, every one of them a spinner, and nothing
/// counted them.
struct ApplePlaybackRebufferLedger {
    static let shortLimit: Duration = .milliseconds(500)

    private(set) var full = 0
    private(set) var short = 0
    private(set) var waited: Duration = .zero
    private var began: ContinuousClock.Instant?
    private var shown = false

    var isWaiting: Bool { began != nil }

    /// Starts a wait; false while one is already open.
    mutating func begin(at now: ContinuousClock.Instant) -> Bool {
        guard began == nil else { return false }
        began = now
        shown = false
        return true
    }

    /// The wait is on screen: a full rebuffer.
    mutating func show() {
        guard began != nil else { return }
        shown = true
    }

    mutating func end(at now: ContinuousClock.Instant) {
        guard let began else { return }
        if shown {
            full += 1
            waited += began.duration(to: now)
        } else {
            short += 1
        }
        self.began = nil
        shown = false
    }

    /// "rebuffers: 2 full (3.4 s waiting), 5 short drew nothing", or nil when there were none.
    var summary: String? {
        guard full + short > 0 else { return nil }
        let seconds = Double(waited.components.seconds) + Double(waited.components.attoseconds) / 1e18
        return "rebuffers: \(full) full (\(String(format: "%.1f", seconds)) s waiting), \(short) short drew nothing"
    }
}
