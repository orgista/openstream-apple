import Foundation

/// Pure selection inputs captured during Discover's off-render recommendation pass.
enum AppleHeroMixPolicy {
    struct State: Sendable {
        var meaningfulProgress = false
        var completed = false
        var disliked = false

        mutating func merge(_ other: Self) {
            meaningfulProgress = meaningfulProgress || other.meaningfulProgress
            completed = completed || other.completed
            disliked = disliked || other.disliked
        }
    }

    struct Candidate: Sendable {
        let id: String
        var resumeAt: Date? = nil
        var isResume = false
        var relevant = false
        var releaseDate: Date? = nil
        var state = State()
        var accessible = true
        var hasBackdrop = true
        var unseen: Bool { !isResume && resumeAt == nil && !state.meaningfulProgress && !state.completed }
    }

    /// Values arrive in today's fallback order, already represented by canonical title+kind.
    static func select(_ values: [Candidate], now: Date) -> [String] {
        let eligible = values.filter { $0.accessible && !$0.state.disliked }
        let withArt = eligible.filter(\.hasBackdrop)
        let pool = withArt.isEmpty ? eligible : withArt
        var result: [String] = []
        var seen = Set<String>()
        func append(_ value: Candidate) {
            guard result.count < AppleHeroRotation.maximumCandidates, seen.insert(value.id).inserted else { return }
            result.append(value.id)
        }
        let resumes = pool.filter { $0.isResume || $0.resumeAt != nil }.sorted {
            if $0.resumeAt != $1.resumeAt { return ($0.resumeAt ?? .distantPast) > ($1.resumeAt ?? .distantPast) }
            return $0.id < $1.id
        }
        if let lead = resumes.first { append(lead) }
        var picks = 0
        for value in pool where value.unseen && value.relevant && !seen.contains(value.id) {
            guard picks < 2 else { break }
            append(value)
            picks += 1
        }
        let releases = pool.filter {
            guard $0.unseen, !seen.contains($0.id), let date = $0.releaseDate else { return false }
            return date <= now && now.timeIntervalSince(date) <= 90 * 86_400
        }.sorted {
            if $0.releaseDate != $1.releaseDate { return ($0.releaseDate ?? .distantPast) > ($1.releaseDate ?? .distantPast) }
            return $0.id < $1.id
        }
        if let release = releases.first { append(release) }
        for value in pool { append(value) }
        return result
    }

    static func fairlyGather<Value>(_ sections: [[Value]]) -> [Value] {
        var result: [Value] = []
        for index in 0..<(sections.map(\.count).max() ?? 0) {
            for section in sections where index < section.count { result.append(section[index]) }
        }
        return result
    }

    static let releaseDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }()

    /// A strict calendar day or ISO timestamp, never a year or a fabricated January 1.
    static func releaseDate(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), raw.count >= 10 else { return nil }
        let day = String(raw.prefix(10))
        let formatter = releaseDayFormatter
        guard let date = formatter.date(from: day), formatter.string(from: date) == day else { return nil }
        if raw.count == 10 { return date }
        guard raw.dropFirst(10).first == "T" else { return nil }
        return AppleHeroBadge.releaseDate(raw)
    }

    static func watchState(progress: [ApplePlaybackProgress], completed: Bool,
                           recordProgress: Double?, disliked: Bool) -> State {
        let valid = progress.filter { $0.position.isFinite && $0.duration.isFinite && $0.duration > 0 }
        let fraction = recordProgress.flatMap { $0.isFinite ? $0 : nil } ?? 0
        return State(meaningfulProgress: fraction >= 0.05 || valid.contains {
            $0.isComplete || $0.position >= 60 || $0.position / $0.duration >= 0.05
        }, completed: completed || fraction >= ApplePlaybackProgress.completionFraction || valid.contains { $0.isComplete },
                     disliked: disliked)
    }
}
