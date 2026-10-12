import Foundation

/// Whether a release name is for the title being played at all.
///
/// Owner, 2026-09-17, "episode 1 still loads the wrong show": Torrentio
/// answered `tt31091039:1:1` (The Secret Lives of Mormon Wives) with twelve
/// streams, seven of them for *other* shows — "Secret Lives of Gypsy Wives
/// S01E01", "Secret Sex Lives of Tyrants S01E01". Every one of them states
/// S01E01, so the episode rule cannot tell them apart, and the best-seeded
/// Gypsy Wives release won on quality. The fix is to read the title too.
///
/// Conservative like the episode rule: a name that says nothing recognisable
/// (a hash, two words) is not a contradiction; a real release name that lacks
/// the title's own words is. Titles with a colon are matched on their best
/// part, because releases of "Star Wars: Andor" are named "Andor".
public enum AppleMediaTitleMatch {
    static let stopwords: Set<String> = ["the", "a", "an", "of", "and", "in", "on", "at", "to", "for", "with", "vs", "by", "from", "part"]

    public static func normalize(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// The words that carry a title, per colon-separated part.
    static func significantParts(of title: String) -> [[String]] {
        title.split(separator: ":").map { part in
            normalize(String(part)).filter { !stopwords.contains($0) }
        }.filter { !$0.isEmpty }
    }

    /// True when `text` is a real release name (three or more alphabetic
    /// words) and no part of `title` is fully present in it.
    public static func contradicts(_ text: String, title: String) -> Bool {
        let words = normalize(text)
        guard words.filter({ $0.rangeOfCharacter(from: .letters) != nil }).count >= 3 else { return false }
        let parts = significantParts(of: title)
        guard !parts.isEmpty else { return false }
        let present = Set(words)
        return !parts.contains { part in part.allSatisfy(present.contains) }
    }

    // MARK: - Another edition of the same name

    /// Full test 2026-09-30: Saturday Night Live S1 E1 (1975) played
    /// "Saturday Night Live UK S01E01". Every word of the title is in that
    /// name, so `contradicts` passes it; what gives it away is the word right
    /// after the title. Country tags are how release names tell editions of a
    /// show apart ("The Office UK", "Shameless US").
    static let editionQualifiers: Set<String> = [
        "uk", "us", "usa", "au", "aus", "australia", "nz", "ca", "canada", "ie", "ireland",
    ]

    /// What a release name says straight after the title.
    enum Tail: Equatable {
        /// The title, then an episode, quality or other release tag.
        case bare
        /// The title, then a country tag the title itself does not carry.
        case qualifier(String)
        /// The title, then a year (not a daily show's date).
        case year(Int)
        /// The title was not found as a run of words, or nothing follows it.
        case unknown
    }

    /// "U K", "U.K." and "U.S.A." arrive as single letters once split; they
    /// are the same country tags as "UK" and "USA" (iPhone 27 v2 re-run:
    /// "Saturday Night Live U K S01E01" still won S1 E1 of the 1975 show).
    static func joiningSpelledTags(_ words: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < words.count {
            var end = index
            while end < words.count, words[end].count == 1, words[end].first?.isLetter == true { end += 1 }
            let joined = words[index..<end].joined()
            if end - index >= 2, editionQualifiers.contains(joined) {
                result.append(joined)
                index = end
            } else {
                result.append(words[index])
                index += 1
            }
        }
        return result
    }

    static func tail(of text: String, title: String) -> Tail {
        let words = joiningSpelledTags(normalize(text))
        let full = joiningSpelledTags(normalize(title))
        let candidates = [full] + title.split(separator: ":").map { joiningSpelledTags(normalize(String($0))) }
        for titleWords in candidates where titleWords.count >= 1 && titleWords.joined().count >= 3 {
            guard let start = firstRun(of: titleWords, in: words) else { continue }
            let nextIndex = start + titleWords.count
            guard nextIndex < words.count else { return .unknown }
            let next = words[nextIndex]
            if editionQualifiers.contains(next), !full.contains(next) { return .qualifier(next) }
            if next.count == 4, let year = Int(next), (1900...2100).contains(year) {
                // "Show 2024 10 05" is a daily show's air date, not the show's year.
                let after = words.dropFirst(nextIndex + 1).prefix(2)
                if after.count == 2, after.allSatisfy({ $0.count <= 2 && Int($0) != nil }) { return .unknown }
                return .year(year)
            }
            return .bare
        }
        return .unknown
    }

    private static func firstRun(of run: [String], in words: [String]) -> Int? {
        guard !run.isEmpty, words.count >= run.count else { return nil }
        for start in 0...(words.count - run.count) where Array(words[start..<(start + run.count)]) == run {
            return start
        }
        return nil
    }

    /// Per release name, whether it is for something other than `title`
    /// (`year` when known):
    /// - `contradicts` — the title's words are missing;
    /// - a year straight after the title more than a year off `year`;
    /// - a country tag straight after the title, **but only when another
    ///   name has the title untagged** — with nothing to compare against
    ///   ("The Office UK" vs "The Office US") the tag says nothing about
    ///   which one was asked for, so nothing is demoted;
    /// - for an episode (`season` known), any year in the name that season
    ///   could not have aired in (`airYearConflicts`).
    public static func mismatches(_ texts: [String], title: String, year: Int? = nil, season: Int? = nil) -> [Bool] {
        let tails = texts.map { tail(of: $0, title: title) }
        let airYears = texts.map { airYearConflicts($0, year: year, season: season) }
        func yearConflicts(_ found: Int) -> Bool { year.map { abs($0 - found) > 1 } ?? false }
        let hasUntagged = zip(tails, airYears).contains { tail, airYear in
            guard !airYear else { return false }
            switch tail {
            case .bare: return true
            case .year(let found): return !yearConflicts(found)
            default: return false
            }
        }
        return zip(zip(texts, tails), airYears).map { pair, airYear in
            let (text, tail) = pair
            if contradicts(text, title: title) { return true }
            if airYear { return true }
            switch tail {
            case .qualifier: return hasUntagged
            case .year(let found): return yearConflicts(found)
            case .bare, .unknown: return false
            }
        }
    }

    /// True when `text` names a year season `season` of a show first aired in
    /// `year` cannot have aired in: before the year before it, or after
    /// `year + season + 1`. "Saturday Night Live U K S01E01 … March 21 2026"
    /// is not season 1 of the 1975 show. Daily shows numbered by year
    /// (season 2024) and anything without a year or season say nothing.
    static func airYearConflicts(_ text: String, year: Int?, season: Int?) -> Bool {
        guard let year, let season, (1...200).contains(season) else { return false }
        let earliest = year - 1, latest = year + season + 1
        return normalize(text).contains { word in
            guard word.count == 4, let found = Int(word), (1920...2100).contains(found) else { return false }
            return found < earliest || found > latest
        }
    }
}

public typealias AppleStremioTitleMatch = AppleMediaTitleMatch
