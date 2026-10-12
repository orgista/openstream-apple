import Foundation

/// Quality order, preserving provider order when quality is equal.
public enum AppleMediaCandidateRanking {
    public static func rank(_ candidates: [AppleStremioHTTPPlaybackCandidate]) -> [AppleStremioHTTPPlaybackCandidate] {
        ordered(candidates, preferCompatibleWhenUnknown: true)
    }

    /// `episode` is the season and episode being played, when one is. A
    /// candidate whose name states a *different* episode sorts below every
    /// candidate that does not contradict it, however good its resolution.
    public static func rankForAutomaticPlayback(
        _ candidates: [AppleStremioHTTPPlaybackCandidate],
        episode: (season: Int, episode: Int)? = nil,
        title: String? = nil,
        year: Int? = nil
    ) -> [AppleStremioHTTPPlaybackCandidate] {
        ordered(candidates, preferCompatibleWhenUnknown: false, episode: episode, title: title, year: year)
    }

    /// Per candidate, whether its name is for another title or another
    /// edition of it (`AppleStremioTitleMatch.mismatches`). All false
    /// without a title.
    static func titleMismatches(
        _ candidates: [AppleStremioHTTPPlaybackCandidate],
        title: String?,
        year: Int? = nil,
        season: Int? = nil
    ) -> [Bool] {
        guard let title, !title.isEmpty else { return candidates.map { _ in false } }
        let texts = candidates.map { candidate in
            [candidate.filename ?? "", candidate.title, candidate.sourceURL.lastPathComponent].joined(separator: " ")
        }
        return AppleStremioTitleMatch.mismatches(texts, title: title, year: year, season: season)
    }

    /// Whether this candidate is named for a different title altogether.
    static func contradictsTitle(_ candidate: AppleStremioHTTPPlaybackCandidate, title: String) -> Bool {
        let text = [candidate.filename ?? "", candidate.title,
                    candidate.sourceURL.lastPathComponent].joined(separator: " ")
        return AppleStremioTitleMatch.contradicts(text, title: title)
    }

    /// Whether this candidate names an episode other than the one being played.
    static func contradictsEpisode(
        _ candidate: AppleStremioHTTPPlaybackCandidate,
        season: Int,
        episode: Int
    ) -> Bool {
        let text = [candidate.filename ?? "", candidate.title,
                    candidate.qualityDescription ?? "",
                    candidate.sourceURL.lastPathComponent].joined(separator: " ")
        return AppleStremioEpisodeFilenameMatch.contradicts(text, season: season, episode: episode)
    }

