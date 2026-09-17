import Foundation

public struct AppleLibraryTitle: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case movie, show, other }
    public let title: String
    public let year: Int?
    public let season: Int?
    public let episode: Int?
    public let kind: Kind
}

public enum AppleLibraryTitleParser {
    public static func parse(name: String, parentPath: String = "") -> AppleLibraryTitle {
        let parents = parentPath.split(separator: "/").map(String.init)
        let stem = removingExtension(name)
        let full = (parents + [stem]).joined(separator: "/")
        let pair = captures(#"(?i)\bS(\d{1,3})[ ._-]*E(\d{1,4})\b|\b(\d{1,3})x(\d{1,4})\b"#, full)
        let season = pair.flatMap { Int($0[0]) ?? Int($0[2]) }
            ?? captures(#"(?i)\bSeason[ ._-]*(\d{1,3})\b"#, full).flatMap { Int($0[0]) }
        let episode = pair.flatMap { Int($0[1]) ?? Int($0[3]) }
            ?? captures(#"(?i)\bEpisode[ ._-]*(\d{1,4})\b"#, full).flatMap { Int($0[0]) }
        let isShow = season != nil || episode != nil || parents.contains { $0.lowercased() == "shows" }
        var parsed = clean(stem)
        if prefersParent(stem) { parsed = ("", nil) }
        if isShow {
            // Episode filenames may be “Pilot” or “Episode 2”; the series folder
            // keeps every local season on the same card.
            for parent in parents.reversed() {
                guard !["movies", "shows", "tv", "media"].contains(parent.lowercased()), !prefersParent(parent) else { continue }
                let candidate = clean(parent)
                if !candidate.0.isEmpty { parsed = candidate; break }
            }
        }
        if parsed.0.isEmpty || (prefersParent(stem) && !isShow) {
            parsed = ("", nil)
            for parent in parents.reversed() {
                guard !["movies", "shows", "tv", "media"].contains(parent.lowercased()), !prefersParent(parent) else { continue }
                let candidate = clean(parent)
                if !candidate.0.isEmpty { parsed = candidate; break }
            }
        }
        let success = !parsed.0.isEmpty
        return AppleLibraryTitle(title: success ? parsed.0 : String(name.prefix(24)) + (name.count > 24 ? "…" : ""),
            year: parsed.1, season: season, episode: episode, kind: success ? (isShow ? .show : .movie) : .other)
    }

    public static func parse(_ item: AppleLibraryItem) -> AppleLibraryTitle {
        parse(name: item.name, parentPath: (item.relativePath as NSString).deletingLastPathComponent)
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
        let value = name.replacingOccurrences(of: #"\.[A-Za-z0-9]{2,4}$"#, with: "", options: .regularExpression)
        if value.count >= 2, value.allSatisfy(\.isNumber) { return true }
        return value.range(of: #"(?i)^(?:VTS[_ ]\d{1,3}[_ ]\d{1,3}|title[_ ]?t?\d{1,3})$"#,
                           options: .regularExpression) != nil
    }

    private static func prefersParent(_ name: String) -> Bool {
        isHash(name) || isDiscPlaylist(name)
    }

    private static func clean(_ raw: String) -> (String, Int?) {
        var value = raw.replacingOccurrences(of: #"^(?:\s*\[[^\]]*\]\s*)+"#, with: "", options: .regularExpression)
        // Tracker stamps: "www.UIndex.org    -    Hey Arnold The Movie 2002…".
        // The mandatory " - " after the domain is what keeps this off real
        // titles — "W.A.R - The Movie" and "Dr.No.1962" do not match.
        value = value.replacingOccurrences(
            of: #"(?i)^\s*(?:www[._])?[a-z0-9-]+[._][a-z]{2,6}\s*-+\s*"#,
            with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"[._]+"#, with: " ", options: .regularExpression)
        let year = captures(#"(?<=.)(?<!\d)\b((?:19|20)\d{2})\b"#, value).flatMap { Int($0[0]) }
        // Cut at release metadata, keeping ordinary title words such as “Atmosphere”.
        let boundary = #"(?i)\b(?:S\d{1,3}[ -]*E\d{1,4}|\d{1,3}x\d{1,4}|Season\s*\d+|Episode\s*\d+|(?:19|20)\d{2}|\d{3,4}p|[48]K|x26[45]|h[ -]?26[45]|HEVC|AVC|WEB[ -]?(?:DL|Rip)|Blu[ -]?Ray|BRRip|BDRip|HDR10\+?|HDR|DV|DOVI|Atmos|DTS|DDP|AAC|AC3|EAC3|REMUX|PROPER|REPACK)\b"#
        if let range = value.range(of: boundary, options: .regularExpression) {
            // A numeric title (1917, 2001) is not a release year at the beginning.
            if range.lowerBound != value.startIndex || Int(value[range]) == nil {
                value = String(value[..<range.lowerBound])
            } else {
                let suffix = String(value[range.upperBound...])
                if let next = suffix.range(of: boundary, options: .regularExpression) {
                    value = String(value[range]) + String(suffix[..<next.lowerBound])
                }
            }
        }
        value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-()[]")))
        return (value, year == Int(value) ? nil : year)
    }

    private static func captures(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}
