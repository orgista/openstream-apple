import AVFoundation
import SwiftUI

struct AppleLibrarySeries: Identifiable, Sendable {
    let id: String
    let parsed: AppleLibraryTitle
    var items: [AppleLibraryItem]
    var addedAt: Date { items.map(\.addedAt).max() ?? .distantPast }

    static func groups(_ items: [AppleLibraryItem]) -> [Self] {
        var groups: [String: Self] = [:]
        for item in items {
            let parsed = AppleLibraryTitleParser.parse(item)
            let folded = parsed.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            // A show's files are its episodes. A dated film kept as two files
            // (a 1080p and a 4K copy, a re-rip) is one title with two versions
            // — one card, both files listed under the page's Other Sources
            // (N32 #13: "Tony" drew twice). An undated film stays one card per
            // file: two different films can share a bare name.
            let key: String
            switch (parsed.kind, parsed.year) {
            case (.show, let year): key = "\(item.sourceID):\(folded):\(year ?? 0)"
            case (.movie, let year?): key = "\(item.sourceID):movie:\(folded):\(year)"
            default: key = item.id
            }
            if groups[key] != nil { groups[key]?.items.append(item) }
            else { groups[key] = Self(id: key, parsed: parsed, items: [item]) }
        }
        return groups.values.map { group in
            var value = group
            value.items.sort {
                let a = AppleLibraryTitleParser.parse($0), b = AppleLibraryTitleParser.parse($1)
                if a.season != b.season { return (a.season ?? 0) < (b.season ?? 0) }
                if a.episode != b.episode { return (a.episode ?? 0) < (b.episode ?? 0) }
                // The best copy first: it is the one a card resolves and plays.
                let lhs = AppleStremioCandidateRanking.resolution($0.name), rhs = AppleStremioCandidateRanking.resolution($1.name)
                if lhs != rhs { return lhs > rhs }
                return $0.id < $1.id
            }
            return value
        }
    }
}

enum AppleLibrarySort: String, CaseIterable, Identifiable {
    case added = "Added", title = "Title A–Z", year = "Year"
    var id: String { rawValue }
}

extension AppleLibrarySeries: Hashable {
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
