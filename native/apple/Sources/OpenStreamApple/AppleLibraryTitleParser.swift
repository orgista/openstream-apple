import Foundation
import Synchronization

public struct AppleLibraryTitle: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case movie, show, other }
    public let title: String
    public let year: Int?
    public let season: Int?
    public let episode: Int?
    public let kind: Kind
    public enum Role: String, Sendable { case feature, trailer, featurette, behindTheScenes, deletedScenes, sample, extra }
    public var role: Role = .feature
    public var episodeEnd: Int? = nil
    /// ISO calendar date; no invented season/episode coordinates.
    public var airDate: String? = nil
    public var part: Int? = nil
    public var version: String? = nil
    public var confidence: Double = 0
    public var explicitIDs: [String: String] = [:]
    public struct Alternative: Equatable, Sendable {
        public enum Provenance: String, Sendable { case filename, parentFolder }
        public let title: String
        public let year: Int?
        public let provenance: Provenance
    }
    public var alternatives: [Alternative] = []
    public var episodeNumbers: [Int] {
        guard role == .feature, let episode else { return [] }
        let end = episodeEnd ?? episode
        guard end >= episode, end - episode < 100 else { return [] }
        return Array(episode...end)
    }
}

public enum AppleLibraryTitleParser {
    /// Moves when parsing or matching changes, so cached misses are looked up again.
    static let version = 7
    /// "Open.Season.3.2010…": a numbered "Season" followed by a release year is a film title.
    private static let seasonTitledMovie = #"(?i)\bSeason[ ._-]*\d{1,3}[ ._()\[\]-]+(?:19|20)\d{2}\b"#
    /// Remembered per name and folder: the launch pass, the series grouping and
    /// each match lookup parse the same files again.
    public static func parse(name: String, parentPath: String = "") -> AppleLibraryTitle {
        let key = MemoKey(name: name, parentPath: parentPath)
        if let known = memo.withLock({ $0[key] }) { return known }
        let parsed = parseUncached(name: name, parentPath: parentPath)
        memo.withLock { titles in
            if titles.count >= memoCapacity { titles.removeAll(keepingCapacity: true) }
            titles[key] = parsed
        }
        return parsed
    }

    private struct MemoKey: Hashable { let name: String; let parentPath: String }
    private static let memo = Mutex<[MemoKey: AppleLibraryTitle]>([:])
    private static let memoCapacity = 20_000

