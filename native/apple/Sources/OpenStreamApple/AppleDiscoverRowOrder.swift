import Foundation

/// The viewer's order for the rows on Discover, kept as a list of stable row
/// ids: one per built-in row kind, and `catalog:<section id>` per catalogue
/// shelf. `nil` in settings means "never reordered", and Discover then draws
/// exactly the order it builds on its own.
enum AppleDiscoverRowOrder {
    static let continueWatching = "continueWatching"
    static let library = "library"
    static let mediaServers = "mediaServers"
    static let topPicks = "topPicks"
    static let top10Movies = "top10Movies"
    static let top10Shows = "top10Shows"
    static let catalogPrefix = "catalog:"

    /// The built-in rows in the order Discover has always drawn them, with
    /// the catalogue shelves after them.
    static let builtInDefault = [continueWatching, library, mediaServers, topPicks, top10Movies, top10Shows]

    static func catalogID(_ sectionID: String) -> String { catalogPrefix + sectionID }

    static func title(forBuiltIn id: String) -> String? {
        switch id {
        case continueWatching: "Continue Watching"
        case library: "Your Library"
        case mediaServers: "Media Servers"
        case topPicks: "Top Picks for You"
        case top10Movies: "Top 10 Movies in the US"
        case top10Shows: "Top 10 Shows in the US"
        default: nil
        }
    }

    /// `available` in its default order, rearranged by `custom`.
    ///
    /// Rows the viewer placed come in their chosen order; ids that no longer
    /// exist are dropped; a row the viewer never placed (a catalogue added
    /// later) goes in after the row it follows by default, or first if it
    /// leads the default order. A row that is not available (Continue
    /// Watching with nothing to resume) is simply not in the result.
    static func resolve(available: [String], custom: [String]?) -> [String] {
        guard let custom else { return available }
        let availableSet = Set(available)
        var seen = Set<String>()
        var result = custom.filter { availableSet.contains($0) && seen.insert($0).inserted }
        for (index, id) in available.enumerated() where !seen.contains(id) {
            let predecessor = available[..<index].last { seen.contains($0) }
            let position = predecessor.flatMap { result.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            result.insert(id, at: position)
            seen.insert(id)
        }
        return result
    }

    /// `ids` after a drag: the rows at `offsets` land before the row that was
    /// at `destination` (the offsets `List.onMove` hands over).
    static func moved(_ ids: [String], fromOffsets offsets: IndexSet, toOffset destination: Int) -> [String] {
        let valid = offsets.filter { ids.indices.contains($0) }
        guard !valid.isEmpty else { return ids }
        let moving = valid.map { ids[$0] }
        var rest = ids.indices.filter { !valid.contains($0) }.map { ids[$0] }
        let target = min(max(destination, 0), ids.count) - valid.filter { $0 < destination }.count
        rest.insert(contentsOf: moving, at: min(max(target, 0), rest.count))
        return rest
    }

    /// `ids` with `id` moved to `target` (Move Up, Move Down, Move to Top, a
    /// step of the Apple TV's carried row), or nil when that changes nothing.
    static func moved(_ ids: [String], id: String, to target: Int) -> [String]? {
        guard let index = ids.firstIndex(of: id), ids.indices.contains(target), target != index else { return nil }
        var result = ids
        result.remove(at: index)
        result.insert(id, at: target)
        return result
    }

    /// `-OpenStreamDebugDiscoverOrder featuredMovies,library,…`: a review
    /// build can show a custom order without writing the viewer's settings.
    /// Each token is a row id, or a catalogue shelf title with spaces and case
    /// ignored ("featuredMovies" names the "Featured Movies" shelf).
    static func debugOrder(_ tokens: String, catalogTitles: [(id: String, title: String)]) -> [String] {
        func squashed(_ text: String) -> String { text.lowercased().filter { !$0.isWhitespace } }
        return tokens.split(separator: ",").map { token -> String in
            let token = token.trimmingCharacters(in: .whitespaces)
            if builtInDefault.contains(token) || token.hasPrefix(catalogPrefix) { return token }
            if let match = catalogTitles.first(where: { squashed($0.title) == squashed(token) }) {
                return catalogID(match.id)
            }
            return token
        }
    }
}
