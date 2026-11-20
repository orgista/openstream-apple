import Foundation

struct AppleMediaServerTitleQuery: Hashable, Sendable {
    let name: String
    let year: Int?
    let type: AppleMediaServerItemType
    let providerIDs: [String]

    init(item: AppleCatalogItem, resolvedMediaID: String? = nil) {
        name = item.name
        year = item.year ?? AppleMediaIdentifier.leadingYear(item.releaseInfo)
        type = item.type == "series" ? .series : .movie
        let ids = [item.imdbID, resolvedMediaID, item.mediaID].compactMap { $0 }
        let imdb = ids.compactMap(AppleMediaIdentifier.canonicalMediaID).first
        let tmdb = ids.compactMap { id -> String? in
            let parts = id.split(separator: ":")
            guard parts.first == "tmdb", let number = parts.last, (Int(number) ?? 0) > 0 else { return nil }
            return String(number)
        }.first
        providerIDs = [imdb.map { "Imdb.\($0)" }, tmdb.map { "Tmdb.\($0)" }].compactMap { $0 }
    }

    func matches(_ item: AppleMediaServerItem, sameTypeHitCount: Int = 1) -> Bool {
        guard item.type == type else { return false }
        var matchedID = false
        for provider in providerIDs {
            let parts = provider.split(separator: ".", maxSplits: 1).map(String.init)
            if let actual = item.providerIDs.first(where: { $0.key.caseInsensitiveCompare(parts[0]) == .orderedSame })?.value {
                guard actual.caseInsensitiveCompare(parts[1]) == .orderedSame else { return false }
                matchedID = true
            }
        }
        if matchedID { return true }
        guard year != nil || sameTypeHitCount == 1 else { return false }
        return item.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(
            name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
            && (year == nil || item.year == year)
    }
}

struct AppleMediaServerTitleMatch: Identifiable, Equatable, Sendable {
    let detail: AppleMediaServerLibraryStore.AppleMediaServerDetail
    let playableItem: AppleMediaServerItem
    var reference: AppleMediaServerItemReference {
        .init(sourceID: detail.source.id, itemID: detail.item.id)
    }
    var id: String { reference.mediaID }
}

extension AppleMediaServerClient {
    func titleMatches(session: AppleMediaServerSession, query: AppleMediaServerTitleQuery) async throws -> [AppleMediaServerItem] {
        if !query.providerIDs.isEmpty {
            do {
                let page = try await items(session: session, parentID: nil, includeTypes: [query.type], limit: 20,
                                           providerIDs: query.providerIDs)
                let sameTypeHitCount = page.items.filter { $0.type == query.type }.count
                let matches = page.items.filter { query.matches($0, sameTypeHitCount: sameTypeHitCount) }
                if !matches.isEmpty { return matches }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw error
            } catch {
                // Compatible servers can reject provider filters or return malformed results.
            }
        }
        try Task.checkCancellation()
        // Local Rill needs the exact-phrase retry when broad search misses the title.
        for term in [query.name, "\"\(query.name)\""] {
            let page = try await items(session: session, parentID: nil, includeTypes: [query.type], limit: 20,
                                       searchTerm: term, years: query.year.map { [$0] } ?? [])
            let sameTypeHitCount = page.items.filter { $0.type == query.type }.count
            let matches = page.items.filter { query.matches($0, sameTypeHitCount: sameTypeHitCount) }
            if !matches.isEmpty { return matches }
            try Task.checkCancellation()
        }
        return []
    }
}
