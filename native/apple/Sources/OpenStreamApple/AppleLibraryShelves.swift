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
            let key = parsed.kind == .show
                ? "\(item.sourceID):\(parsed.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))):\(parsed.year ?? 0)"
                : item.id
            if groups[key] != nil { groups[key]?.items.append(item) }
            else { groups[key] = Self(id: key, parsed: parsed, items: [item]) }
        }
        return groups.values.map { group in
            var value = group
            value.items.sort {
                let a = AppleLibraryTitleParser.parse($0), b = AppleLibraryTitleParser.parse($1)
                if a.season != b.season { return (a.season ?? 0) < (b.season ?? 0) }
                if a.episode != b.episode { return (a.episode ?? 0) < (b.episode ?? 0) }
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
