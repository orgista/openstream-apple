/// Which of `AppleMacWindowPresence`'s deferred reports go out: only one that
/// still matches where the view is when it is delivered, and only when it
/// differs from the last one sent.
struct AppleWindowPresenceReports: Equatable, Sendable {
    private(set) var lastReported: Bool?

    /// `present` was true when the move happened; `stillPresent` is where the
    /// view is now. Returns what to send, or nil to send nothing.
    mutating func report(_ present: Bool, stillPresent: Bool) -> Bool? {
        guard present == stillPresent, present != lastReported else { return nil }
        lastReported = present
        return present
    }
}
