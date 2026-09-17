import Foundation

/// Observes `AppleCatalogStore.sections` and `AppleMediaIndexStore.records`
/// and republishes the Top Shelf snapshot whenever either changes, so
/// "Top Picks" stays in sync with the first catalog shelf the same way
/// Continue Watching stays in sync with playback progress. Whoever owns
/// those two store instances (currently `OpenStreamRootView`) should call
/// `publish` from a `.task`/`.onChange` for each.
@MainActor
public final class AppleTopShelfPublisher {
    public static let shared = AppleTopShelfPublisher()

    private let writer: AppleTopShelfSnapshotWriter
    private var lastDigest: String?

    public init(writer: AppleTopShelfSnapshotWriter = .shared) {
        self.writer = writer
    }

    /// Cheap no-op when nothing relevant changed since the last publish; the
    /// actual file write happens on `AppleTopShelfSnapshotWriter`, off the
    /// main actor.
    public func publish(
        records: [AppleMediaRecord],
        sections: [AppleCatalogSection],
        enabled: Bool
    ) async {
        let digest = Self.digest(records: records, sections: sections, enabled: enabled)
        guard digest != lastDigest else { return }
        lastDigest = digest
        try? await writer.write(records: records, sections: sections, enabled: enabled)
    }

    private static func digest(
        records: [AppleMediaRecord],
        sections: [AppleCatalogSection],
        enabled: Bool
    ) -> String {
        let recordsKey = records
            .map { "\($0.id)|\($0.isFavorite)|\($0.progress ?? -1)|\($0.lastVerified.timeIntervalSince1970)" }
            .joined(separator: ",")
        let topPicksKey = sections.first(where: { !$0.items.isEmpty })?
            .items.prefix(10).map(\.id).joined(separator: ",") ?? ""
        return ApplePlaybackIdentity.digest(for: [
            enabled ? "1" : "0", recordsKey, topPicksKey,
        ].joined(separator: "\u{1f}"))
    }
}