    private static func parseUncached(name: String, parentPath: String) -> AppleLibraryTitle {
        let parents = parentPath.split(separator: "/").map(String.init)
        let parentRoles = folderRoles(parents)
        let titleParents = parents.indices.filter { !collectionFolders.contains(parents[$0].lowercased())
            && !prefersParent(parents[$0]) && !isDiscFolder(parents[$0]) && parentRoles[$0] == .feature
        }.map { parents[$0] }
        let stem = removingExtension(name)
        let full = (parents + [stem]).joined(separator: "/")
        let pair = captures(#"(?i)\bS(\d{1,3})[ ._-]*E(\d{1,4})\b|\b(\d{1,3})x(\d{1,4})\b"#, full)
        let episodeWord = captures(#"(?i)\bEpisode[ ._-]*(\d{1,4})\b"#, full).flatMap { Int($0[0]) }
        // Without an episode token, "Season N <year>" in the file name is part of a film title;
        // a folder with that shape is skipped only when the file name carries it too.
        let movieSeason = pair == nil && episodeWord == nil && matches(seasonTitledMovie, stem)
        let seasonText = movieSeason
            ? (parents + [stem]).filter { !matches(seasonTitledMovie, $0) }.joined(separator: "/") : full
        let season = pair.flatMap { Int($0[0]) ?? Int($0[2]) }
            ?? captures(#"(?i)\bSeason[ ._-]*(\d{1,3})\b"#, seasonText).flatMap { Int($0[0]) }
        let episode = pair.flatMap { Int($0[1]) ?? Int($0[3]) } ?? episodeWord
        let rangeEnd = captures(#"(?i)\bS\d{1,3}[ ._-]*E\d{1,4}[ ._]*-[ ._]*(?:E)?(\d{1,4})\b"#, stem).flatMap { Int($0[0]) }
        let dateParts = captures(#"\b((?:19|20)\d{2})[._-](\d{2})[._-](\d{2})\b"#, stem)
        let airDate = dateParts.flatMap { values -> String? in
            guard let year = Int(values[0]), let month = Int(values[1]), let day = Int(values[2]) else { return nil }
            let calendar = Calendar(identifier: .gregorian)
            let components = DateComponents(year: year, month: month, day: day)
            guard let date = calendar.date(from: components),
                  calendar.dateComponents([.year, .month, .day], from: date) == components else { return nil }
            return values.joined(separator: "-")
        }
        let role = parentRoles.first { $0 != .feature } ?? fileRole(stem)
        let isShow = airDate != nil || season != nil || episode != nil || parents.contains { $0.lowercased() == "shows" }
        let part = isShow ? nil : multipartMarker(stem)?.number
        var parsed = clean(stem, movieSeason: movieSeason)
        var selectedFromParent = false
        // A bare 2–4 digit stem (`0001.mkv`, `1917.mkv`) is a disc playlist only
        // when a title folder exists to defer to; with no folder it is the title.
        let stemPrefersParent = prefersParent(stem) && (!isShortNumber(stem) || titleParents.contains { !clean($0, titleFolder: true).0.isEmpty })
        if stemPrefersParent || parentRoles.contains(where: { $0 != .feature }) { parsed = ("", nil) }
        if isShow {
            // Episode filenames may be “Pilot” or “Episode 2”; the series folder
            // keeps every local season on the same card.
            for parent in titleParents.reversed() {
                let candidate = clean(parent, movieSeason: movieSeason, titleFolder: true)
                if !candidate.0.isEmpty { parsed = candidate; selectedFromParent = true; break }
            }
        }
        if parsed.0.isEmpty || (stemPrefersParent && !isShow) {
            parsed = ("", nil)
            for parent in titleParents.reversed() {
                let candidate = clean(parent, movieSeason: movieSeason, titleFolder: true)
                if !candidate.0.isEmpty { parsed = candidate; selectedFromParent = true; break }
            }
        }
        // `parsed` is the stored identity (group id, match record, `local-…`
        // id) and must not move between versions. Search-only normalisation
        // (release prefixes, edition words, hyphens, the folder's year) lives
        // in the alternatives, which only ever feed lookups.
        var alternatives: [AppleLibraryTitle.Alternative] = []
        var filenameSearch: (String, Int?)?
        if !parsed.0.isEmpty, !selectedFromParent {
            let search = clean(stem, forSearch: true, movieSeason: movieSeason)
            filenameSearch = search.0.isEmpty ? parsed : search
        }
        var folderSearch: (String, Int?)?
        for parent in titleParents.reversed() {
            let candidate = clean(parent, forSearch: true, movieSeason: movieSeason, titleFolder: true)
            guard !candidate.0.isEmpty else { continue }
            folderSearch = candidate
            // Only the nearest meaningful title folder is evidence.
            break
        }
        if var search = filenameSearch {
            if search.1 == nil, let folder = folderSearch, folder.0.caseInsensitiveCompare(search.0) == .orderedSame {
                search.1 = folder.1
            }
            alternatives.append(.init(title: search.0, year: search.1, provenance: .filename))
        }
        if let folder = folderSearch { alternatives.append(.init(title: folder.0, year: folder.1, provenance: .parentFolder)) }
        let success = !parsed.0.isEmpty
        var result = AppleLibraryTitle(title: success ? parsed.0 : String(name.prefix(24)) + (name.count > 24 ? "…" : ""),
            year: airDate == nil ? parsed.1 : nil, season: season, episode: episode, kind: success ? (isShow ? .show : .movie) : .other)
        result.episodeEnd = rangeEnd
        result.airDate = airDate
        result.role = role
        result.part = part
        result.version = captures(#"(?i)\b(\d{3,4}p|[48]K|(?:[a-z]+[ ._-]+)?edition)\b"#, stem)?.first?.lowercased()
        result.confidence = rangeEnd.map { $0 < (episode ?? 0) || $0 - (episode ?? 0) >= 100 } == true ? 0 : !success ? 0 : (episode != nil || airDate != nil ? 1 : (isShow ? 0.4 : (parsed.1 != nil ? 0.9 : 0.5)))
        if let id = captures(#"(?i)\b(tt\d{7,10})\b"#, full)?.first { result.explicitIDs["imdb"] = id.lowercased() }
        for provider in ["tmdb", "tvdb"] {
            if let id = captures("(?i)\\b" + provider + "(?:id)?[ :=_-]+([0-9]+)\\b", full)?.first,
               let number = Int(id), number > 0 { result.explicitIDs[provider] = String(number) }
        }
        result.alternatives = alternatives
        return result
    }

    public static func parse(_ item: AppleLibraryItem) -> AppleLibraryTitle {
        parse(name: item.name, parentPath: (item.relativePath as NSString).deletingLastPathComponent)
    }

    static func isSupplemental(_ item: AppleLibraryItem) -> Bool {
        parse(item).role != .feature
    }

    static func episodeTitle(name: String, number: Int) -> String {
        let stem = removingExtension(name)
        let marker = #"(?i)\b(?:S\d{1,3}[ ._-]*E\d{1,4}(?:[ ._]*-[ ._]*E?\d{1,4})?|\d{1,3}x\d{1,4}|Episode[ ._-]*\d{1,4})\b"#
        let suffix = firstRange(marker, in: stem).map { String(stem[$0.upperBound...]) } ?? stem
        let episodeName = suffix.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "._-")))
        let release = #"(?i)^(?:(?:AMZN|NF|DSNP|HMAX|ATVP)[ ._-]+)?(?:WEB[ ._-]?(?:DL|Rip)?|HDTV|BluRay|BDRip)[ ._-]+(?:DDP?[ ._-]?\d(?:[ ._-]\d)?[ ._-]+)?(?:h[ ._-]?26[45]|x26[45]|HEVC|AVC)\b"#
        let title = firstRange(release, in: episodeName) == nil ? clean(episodeName).0 : ""
        return title.isEmpty ? "Episode \(number)" : title
    }

    /// Parses `items` off the main actor, so the main-actor callers that
    /// follow find every answer remembered: the first pass after launch
    /// parsed ~400 files on the main thread (~240 ms on an Apple TV 4K, 2026-10-15).
    @concurrent static func warm(_ items: [AppleLibraryItem]) async {
        for item in items { _ = parse(item) }
    }

    private static let collectionFolders: Set<String> = ["movies", "shows", "tv", "media", "library"]

    private static func folderRoles(_ parents: [String]) -> [AppleLibraryTitle.Role] {
        let start = parents.lastIndex { collectionFolders.contains($0.lowercased()) }.map { $0 + 1 } ?? 0
        var hasTitleFolder = false
        return parents.enumerated().map { index, parent in
            guard index >= start else { return .feature }
            // A collection's first meaningful folder is the title, even when it is called Extras.
            guard hasTitleFolder else {
                if !prefersParent(parent), !isDiscFolder(parent), !clean(parent, titleFolder: true).0.isEmpty {
                    hasTitleFolder = true
                }
                return .feature
            }
            let folder = replacing(#"[._-]+"#, in: parent.lowercased(), with: " ").trimmingCharacters(in: .whitespaces)
            switch folder {
            case "extra", "extras", "bonus", "bonus features": return .extra
            case "trailer", "trailers": return .trailer
            case "featurette", "featurettes": return .featurette
            case "behind the scenes": return .behindTheScenes
            case "deleted scenes": return .deletedScenes
            case "sample", "samples": return .sample
            default: return .feature
            }
        }
    }

    private static func fileRole(_ text: String) -> AppleLibraryTitle.Role {
        let normalized = replacing(#"[._-]+"#, in: text.lowercased(), with: " ")
        for (pattern, role) in [(#"\bbehind the scenes\b"#, AppleLibraryTitle.Role.behindTheScenes),
            (#"\bdeleted scenes\b"#, .deletedScenes), (#"\bfeaturettes?\b"#, .featurette),
            (#"\btrailers?\b"#, .trailer), (#"\bsamples?\b"#, .sample)] {
            if firstRange(pattern + #"(?:$|\s+\d{3,4}p\b)"#, in: normalized) != nil { return role }
        }
        return .feature
    }

    private static func removingExtension(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        return AppleLibraryScanner.supportedExtensions.contains(ext) ? (name as NSString).deletingPathExtension : name
    }

    private static func isHash(_ name: String) -> Bool {
        let value = removingExtension(name).replacingOccurrences(of: "-", with: "")
        return value.count >= 16 && value.allSatisfy { $0.isHexDigit }
    }

    /// A disc rip keeps the playlist's number as its filename — `00526.m2ts`
    /// beside `Fantastic Mr. Fox (2009)`, or `VTS_01_1.VOB` from a DVD. The
    /// number is not a title and the folder above it is, so these defer to the
    /// parent exactly like a hashed name does. A film whose *title* is a number
    /// (1992, 2073, 1917) is unaffected: its filename carries the year and the
    /// release tags too, so the stem is never digits alone.
    private static func isDiscPlaylist(_ name: String) -> Bool {
        // Not `removingExtension`: a disc rip may carry a container the
        // scanner does not list (`.VOB`), and the shape is what matters.
        let value = replacing(#"\.[A-Za-z0-9]{2,4}$"#, in: name, with: "")
        if value.count >= 2, value.allSatisfy(\.isNumber) { return true }
        return firstRange(#"(?i)^(?:VTS[_ ]\d{1,3}[_ ]\d{1,3}|title[_ ]?t?\d{1,3})$"#, in: value) != nil
    }

    private static func isShortNumber(_ name: String) -> Bool {
        let value = replacing(#"\.[A-Za-z0-9]{2,4}$"#, in: name, with: "")
        return value.count < 5 && value.allSatisfy(\.isNumber)
    }

    private static func prefersParent(_ name: String) -> Bool {
        isHash(name) || isDiscPlaylist(name)
    }

    private static func isDiscFolder(_ name: String) -> Bool {
        firstRange(#"(?i)^(?:cd|disc|disk|part)[ ._-]*\d{1,2}$"#, in: name) != nil
    }

    /// Compact tags are file parts. Separated “Part 1” / “Part.1” before
    /// a release year belongs to the title (for example Deathly Hallows).
    /// Separated part tags after a year remain explicit file parts.
    private static func multipartMarker(_ raw: String) -> (range: Range<String.Index>, number: Int)? {
        let pattern = #"(?i)\b(cd|disc|disk|part)([ ._-]*)(\d{1,2})\b"#
        guard let expression = icuRegex(pattern) else { return nil }
        for match in expression.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
            guard let range = Range(match.range, in: raw),
                  let marker = Range(match.range(at: 1), in: raw),
                  let separator = Range(match.range(at: 2), in: raw),
                  let digits = Range(match.range(at: 3), in: raw),
                  let number = Int(raw[digits]), number > 0 else { continue }
            if raw[marker].lowercased() == "part", !raw[separator].isEmpty,
               firstRange(#"\b(?:19|20)\d{2}\b"#, in: String(raw[..<range.lowerBound])) == nil {
                continue
            }
            return (range, number)
        }
        return nil
    }

    /// `forSearch: false` is the identity form and must stay byte-for-byte
    /// what earlier versions produced; new normalisation goes behind `forSearch`.
    private static func clean(_ raw: String, forSearch: Bool = false, movieSeason: Bool = false, titleFolder: Bool = false) -> (String, Int?) {
        let keepsSeason = movieSeason && matches(seasonTitledMovie, raw)
        let titleStem: String
        if let marker = multipartMarker(raw) { titleStem = raw.replacingCharacters(in: marker.range, with: " ") }
        else { titleStem = raw }
        var value = replacing(#"^(?:\s*\[[^\]]*\]\s*)+"#, in: titleStem, with: "")
        if forSearch {
            // Recognized staging and release labels only; never strip arbitrary numbers/groups.
            value = replacing(#"(?i)^ISO-STAGE-\d+-|^sharphd-|^_UNPACK_"#, in: value, with: "")
            value = replacing(#"(?i)^(?:A[ ._]Marvel[ ._]Television[ ._]Special[ ._]Presentation)[ ._]*--[ ._]*"#, in: value, with: "")
            value = replacing(#"(?i)[{\[]?(?:imdb(?:id)?[ :=_-]+tt\d{7,10}|tmdb(?:id)?[ :=_-]+\d+|tvdb(?:id)?[ :=_-]+\d+)[}\]]?"#, in: value, with: " ")
            value = replacing(#"(?i)\b(?:director'?s[ ._-]+cut|extended[ ._-]+(?:cut|edition)|theatrical[ ._-]+cut|unrated|remastered)\b"#, in: value, with: " ")
        }
        // Tracker stamps: "www.UIndex.org    -    Hey Arnold The Movie 2002…".
        // The mandatory " - " after the domain is what keeps this off real
        // titles — "W.A.R - The Movie" and "Dr.No.1962" do not match.
        value = replacing(#"(?i)^\s*(?:www[._])?[a-z0-9-]+[._][a-z]{2,6}\s*-+\s*"#, in: value, with: "")
        value = replacing(#"[._]+"#, in: value, with: " ")
        let year = captures(#"(?<=.)(?<!\d)\b((?:19|20)\d{2})\b"#, value).flatMap { Int($0[0]) }
        // Cut at release metadata, keeping ordinary title words such as “Atmosphere”.
        let supplemental = titleFolder ? "" : #"(?:trailer|featurette|behind[ -]the[ -]scenes|deleted[ -]scenes|sample)(?=\s*$)|"#
        let boundary = #"(?i)\b(?:S\d{1,3}[ -]*E\d{1,4}|\d{1,3}x\d{1,4}|"# + (keepsSeason ? "" : #"Season\s*\d{1,3}\b|"#) + #"Episode\s*\d+|(?:19|20)\d{2}|\d{3,4}p|[48]K|x26[45]|h[ -]?26[45]|HEVC|AVC|WEB[ -]?(?:DL|Rip)|Blu[ -]?Ray|BRRip|BDRip|HDR10\+?|HDR|DV|DOVI|Atmos|DTS|DDP|AAC|AC3|EAC3|REMUX|PROPER|REPACK|(?:[a-z]+[ -]+)?edition|"# + supplemental + #"\{?(?:imdb|tmdb)[ -])\b"#
        if let range = firstRange(boundary, in: value) {
            // A numeric title (1917, 2001) is not a release year at the beginning.
            if range.lowerBound != value.startIndex || Int(value[range]) == nil {
                value = String(value[..<range.lowerBound])
            } else {
                let suffix = String(value[range.upperBound...])
                if let next = firstRange(boundary, in: suffix) {
                    value = String(value[range]) + String(suffix[..<next.lowerBound])
                }
            }
        }
        if forSearch { value = value.replacingOccurrences(of: "-", with: " ") }
        value = replacing(#"\s+"#, in: value, with: " ")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-()[]")))
        return (value, year == Int(value) ? nil : year)
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        firstRange(pattern, in: text) != nil
    }

    private static func captures(_ pattern: String, _ text: String) -> [String]? {
        guard let match = icuRegex(pattern)?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }

    private static func firstRange(_ pattern: String, in text: String) -> Range<String.Index>? {
        stringRegex(pattern).flatMap { text.firstRange(of: $0) }
    }

    private static func replacing(_ pattern: String, in text: String, with template: String) -> String {
        guard let expression = icuRegex(pattern) else { return text }
        return expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    // Every pattern compiled once: compiling them per call was ~0.9 s of a
    // Apple TV launch (2026-10-16). The identity form must not move, so each
    // helper keeps the engine of the call it replaced. `String.range(of:options:
    // .regularExpression)` is Swift `Regex` with simple word boundaries;
    // `replacingOccurrences(…, options: .regularExpression)` and
    // `NSRegularExpression` are ICU. They disagree: ICU misses
    // `\b(?:Season\s*\d{1,3}\b|Episode)\b` in "Season 1".
    private static let compiledICU = Mutex<[String: NSRegularExpression]>([:])
    private static let compiledString = Mutex<[String: SharedRegex]>([:])

    /// `Regex` is not `Sendable`, but a compiled one is immutable and publishes
    /// its lowered program atomically, so threads can share it.
    private struct SharedRegex: @unchecked Sendable { let value: Regex<AnyRegexOutput> }

    private static func icuRegex(_ pattern: String) -> NSRegularExpression? {
        if let known = compiledICU.withLock({ $0[pattern] }) { return known }
        guard let made = try? NSRegularExpression(pattern: pattern) else { return nil }
        compiledICU.withLock { $0[pattern] = made }
        return made
    }

    private static func stringRegex(_ pattern: String) -> Regex<AnyRegexOutput>? {
        if let known = compiledString.withLock({ $0[pattern] }) { return known.value }
        guard let made = try? Regex(pattern).wordBoundaryKind(.simple) else { return nil }
        compiledString.withLock { $0[pattern] = SharedRegex(value: made) }
        return made
    }
}
