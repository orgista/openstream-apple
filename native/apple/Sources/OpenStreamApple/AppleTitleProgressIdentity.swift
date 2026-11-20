import Foundation

/// Which progress key a title page reads and writes. The page keyed it on the
/// record built from the item it was opened with, and the same film arrives
/// as different items: an IMDb id from one catalog, a `tmdb:` id with no IMDb
/// id from another (keyed by title and year), or Continue Watching's own
/// record. Mad Max: Fury Road was watched for 65 s, listed in Continue
/// Watching, and its title page still said Play (Apple TV check 2026-10-01).
/// Every key the title can have is tried; the newest saved position wins.
public enum AppleTitleProgressIdentity {
    /// The page's own record id first, then the IMDb-keyed record (from the
    /// item or the id the page resolved), then the title-and-year record.
    /// Media servers save playback under their source/item reference instead.
    public static func candidates(item: AppleCatalogItem, sourceID: AppleSource.ID,
                                  resolvedMediaID: String? = nil) -> [String] {
        if AppleXtreamReference.parse(item.mediaID) != nil {
            return [AppleMediaIngestion.catalogRecord(instanceID: sourceID, item: item).id]
        }
        let kind: AppleMediaKind = item.type == "series" ? .series : .movie
        let year = item.releaseInfo.flatMap { Int($0.prefix(4)) }
        var keys = [AppleMediaIngestion.catalogRecord(instanceID: sourceID, item: item).id]
        if let serverItem = AppleMediaServerItemReference.parse(item.mediaID) {
            keys.append(serverItem.mediaID)
        }
        let imdb = [item.imdbID, item.mediaID, resolvedMediaID]
            .compactMap { $0 }
            .first(where: AppleMediaIdentifier.isIMDBIdentifier)
        if let imdb {
            keys.append(AppleMediaRecord(canonicalID: imdb, kind: kind, title: item.name, year: year,
                                         availability: []).id)
        }
        keys.append(AppleMediaRecord(canonicalID: nil, kind: kind, title: item.name, year: year,
                                     availability: []).id)
        var seen = Set<String>()
        return keys.filter { seen.insert($0).inserted }
    }

    /// The candidate holding the newest saved position, else the first.
    public static func key(among candidates: [String],
                           progress: (String) -> ApplePlaybackProgress?) -> String? {
        let saved = candidates.compactMap { key in progress(key).map { (key, $0.updatedAt) } }
        return saved.max { $0.1 < $1.1 }?.0 ?? candidates.first
    }
}