    private static func ordered(
        _ candidates: [AppleStremioHTTPPlaybackCandidate],
        preferCompatibleWhenUnknown: Bool,
        episode: (season: Int, episode: Int)? = nil,
        title: String? = nil,
        year: Int? = nil
    ) -> [AppleStremioHTTPPlaybackCandidate] {
        let mismatched = titleMismatches(candidates, title: title, year: year, season: episode?.season)
        let placeholders = candidates.map(AppleStreamPlaceholderPolicy.isPlaceholder)
        return candidates.enumerated().sorted { lhs, rhs in
            // A provider's error clip ("only rar is available") is never the
            // title, so it sorts below everything that might be.
            let lp = placeholders[lhs.offset], rp = placeholders[rhs.offset]
            if lp != rp { return !lp }
            // Demoted rather than dropped: if every candidate contradicts, the
            // viewer still gets something to play rather than nothing.
            // A different show is worse than a different episode, so it sorts first.
            let lw = mismatched[lhs.offset], rw = mismatched[rhs.offset]
            if lw != rw { return !lw }
            if let episode {
                let lw = contradictsEpisode(lhs.element, season: episode.season, episode: episode.episode)
                let rw = contradictsEpisode(rhs.element, season: episode.season, episode: episode.episode)
                if lw != rw { return !lw }
            }
            let l = quality(lhs.element), r = quality(rhs.element)
            if l.0 != r.0 { return l.0 > r.0 }
            if l.1 != r.1 { return l.1 > r.1 }
            // Unknown-quality legacy streams retain their compatibility order.
            if preferCompatibleWhenUnknown && l.0 == 0 && l.1 == 0 {
                let le = extensionPreference(of: lhs.element), re = extensionPreference(of: rhs.element)
                if le != re { return le < re }
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    public static func resolution(_ text: String) -> Int {
        let lower = text.lowercased()
        if lower.range(of: #"\b8k\b"#, options: .regularExpression) != nil { return 4320 }
        if lower.range(of: #"\b(?:4k|uhd)\b"#, options: .regularExpression) != nil { return 2160 }
        guard let range = lower.range(of: #"\b(?:4320|2160|1440|1080|720|576|480)[pi]\b"#, options: .regularExpression) else { return 0 }
        return Int(lower[range].dropLast()) ?? 0
    }

    private static func quality(_ candidate: AppleStremioHTTPPlaybackCandidate) -> (Int, Double) {
        let text = [candidate.qualityDescription ?? candidate.title, candidate.filename ?? "", candidate.sourceURL.lastPathComponent].joined(separator: " ")
        let regex = try? NSRegularExpression(pattern: #"(?i)([0-9]+(?:\.[0-9]+)?)\s*(GB|GiB|MB|MiB)\b"#)
        let ns = text as NSString
        let match = regex?.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
        let size = match.map { (Double(ns.substring(with: $0.range(at: 1))) ?? 0) * (ns.substring(with: $0.range(at: 2)).lowercased().hasPrefix("g") ? 1_000_000_000 : 1_000_000) } ?? 0
        return (resolution(text), candidate.sizeBytes.map(Double.init) ?? size)
    }

    private static func extensionPreference(of candidate: AppleStremioHTTPPlaybackCandidate) -> Int {
        let name = (candidate.filename ?? candidate.sourceURL.lastPathComponent).lowercased()
        guard let dot = name.lastIndex(of: ".") else { return 3 }
        let ext = name[name.index(after: dot)...]
        return switch ext {
        case "mp4", "m4v": 0
        case "mkv": 1
        case "ts", "m2ts", "mts": 2
        default: 3
        }
    }
}

/// Builds an `ApplePlaybackRequest` for a Stremio HTTP candidate without AVAsset
/// inspection. Provider `proxyHeaders.request` values are copied into
/// `hints.proxyHeaders` so the engine attaches them to the media request, and
/// `notWebReady` is forwarded so the engine knows the candidate is engine-only.
extension AppleStremioHTTPPlaybackCandidate {
    public func playbackRequest(
        mediaID: String,
        title: String?,
        resume: Double?,
        addonMediaID: String? = nil,
        addonMediaType: String? = nil,
        expectedRuntime: Double? = nil,
        subtitle: String? = nil,
        releaseYear: Int? = nil,
        artworkURL: URL? = nil
    ) -> ApplePlaybackRequest {
        var request = ApplePlaybackRequest(
            url: sourceURL,
            headers: requestHeaders,
            isLive: false,
            resumePosition: resume,
            mediaID: mediaID,
            title: title ?? self.title,
            sourceName: sourceName.map { "via \($0)" },
            sourceKind: .catalog,
            hints: ApplePlaybackRequest.Hints(
                notWebReady: requiresGateway,
                proxyHeaders: requestHeaders,
                filename: filename,
                addonMediaID: addonMediaID,
                addonMediaType: addonMediaType,
                serviceKey: serviceKey,
                expectedRuntime: expectedRuntime
            )
        )
        request.subtitle = subtitle
        request.releaseYear = releaseYear
        request.artworkURL = artworkURL
        return request
    }
}

public typealias AppleStremioCandidateRanking = AppleMediaCandidateRanking
