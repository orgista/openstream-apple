import Foundation

/// Which in-progress titles Continue Watching lists and in what order — one
/// rule for Discover's row and the Top Shelf snapshot.
enum AppleContinueWatchingResolver {
    static let refreshDelay: Duration = .milliseconds(500)

    /// Incoming membership is authoritative; the freshest activity leads after every refresh.
    /// Keep a newer current value when an older asynchronous response arrives.
    static func merge<Value, Stamp: Comparable>(_ current: [Value], incoming: [Value],
        id: (Value) -> String, timestamp: (Value) -> Stamp) -> [Value] {
        let incomingIDs = Set(incoming.map(id))
        var values: [String: Value] = [:]
        for value in current + incoming where incomingIDs.contains(id(value)) {
            let key = id(value)
            if let previous = values[key], timestamp(previous) > timestamp(value) { continue }
            values[key] = value
        }
        return values.values.sorted {
            let first = timestamp($0), second = timestamp($1)
            return first == second ? id($0) < id($1) : first > second
        }
    }

    /// How many titles a Continue Watching row shows.
    static let maximumCount = 12

    static func rail<Value>(_ entries: [Value]) -> [Value] {
        Array(entries.prefix(maximumCount))
    }

    static func hasFullList(count: Int) -> Bool { count > maximumCount }

    /// Records the viewer is part-way into, most recently watched first.
    ///
    /// Completed series activity stays only while an available successor exists.
    /// Resume deletion does not delete that activity; exhausted series leave.
    static func inProgress(
        _ records: [AppleMediaRecord],
        saved: (AppleMediaRecord) -> ApplePlaybackProgress? = { _ in nil },
        activity: (AppleMediaRecord) -> ApplePlaybackProgress? = { _ in nil },
        successorAvailable: (AppleMediaRecord) -> Bool = { _ in false },
        removedAt: (AppleMediaRecord) -> Date? = { _ in nil },
        watchedAt: (AppleMediaRecord) -> Date
    ) -> [AppleMediaRecord] {
        let unfinished = records.filter {
            let value = saved($0)
            let latest = activity($0) ?? value
            if latest != nil {
                return AppleCompletionPolicy.includes(saved: value, activity: latest,
                    successorAvailable: $0.kind == .series && successorAvailable($0), removedAt: removedAt($0))
            }
            return !AppleContinueWatchingRemovalPolicy.isRemoved(removedAt: removedAt($0), lastPlayedAt: nil)
                && ($0.progress ?? 0) > 0 && ($0.progress ?? 1) < ApplePlaybackProgress.completionFraction
        }
        let dates = Dictionary(unfinished.map { ($0.id, watchedAt($0)) }, uniquingKeysWith: max)
        return unfinished.sorted { lhs, rhs in
            let lhsDate = dates[lhs.id] ?? .distantPast
            let rhsDate = dates[rhs.id] ?? .distantPast
            return lhsDate == rhsDate ? lhs.id < rhs.id : lhsDate > rhsDate
        }
    }

    static func isUpNext(_ record: AppleMediaRecord, saved: ApplePlaybackProgress?,
                         successorAvailable: Bool = false) -> Bool {
        record.kind == .series && AppleCompletionPolicy.includes(saved: nil, activity: saved,
            successorAvailable: successorAvailable, removedAt: nil)
    }

    /// How far along a Continue Watching card's bar is, 0...1, or nil for
    /// none. One rule for Discover's row (both styles) and the Top Shelf.
    ///
    /// A series keeps one saved position, under the show, and names the
    /// episode in `partID`; that is the episode Resume plays
    /// (`AppleTitlePagePolicy.heroEpisode`), so the bar is that episode's,
    /// read from the store. The record's own `progress` is only a copy made
    /// at the last index sync, and a series entry that names no episode, or
    /// a finished one, resumes nothing: Play starts the next episode from the
    /// beginning, so there is no bar. A film is unchanged: its saved
    /// position, else the record's copy.
    static func progress(isSeries: Bool, saved: ApplePlaybackProgress?, recordProgress: Double?) -> Double? {
        guard let saved else {
            return isSeries ? nil : recordProgress.map { min(max($0, 0), 1) }
        }
        if saved.isComplete { return nil }
        if isSeries, saved.partID == nil || saved.resumePosition == nil { return nil }
        guard saved.duration.isFinite, saved.duration > 0 else { return recordProgress }
        return AppleWatchProgress.fraction(position: saved.position, duration: saved.duration)
    }

    /// Whether a record can open its own page: a library file, server
    /// title or channel (`AppleCatalogSearchStore.listsUnmatched`).
    static func isOpenable(_ record: AppleMediaRecord) -> Bool {
        AppleCatalogSearchStore.listsUnmatched(record)
    }
}
