import Foundation

/// Resolves a shared link's identity: the viewer's own title when one has
/// that id, else TMDB's. No navigation or UI state is held here.
struct AppleSharedLinkResolution {
    let record: AppleMediaRecord?
    let item: AppleCatalogItem?

    @MainActor
    static func resolve(_ link: SharedLink, records: [AppleMediaRecord],
                        configuration: AppleTMDBConfiguration?,
                        tmdb: AppleTMDBClient = AppleTMDBClient()) async throws -> Self {
        var item: AppleCatalogItem?
        var record: AppleMediaRecord?
        switch link {
        case .imdb(let id):
            record = records.first { $0.canonicalID == id }
            if record == nil {
                guard let configuration else { throw AppleSharedLinkError.metadataUnavailable }
                item = try? await tmdb.sharedLinkDetails(imdbID: id, configuration: configuration)
            }
        case .tmdb(let kind, let id):
            guard let configuration else { throw AppleSharedLinkError.metadataUnavailable }
            item = try await tmdb.sharedLinkDetails(id: id, kind: kind, configuration: configuration)
        }
        if item == nil, let record {
            item = AppleCatalogItem(mediaID: record.canonicalID ?? record.id,
                type: record.kind == .series ? "series" : "movie", name: record.title,
                posterURL: record.artworkURL, backgroundURL: record.backdropURL,
                summary: record.summary, releaseInfo: record.year.map(String.init), year: record.year)
        }
        try Task.checkCancellation()
        return Self(record: record, item: item)
    }
}
