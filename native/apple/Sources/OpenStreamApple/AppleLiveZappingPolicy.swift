import Foundation

enum AppleLiveZappingPolicy {
    enum Direction: Equatable, Sendable { case next, previous }
    enum Input: Sendable { case up, down, select, longSelect }
    enum Action: Equatable, Sendable { case zap(Direction), showInfo, showOptions, navigate }

    static func action(_ input: Input, infoVisible: Bool = false, multiview: Bool = false) -> Action {
        guard !multiview, !infoVisible else { return .navigate }
        switch input {
        case .up: return .zap(.next)
        case .down: return .zap(.previous)
        case .select: return .showInfo
        case .longSelect: return .showOptions
        }
    }

    static func swipe(horizontal: Double, vertical: Double) -> Direction? {
        guard horizontal.isFinite, vertical.isFinite, abs(vertical) >= 60,
              abs(vertical) > abs(horizontal) * 1.5 else { return nil }
        return vertical < 0 ? .next : .previous
    }

    /// The last channel resumes only inside this window; older than this,
    /// Live opens on the guide.
    static let resumeWindow: TimeInterval = 30 * 60

    static func isWithinResumeWindow(_ lastWatchedAt: Date?, now: Date) -> Bool {
        guard let lastWatchedAt else { return false }
        return now.timeIntervalSince(lastWatchedAt) <= resumeWindow
    }

    static func resumeTarget(enabled: Bool, liveTabActive: Bool, watchedIDs: [String], availableIDs: Set<String>,
                             lastWatchedAt: Date?, now: Date = Date()) -> String? {
        guard enabled, liveTabActive, isWithinResumeWindow(lastWatchedAt, now: now) else { return nil }
        return watchedIDs.first { availableIDs.contains($0) }
    }

    static func guideNeighborhood(currentID: String, orderedIDs: [String], radius: Int = 20) -> [String] {
        let radius = max(1, radius)
        guard let index = orderedIDs.firstIndex(of: currentID) else {
            return [currentID] + orderedIDs.prefix(2 * radius - 1)
        }
        return Array(orderedIDs[max(0, index - radius)..<min(orderedIDs.count, index + radius)])
    }

    /// Up/Down presses are collected and tuned once, this long after the
    /// last one. One-connection IPTV providers stall when every press opens
    /// a stream.
    static let coalesceDelay: Duration = .milliseconds(400)

    /// Takes the guide's final projected order, after package/hidden/favorite
    /// filters. Wrap at the ends, and never reopen a lone current channel.
    static func target(currentID: String, orderedIDs: [String], direction: Direction) -> String? {
        guard !orderedIDs.isEmpty else { return nil }
        let index = orderedIDs.firstIndex(of: currentID)
        let target: String
        if let index {
            let offset = direction == .next ? 1 : -1
            target = orderedIDs[(index + offset + orderedIDs.count) % orderedIDs.count]
        } else {
            target = direction == .next ? orderedIDs[0] : orderedIDs[orderedIDs.count - 1]
        }
        return target == currentID ? nil : target
    }

    /// A channel asked for from outside the guide (a link, Siri, a widget)
    /// is handled as soon as the saved lineup knows it, not after the
    /// network refresh. Waiting let the strip start the last channel first
    /// and the request then restarted it (test iPhone, 2026-10-06).
    static func handlesRequest(isLoading: Bool, channelIsKnown: Bool) -> Bool {
        channelIsKnown || !isLoading
    }

    /// Asking again for the live channel that is already starting or playing
    /// brings its player forward instead of reopening the stream. Reopening
    /// cut a slow Xtream channel off 4 s into its start, so it never played.
    static func keepsCurrentAttempt(requestedID: String, selectedID: String?, isCatchUp: Bool,
                                    phase: ApplePlaybackPhase) -> Bool {
        guard requestedID == selectedID, !isCatchUp else { return false }
        switch phase {
        case .resolving, .loading, .waiting, .playing, .paused: return true
        case .idle, .ended, .failed: return false
        }
    }
}
