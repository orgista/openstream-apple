import Foundation
import TVServices

final class TopShelfProvider: TVTopShelfContentProvider {
    private struct Snapshot: Decodable {
        struct Item: Decodable {
            let id: String
            let title: String
            let artworkURL: URL?
            let displayURL: URL
            let playURL: URL?
        }

        let version: Int
        let continueWatching: [Item]
        // Decoded for forward compatibility with the app's snapshot writer,
        // but no longer rendered — Top Picks replaced them on the shelf.
        let recentlyAdded: [Item]
        let favorites: [Item]
        let topPicks: [Item]

        private enum CodingKeys: String, CodingKey {
            case version, continueWatching, recentlyAdded, favorites, topPicks
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            continueWatching = try container.decode([Item].self, forKey: .continueWatching)
            recentlyAdded = try container.decode([Item].self, forKey: .recentlyAdded)
            favorites = try container.decode([Item].self, forKey: .favorites)
            topPicks = try container.decodeIfPresent([Item].self, forKey: .topPicks) ?? []
        }
    }

    override func loadTopShelfContent(completionHandler: @escaping ((any TVTopShelfContent)?) -> Void) {
        guard let root = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.orgista.openstream"
        ), let data = try? Data(contentsOf: root.appending(path: "topshelf-v1.json")),
        data.count <= 1_000_000,
        let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
        snapshot.version == 1 else {
            completionHandler(nil)
            return
        }

        // Continue Watching first (when non-empty), then Top Picks — mirrors
        // AppleTopShelfContentBuilder.sections(for:) in OpenStreamApple.
        let sections = [
            collection(title: "Continue Watching", values: snapshot.continueWatching),
            collection(title: "Top Picks", values: snapshot.topPicks),
        ].compactMap { $0 }
        completionHandler(sections.isEmpty ? nil : TVTopShelfSectionedContent(sections: sections))
    }

    private func collection(title: String, values: [Snapshot.Item]) -> TVTopShelfItemCollection<TVTopShelfSectionedItem>? {
        let items = values.prefix(20).map { value in
            let item = TVTopShelfSectionedItem(identifier: value.id)
            item.title = String(value.title.prefix(200))
            item.imageShape = .poster
            item.displayAction = TVTopShelfAction(url: value.displayURL)
            if let playURL = value.playURL { item.playAction = TVTopShelfAction(url: playURL) }
            if let imageURL = value.artworkURL,
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
