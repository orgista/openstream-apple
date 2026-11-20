import Foundation

#if canImport(CoreSpotlight) && !os(tvOS)
import CoreSpotlight

/// Keeps the privacy-approved media projection in Core Spotlight. This is a
/// projection only: identifiers are opaque and no source URL, path, token, or
/// credential is exported to the system index.
protocol AppleSpotlightStoring: Sendable {
    func deleteAll() async throws
    func index(_ records: [AppleMediaRecord]) async throws
}

public actor AppleSpotlightIndexer {
    public static let shared = AppleSpotlightIndexer()

    private let store: any AppleSpotlightStoring

    private var pending: Task<Void, Never>?
    private var revision = 0

    public init() { store = AppleCoreSpotlightStore() }
    init(store: any AppleSpotlightStoring) { self.store = store }

    public func synchronize(records: [AppleMediaRecord], enabled: Bool) async {
        // Actor methods reenter at each index await. Serialize whole replacements
        // so disabling discovery always deletes any earlier in-flight indexing.
        revision &+= 1
        let currentRevision = revision
        let previous = pending
        let task = Task {
            await previous?.value
            await self.replaceIndex(records: records, enabled: enabled)
        }
        pending = task
        await task.value
        if currentRevision == revision { pending = nil }
    }

    private func replaceIndex(records: [AppleMediaRecord], enabled: Bool) async {
        do {
            guard enabled else {
                try await store.deleteAll()
                return
            }

            let eligible = records
                .filter { !$0.availability.isEmpty && !$0.isPrivate }
                .sorted { lhs, rhs in
                    if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
                    if (lhs.progress != nil) != (rhs.progress != nil) { return lhs.progress != nil }
                    return lhs.lastVerified > rhs.lastVerified
                }
                .prefix(1_000)

            try await store.deleteAll()
            if !eligible.isEmpty { try await store.index(Array(eligible)) }
        } catch {
            // Spotlight is an optional system projection. In-app Search remains
            // authoritative and a transient indexing failure must not block it.
        }
    }

}

private actor AppleCoreSpotlightStore: AppleSpotlightStoring {
    private static let domain = "com.orgista.openstream.media"
    private let index = CSSearchableIndex(name: "OpenStreamMedia")
    func deleteAll() async throws { try await index.deleteSearchableItems(withDomainIdentifiers: [Self.domain]) }
    func index(_ records: [AppleMediaRecord]) async throws { try await index.indexSearchableItems(records.map(Self.searchableItem)) }

    private static func searchableItem(_ record: AppleMediaRecord) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(itemContentType: "public.content")
        attributes.title = record.title
        attributes.displayName = record.title
        attributes.contentDescription = [
            record.kind.rawValue.capitalized,
            record.year.map(String.init),
            record.summary,
        ].compactMap { $0 }.joined(separator: " · ")
        attributes.keywords = Array(Set(record.aliases + [record.kind.rawValue]))
        attributes.contentURL = URL(string: "openstream://media/\(record.id)?action=display")
        if let artwork = AppleSystemArtworkPolicy.publicURL(record.artworkURL) {
            attributes.thumbnailURL = artwork
        }
        return CSSearchableItem(
            uniqueIdentifier: record.id,
            domainIdentifier: domain,
            attributeSet: attributes
        )
    }
}
#else
public actor AppleSpotlightIndexer {
    public static let shared = AppleSpotlightIndexer()
    public init() {}
    public func synchronize(records: [AppleMediaRecord], enabled: Bool) async {}
}
#endif
