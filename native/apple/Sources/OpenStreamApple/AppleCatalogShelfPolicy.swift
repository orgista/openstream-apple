import Foundation

enum AppleCatalogShelfPolicy {
    static func hasDiscoverContent(hasCatalog: Bool, hasLocalLibrary: Bool, hasMediaServerItems: Bool) -> Bool {
        hasCatalog || hasLocalLibrary || hasMediaServerItems
    }

    enum Style: Equatable, Sendable { case poster, featured, ranked }

    static func title(for catalog: AppleStremioCatalog) -> String {
        appleCatalogShelfTitle(sourceName: "", catalogType: catalog.type, catalogName: catalog.name, catalogID: catalog.id)
    }

    static func style(for catalog: AppleStremioCatalog) -> Style {
        let name = title(for: catalog).lowercased()
        if name.hasPrefix("top 10") { return .ranked }
        if name.hasPrefix("featured") || (name.contains("emmy") && name.contains("winners")) { return .featured }
        return .poster
    }

    static func rankedSubtitle(for item: AppleCatalogItem) -> String {
        [item.year.map { String($0) } ?? item.releaseInfo.map(AppleReleaseYearText.display), item.genres?.first]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// The rows Discover draws: active sources, non-empty, in title order,
    /// and never two rows under one heading (owner, 2026-09-24: "Prime Video"
    /// appeared twice). Each row carries its heading in `shelfTitle`.
    ///
    /// When one name covers catalogs of different types — Cinemeta's
    /// "Popular" movies and "Popular" series — each reads "Popular Movies" /
    /// "Popular Shows". When two rows still share a heading, the first keeps
    /// it and the later one is not drawn. A later row with different titles
    /// used to stay, headed "Popular Movies · Cinemeta" — the provider back in
    /// the shelf title (Apple TV pass 2026-10-02) — and without the suffix it
    /// would be a second "Popular Movies" right under the first, which the
    /// owner ruled out on 2026-09-24. Its items are not folded into the first
    /// row: they open through their own add-on, and a merged row has one.
    /// The row is still listed (and can be turned on) in Discover Rows.
    static func visibleSections(
        _ sections: [AppleCatalogSection], activeSourceIDs: Set<AppleSource.ID>
    ) -> [AppleCatalogSection] {
        let shown = sections.filter { activeSourceIDs.contains($0.sourceID) && !$0.items.isEmpty }
        let titles = shown.map { title(for: $0.catalog) }
        var typesByTitle = [String: Set<String>]()
        for (section, title) in zip(shown, titles) {
            typesByTitle[title.lowercased(), default: []].insert(section.catalog.type.lowercased())
        }
        var seenIDs = Set<String>()
        var seenHeadings = Set<String>()
        return zip(shown, titles).map { section, title -> AppleCatalogSection in
            var section = section
            section.shelfTitle = (typesByTitle[title.lowercased()]?.count ?? 0) > 1
                ? typedTitle(title, type: section.catalog.type) : title
            return section
        }.sorted {
            let order = ($0.shelfTitle ?? "").localizedCaseInsensitiveCompare($1.shelfTitle ?? "")
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }.filter { section in
            seenIDs.insert(section.id).inserted
                && seenHeadings.insert((section.shelfTitle ?? "").lowercased()).inserted
        }
    }

    /// An add-on's name as a row heading shows it: whitespace collapsed and a
    /// trailing " | Host" dropped. "AIOMetadata  | ElfHosted" was printed raw,
    /// double space and all (full test 2026-09-30).
    static func displaySourceName(_ name: String) -> String {
        let collapse: (Substring) -> String = {
            $0.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let full = collapse(Substring(name))
        guard let bar = name.firstIndex(of: "|") else { return full }
        let head = collapse(name[..<bar])
        return head.isEmpty ? full : head
    }

    /// Half or more of a row's leading titles already shown under the same
    /// heading means it is the same list from another add-on.
    static func mostlyRepeats(_ items: Set<String>, _ kept: Set<String>) -> Bool {
        guard !items.isEmpty else { return true }
        return Double(items.intersection(kept).count) / Double(items.count) >= 0.5
    }

    /// "Popular" → "Popular Movies" / "Popular Shows"; a name that already
    /// ends in a type word swaps it rather than stacking a second one. The
    /// type word goes where it reads as English (Apple TV pass 2026-10-02:
    /// "Year Movies", "Latest Releases Movies"):
    /// - a name that is a way of sorting ("Year", "Genre") → "Movies by Year";
    /// - a name ending in a plural noun the type describes ("Latest
    ///   Releases") → "Latest Movie Releases";
    /// - anything else, an adjective ("Popular", "Top Rated") → "Popular Movies".
    static func typedTitle(_ title: String, type: String) -> String {
        let plural: String
        let singular: String
        switch type.lowercased() {
        case "movie": (plural, singular) = ("Movies", "Movie")
        case "series": (plural, singular) = ("Shows", "Show")
        default: return title
        }
        var words = title.split(separator: " ").map(String.init)
        if let last = words.last?.lowercased(), ["movies", "movie", "shows", "show", "series", "tv"].contains(last), words.count > 1 {
            words.removeLast()
        }
        let byWords: Set<String> = ["year", "years", "genre", "genres", "decade", "decades", "country", "language", "rating", "network", "networks", "studio", "studios"]
        if words.count == 1, let only = words.first, byWords.contains(only.lowercased()) {
            return "\(plural) by \(only)"
        }
        let nounWords: Set<String> = ["releases", "premieres", "arrivals", "additions", "picks", "favorites", "favourites", "classics", "hits", "gems"]
        if words.count > 1, let last = words.last, nounWords.contains(last.lowercased()) {
            return (words.dropLast() + [singular, last]).joined(separator: " ")
        }
        return (words + [plural]).joined(separator: " ")
    }

    /// First occurrence wins. A shelf keys its `ForEach` on `id`, so a repeated
    /// id draws one card twice under one accessibility identifier — which
    /// SwiftUI treats as undefined and XCTest cannot resolve.
    static func uniqueByID<Value: Identifiable>(_ values: [Value]) -> [Value] {
        var seen = Set<Value.ID>()
        return values.filter { seen.insert($0.id).inserted }
    }
}

/// A Discover row's heading: the add-on's own catalog name, never a streaming
/// service the app put there itself.
///
/// The app used to map catalog ids (`nfx`, `dnp`, `hbm`…) to brands and head
/// rows "Netflix Movies" / "Disney+ Shows". That read as the service's content
/// inside this app (App Store compliance audit B4, owner 2026-10-01), so the
/// id table is gone: a row says what the add-on called the list, with a
/// provider prefix dropped and whitespace collapsed (the Streaming Catalogs
/// add-on names its Prime movies "Prime  Video"). Service names and logos
/// belong only to Watch On / "Also available on". When one name covers a
/// movie and a series catalog, `AppleCatalogShelfPolicy.visibleSections` adds
/// the type word, so two rows never share a heading (owner, 2026-09-24).
func appleCatalogShelfTitle(sourceName _: String, catalogType: String, catalogName: String? = nil,
                            catalogID _: String? = nil) -> String {
    let name = appleCatalogNameWithoutProviderPrefix(
        (catalogName ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " "))
    if !name.isEmpty { return name }
    // Unnamed catalogs still get a useful heading, never an add-on name.
    switch catalogType.lowercased() {
    case "movie": return "Movies"
    case "series": return "Shows"
    case "tv": return "TV"
    case "channel": return "Channels"
    case "anime": return "Anime"
    default: return "Catalog"
    }
}

/// Metadata add-ons that prefix every catalog with their own name.
#if OPENSTREAM_ADDONS
private let appleCatalogProviderPrefixes = ["tmdb", "cinemeta", "trakt", "imdb", "mdblist", "letterboxd", "stremio"]
#else
private let appleCatalogProviderPrefixes = ["tmdb", "cinemeta", "trakt", "imdb", "mdblist", "letterboxd"]
#endif
/// Short provider tags that are only a prefix when a separator follows them
/// ("RT: Certified Fresh"), so a list that merely starts with the letters keeps them.
private let appleCatalogProviderTags = ["rt"]

/// "TMDB Popular Movies" → "Popular Movies", "Trakt - Trending" → "Trending":
/// a row names what it lists, not the add-on it came from (the Apple TV app
/// never shows a provider in a shelf title). A name that is only the provider
/// ("TMDB") is kept, so no row loses its heading.
func appleCatalogNameWithoutProviderPrefix(_ name: String) -> String {
    let words = name.split(separator: " ", omittingEmptySubsequences: true)
    let separators: Set<Substring> = ["-", "–", "—", ":", "|", "·"]
    guard let first = words.first else { return name }
    let bare = first.trimmingCharacters(in: CharacterSet(charactersIn: ":|-·")).lowercased()
    let separated = bare.count < first.count || words.dropFirst().first.map { separators.contains($0) } == true
    guard appleCatalogProviderPrefixes.contains(bare) || (separated && appleCatalogProviderTags.contains(bare))
    else { return name }
    let rest = words.dropFirst().drop { separators.contains($0) }
    return rest.isEmpty ? name : rest.joined(separator: " ")
}
