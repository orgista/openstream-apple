import Foundation
import OSLog
import TVServices

/// The shelf failing is invisible from the outside: tvOS silently falls back
/// to the static Top Shelf image, which looks like a design choice rather than
/// a bug. Every exit from `loadTopShelfContent` says why, into
/// `log stream --predicate 'subsystem == "com.orgista.openstream.topshelf"'`.
private let log = Logger(subsystem: "com.orgista.openstream.topshelf", category: "content")

final class TopShelfProvider: TVTopShelfContentProvider {
    private struct Snapshot: Decodable {
        struct Item: Decodable {
            let id: String
            let title: String
            let artworkURL: URL?
            let displayURL: URL
            let playURL: URL?
            /// 0–1 for a title in Continue Watching; absent in older snapshots.
            let progress: Double?
            /// The 16:9 backdrop; absent in older snapshots and for titles
            /// with no landscape art.
            let landscapeArtworkURL: URL?
        }

        let version: Int
        let continueWatching: [Item]
        // Decoded for forward compatibility with the app's snapshot writer,
        // but no longer rendered — Top Picks replaced them on the shelf.
        let recentlyAdded: [Item]
        let favorites: [Item]
        let topPicks: [Item]
        let favoriteChannels: [Item]

        private enum CodingKeys: String, CodingKey {
            case version, continueWatching, recentlyAdded, favorites, topPicks, favoriteChannels
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            continueWatching = try container.decode([Item].self, forKey: .continueWatching)
            recentlyAdded = try container.decode([Item].self, forKey: .recentlyAdded)
            favorites = try container.decode([Item].self, forKey: .favorites)
            favoriteChannels = try container.decodeIfPresent([Item].self, forKey: .favoriteChannels) ?? []
            topPicks = try container.decodeIfPresent([Item].self, forKey: .topPicks) ?? []
        }
    }

    override func loadTopShelfContent(completionHandler: @escaping ((any TVTopShelfContent)?) -> Void) {
        guard let root = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.orgista.openstream"
        ) else {
            log.error("no app group container — check the extension's entitlement")
            completionHandler(nil)
            return
        }
        let url = root.appending(path: "topshelf-v1.json")
        guard let data = try? Data(contentsOf: url) else {
            log.error("no snapshot at \(url.path, privacy: .public) — the app has not published one")
            completionHandler(nil)
            return
        }
        guard data.count <= 1_000_000,
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.version == 1 else {
            log.error("snapshot unreadable — \(data.count) bytes")
            completionHandler(nil)
            return
        }

        // Continue Watching first (when non-empty), then Top Picks — mirrors
        // AppleTopShelfContentBuilder.sections(for:) in OpenStreamApple.
        let sections = [
            collection(title: "Continue Watching", values: snapshot.continueWatching),
            collection(title: "Favorite channels", values: snapshot.favoriteChannels),
            collection(title: "Top Picks", values: snapshot.topPicks),
        ].compactMap { $0 }
        let shapes = sections.map { $0.items.first?.imageShape == .hdtv ? "hdtv" : "poster" }.joined(separator: ",")
        log.info("serving \(sections.count) section(s): continueWatching=\(snapshot.continueWatching.count) topPicks=\(snapshot.topPicks.count) shapes=\(shapes, privacy: .public)")
        completionHandler(sections.isEmpty ? nil : TVTopShelfSectionedContent(sections: sections))
    }

    private func collection(title: String, values: [Snapshot.Item]) -> TVTopShelfItemCollection<TVTopShelfSectionedItem>? {
        let values = values.prefix(20)
        // 16:9 tiles like the Apple TV app's, but only when every tile has a
        // backdrop — a row takes one shape, and a poster stretched to 16:9 is
        // worse than posters. Mirrors AppleTopShelfSection.imageShape.
        let landscape = values.allSatisfy { $0.landscapeArtworkURL != nil }
        let items = values.map { value in
            let item = TVTopShelfSectionedItem(identifier: value.id)
            item.title = String(value.title.prefix(200))
            item.imageShape = landscape ? .hdtv : .poster
            item.displayAction = TVTopShelfAction(url: value.displayURL)
            if let playURL = value.playURL { item.playAction = TVTopShelfAction(url: playURL) }
            // The bar under a started title, as the Apple TV app draws it.
            if let progress = value.progress, progress > 0 {
                item.playbackProgress = min(progress, 1)
            }
            if let imageURL = landscape ? value.landscapeArtworkURL : (value.artworkURL ?? value.landscapeArtworkURL),
               ["https", "http"].contains(imageURL.scheme?.lowercased()),
               imageURL.user == nil, imageURL.password == nil {
                item.setImageURL(imageURL, for: [.screenScale1x, .screenScale2x])
            }
            return item
        }
        guard !items.isEmpty else { return nil }
        let collection = TVTopShelfItemCollection(items: items)
        collection.title = title
        return collection
    }
}
