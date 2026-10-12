import Foundation

/// Resolves identity through the existing metadata clients and the caller's Search pipeline.
/// No navigation or UI state is held here.
struct AppleSharedLinkResolution {
    let record: AppleMediaRecord?
    let item: AppleCatalogItem?
    let title: AppleSharedLinkResolver.Title?
    /// A metadata catalog's text search for one kind ("movie" or "series").
    /// Only add-on builds consult it; nil means the built-in Cinemeta search.
    typealias CatalogSearch = @Sendable (_ type: String, _ query: String) async throws -> [AppleCatalogItem]

    @MainActor
    static func resolve(_ link: SharedLink, records: [AppleMediaRecord], sources: [AppleSource],
                        configuration: AppleTMDBConfiguration?,
                        pageResolver: AppleSharedLinkResolver = AppleSharedLinkResolver(),
                        tmdb: AppleTMDBClient = AppleTMDBClient(),
                        catalogSearch: CatalogSearch? = nil,
                        search: (String) async -> [AppleMediaRecord]) async throws -> Self {
        var directItem: AppleCatalogItem?
        var directRecord: AppleMediaRecord?
        var title: AppleSharedLinkResolver.Title?
        switch link {
        case .imdb(let id):
            directRecord = records.first { $0.canonicalID == id }
            if directRecord == nil, let configuration = configuration {
                directItem = try? await tmdb.sharedLinkDetails(imdbID: id, configuration: configuration)
            }
            #if OPENSTREAM_ADDONS
            if directItem == nil, directRecord == nil {
                for source in sources where source.isAddon && source.isEnabled && source.resources.contains("meta") {
                    for type in ["movie", "series"] {
                        if let details = try? await AppleStremioMetadataClient().details(source: source, type: type, mediaID: id),
                           let name = details.title {
                            directItem = AppleCatalogItem(mediaID: id, type: details.mediaType ?? type, name: name,
                                posterURL: details.posterURL, backgroundURL: details.backdropURL,
                                summary: details.overview, releaseInfo: details.releaseInfo, year: details.year)
                            break
                        }
                    }
                    if directItem != nil { break }
                }
            }
            #endif
        case .tmdb(let kind, let id):
            guard let configuration = configuration else { throw AppleSharedLinkError.unreadable }
            directItem = try await tmdb.sharedLinkDetails(id: id, kind: kind, configuration: configuration)
        default:
            title = try await pageResolver.title(for: link)
        }
        if let title {
            appleTrace("shared link title \(title.name) year=\(title.year.map(String.init) ?? "-")")
            let results = await search(title.name)
            directRecord = AppleSharedLinkResolver.bestMatch(title, records: results)
            if directRecord == nil, let configuration = configuration {
                let items = (try? await tmdb.sharedLinkSearch(title: title, configuration: configuration)) ?? []
                let records = items.map { AppleMediaRecord(canonicalID: $0.mediaID,
                    kind: $0.type == "movie" ? .movie : .series, title: $0.name, year: $0.year, availability: []) }
                if let match = AppleSharedLinkResolver.bestMatch(title, records: records),
                   let index = records.firstIndex(where: { $0.id == match.id }) {
                    let candidate = items[index]
                    let pieces = candidate.mediaID.split(separator: ":")
                    if pieces.count == 3, pieces[0] == "tmdb", let id = Int(pieces[2]) {
                        directItem = try await tmdb.sharedLinkDetails(id: id, kind: pieces[1] == "movie" ? .movie : .show, configuration: configuration)
                    } else { directItem = candidate }
                }
            }
            #if OPENSTREAM_ADDONS
            // No TMDB key (a fresh install): the built-in metadata catalog
            // still knows the title, so the link opens its page, not Search.
            if directRecord == nil, directItem == nil {
                directItem = await catalogMatch(title, search: catalogSearch ?? cinemetaSearch)
            }
            #endif
        }
        if directItem == nil, let record = directRecord {
            directItem = AppleCatalogItem(mediaID: record.canonicalID ?? record.id,
                type: record.kind == .series ? "series" : "movie", name: record.title,
                posterURL: record.artworkURL, backgroundURL: record.backdropURL,
                summary: record.summary, releaseInfo: record.year.map(String.init), year: record.year)
        }
        try Task.checkCancellation()
        return Self(record: directRecord, item: directItem, title: title)
    }

    #if OPENSTREAM_ADDONS
    /// The one catalog entry with the shared title's name, year and kind, or nil when none or several qualify.
    static func catalogMatch(_ title: AppleSharedLinkResolver.Title, search: CatalogSearch) async -> AppleCatalogItem? {
        let types = switch title.kind {
        case .movie: ["movie"]
        case .show, .episode: ["series"]
        case nil: ["movie", "series"]
        }
        var items: [AppleCatalogItem] = []
        for type in types {
            guard !Task.isCancelled else { return nil }
            items += ((try? await search(type, title.name)) ?? []).filter { $0.type == type }
        }
        let records = items.map { AppleMediaRecord(canonicalID: $0.mediaID, kind: $0.type == "movie" ? .movie : .series,
            title: $0.name, year: $0.year ?? Int(($0.releaseInfo ?? "").prefix(4)), availability: []) }
        guard let match = AppleSharedLinkResolver.bestMatch(title, records: records),
              let index = records.firstIndex(where: { $0.id == match.id }) else { return nil }
        let item = items[index]
        appleTrace("shared link catalog match \(item.mediaID)")
        guard item.year == nil, let year = match.year else { return item }
        return AppleCatalogItem(mediaID: item.mediaID, type: item.type, name: item.name, posterURL: item.posterURL,
            backgroundURL: item.backgroundURL, summary: item.summary, releaseInfo: item.releaseInfo, year: year,
            logoURL: item.logoURL, imdbID: item.imdbID)
    }

    private static let cinemetaSearch: CatalogSearch = { type, query in
        var cinemeta = AppleStremioMetadataClient.defaultMetadataSource
        cinemeta.resources = ["catalog", "meta"]
        cinemeta.catalogs = [.init(type: type, id: "top", supportsSearch: true)]
        return try await AppleStremioCatalogClient().search(source: cinemeta, catalog: cinemeta.catalogs[0], query: query)
    }
    #endif
}
