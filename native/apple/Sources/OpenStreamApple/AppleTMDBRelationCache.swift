import Foundation
import Synchronization

/// Metadata links retain their source and seed; they are never playback routes.
struct AppleTMDBRelation: Codable, Equatable, Sendable {
    enum Origin: String, Codable, Sendable { case recommendation, similar }
    struct Target: Codable, Equatable, Sendable {
        let id: Int
        let type: String
        let title: String
        let year: Int?
        let origin: Origin

        var directKey: String { "\(type)|tmdb:\(id)" }
        var titleKey: String? {
            guard id > 0, let year, !title.isEmpty else { return nil }
            return "\(type)|title:\(Self.fold(title))|\(year)"
        }

        static func keys(_ item: AppleCatalogItem) -> [String] {
            var keys: [String] = []
            if item.mediaID.hasPrefix("tmdb:") { keys.append("\(item.type)|\(item.mediaID)") }
            if let year = AppleRecommendationInputs.releaseYear(item), !item.name.isEmpty {
                keys.append("\(item.type)|title:\(fold(item.name))|\(year)")
            }
            return keys
        }

        func accessibleIDs(in index: [String: Set<String>]) -> Set<String> {
            guard id > 0 else { return [] }
            if let direct = index[directKey], !direct.isEmpty { return direct }
            guard let titleKey, let ids = index[titleKey], ids.count == 1 else { return [] }
            return ids
        }

        func matches(_ item: AppleCatalogItem) -> Bool {
            guard item.type == type, id > 0 else { return false }
            return Self.keys(item).contains(directKey) || titleKey.map { Self.keys(item).contains($0) } == true
        }

        private static func fold(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
    }
    /// O(n) once per immutable candidate snapshot, instead of walking every
    /// title for each of 128 seeds × 40 links. Ambiguous remake joins fail shut.
    static func accessibleIndex(_ items: [String: AppleCatalogItem]) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for (id, item) in items {
            for key in Target.keys(item) { result[key, default: []].insert(id) }
        }
        return result
    }

    let seedID: String
    let type: String
    let targets: [Target]
    let storedAt: Date
}

/// A bounded cache populated by the existing, settings-gated metadata request.
/// Discover reads it once per revision. It has no network transport.
actor AppleTMDBRelationCache {
    static let shared = AppleTMDBRelationCache()
    static let changeNotification = Notification.Name("OpenStreamTMDBRelationsChanged")
    private static let counter = Mutex<UInt64>(0)
    nonisolated static var revision: UInt64 { counter.withLock { $0 } }
    private var loaded: [String: [AppleTMDBRelation]] = [:]
    private let cache: AppleMetadataDiskCache
    private static let maximumSeeds = 128

    init(cache: AppleMetadataDiskCache = .shared) { self.cache = cache }

    func snapshot(configuration: AppleTMDBConfiguration?) async -> [AppleTMDBRelation] {
        guard let configuration else { return [] }
        let marker = AppleCatalogArtworkPolicy.configurationMarker(configuration)
        if let values = loaded[marker] { return fresh(values) }
        let entry = await cache.entry(source: "openstream://tmdb-relations-v1", type: "links", mediaID: marker)
        // A store may have arrived while the disk actor was suspended.
        if let values = loaded[marker] { return fresh(values) }
        let values = entry.flatMap { try? JSONDecoder().decode([AppleTMDBRelation].self, from: $0.payload) } ?? []
        if loaded.count >= 2 { loaded.removeAll() }
        loaded[marker] = fresh(values)
        return loaded[marker] ?? []
    }

    private func fresh(_ values: [AppleTMDBRelation]) -> [AppleTMDBRelation] {
        Array(values.filter { $0.storedAt.timeIntervalSinceNow > -AppleMetadataDiskCachePolicy.keepFor }
            .prefix(Self.maximumSeeds))
    }

    func store(_ relation: AppleTMDBRelation, configuration: AppleTMDBConfiguration) async {
        _ = await snapshot(configuration: configuration)
        let marker = AppleCatalogArtworkPolicy.configurationMarker(configuration)
        var values = fresh(loaded[marker] ?? [])
        let targets = Array(relation.targets.prefix(40))
        let unchanged = values.first(where: { $0.seedID == relation.seedID && $0.type == relation.type })?.targets == targets
        values.removeAll { $0.seedID == relation.seedID && $0.type == relation.type }
        values.insert(AppleTMDBRelation(seedID: relation.seedID, type: relation.type,
            targets: targets, storedAt: relation.storedAt), at: 0)
        loaded[marker] = Array(values.prefix(Self.maximumSeeds))
        guard let payload = try? JSONEncoder().encode(Array(values.prefix(Self.maximumSeeds))) else { return }
        await cache.store(payload, source: "openstream://tmdb-relations-v1", type: "links",
            mediaID: AppleCatalogArtworkPolicy.configurationMarker(configuration))
        guard !unchanged else { return }
        Self.counter.withLock { $0 &+= 1 }
        NotificationCenter.default.post(name: Self.changeNotification, object: nil)
    }
}
