import Foundation

/// Collapses raw playback candidates into the short list of choices the
/// in-player "Other sources" sheet shows by default.
///
/// The sheet used to list one row per candidate the resolver returned —
/// "[TB+] Add-on 1080p · via Add-on TB" repeated five times, because five
/// providers happened to answer with the same quality, each headed by the
/// add-on's internal cache-status tag, which means nothing to a viewer
/// (owner 2026-09-15, from a screenshot of the list: "find a better gui
/// cleans and simpler and less sources like example 1 4k dv selection but
/// the backend will chose the best source of that specific stream i.e.
/// Local or Stream 4k etc"). A viewer picks a quality, not a URL.
///
/// This groups candidates by what the stream IS — resolution and dynamic
/// range, plus local vs. remote, since a local file is meaningfully faster
/// than any stream at the same quality — and keeps only the first member of
/// each group. `AppleStremioPlaybackResolver.rankedCandidates` has already
/// sorted candidates best-first within equal quality, so "first" is already
/// "the backend's best pick" for that choice; nothing here re-ranks streams.
public enum AppleStreamSourceGrouping: Sendable {
    /// Enough about one candidate to classify it, without depending on its
    /// final display title: text to scan for resolution/dynamic-range
    /// markers (the caller assembles this from structured fields such as
    /// `qualityDescription`/`filename` where those exist, only falling back
    /// to a title when nothing else is available — see the local-file case
    /// in `AppleDiscoverView.configuredSources`), and whether it plays from
    /// local storage rather than a remote add-on.
    public struct Candidate: Sendable {
        public let text: String
        public let isLocal: Bool

        public init(text: String, isLocal: Bool) {
            self.text = text
            self.isLocal = isLocal
        }
    }

    /// One row the sheet should offer, and the index (into the array passed
    /// to `choices(for:)`) of the specific candidate to play when the viewer
    /// picks it.
    public struct Choice: Sendable, Equatable {
        public let title: String
        public let index: Int
    }

    private enum DynamicRange: Int, Comparable {
        case standard, hdr, dolbyVision
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private struct Bucket {
        let isLocal: Bool
        let resolution: Int
        let range: DynamicRange
        let index: Int
    }

    /// Groups `candidates` by (local, resolution, dynamic range), best group
    /// first: local ahead of remote, then highest resolution, then Dolby
    /// Vision ahead of HDR ahead of plain. Order within a tie is the order
    /// `candidates` arrived in, so ties among equally-ranked remote streams
    /// keep the resolver's own ordering.
    public static func choices(for candidates: [Candidate]) -> [Choice] {
        var buckets: [String: Bucket] = [:]
        var keyOrder: [String] = []
        for (index, candidate) in candidates.enumerated() {
            let resolution = AppleStremioCandidateRanking.resolution(candidate.text)
            let range = dynamicRange(in: candidate.text)
            let key = "\(candidate.isLocal)-\(resolution)-\(range.rawValue)"
            guard buckets[key] == nil else { continue }
            buckets[key] = Bucket(isLocal: candidate.isLocal, resolution: resolution, range: range, index: index)
            keyOrder.append(key)
        }
        return keyOrder.compactMap { buckets[$0] }
            .sorted { lhs, rhs in
                if lhs.isLocal != rhs.isLocal { return lhs.isLocal }
                if lhs.resolution != rhs.resolution { return lhs.resolution > rhs.resolution }
                return lhs.range > rhs.range
            }
            .map { Choice(title: title(for: $0), index: $0.index) }
    }

    /// Strips a leading add-on cache-status tag such as `[TB+]` or `[RD]`
    /// from a title. These are the add-on's own shorthand for which cached
    /// service produced the stream, not something a viewer chose or can act
    /// on (owner: "maybe remove the [tb+]").
    public static func strippingProviderTag(from title: String) -> String {
        title.replacingOccurrences(of: #"^(?:\s*\[[^\]]{1,20}\]\s*)+"#, with: "", options: .regularExpression)
    }

    private static func title(for bucket: Bucket) -> String {
        guard bucket.resolution != 0 || bucket.range != .standard else {
            return bucket.isLocal ? "Local" : "Standard"
        }
        var title = label(forResolution: bucket.resolution)
        switch bucket.range {
        case .dolbyVision: title += " Dolby Vision"
        case .hdr: title += " HDR"
        case .standard: break
        }
        return bucket.isLocal ? "Local · \(title)" : title
    }

    private static func label(forResolution resolution: Int) -> String {
        switch resolution {
        case 4320: return "8K"
        case 2160: return "4K"
        case 0: return "Standard"
        default: return "\(resolution)p"
        }
    }

    private static func dynamicRange(in text: String) -> DynamicRange {
        let lower = text.lowercased()
        if lower.range(of: #"\b(?:dv|dovi|dolby[ ._-]?vision)\b"#, options: .regularExpression) != nil { return .dolbyVision }
        if lower.range(of: #"\bhdr(?:10\+?)?\b"#, options: .regularExpression) != nil { return .hdr }
        return .standard
    }
}
