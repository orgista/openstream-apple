import Foundation

/// The last channel list a live source returned, on disk.
///
/// The Live tab re-fetched all **9376** of the owner's channels on every
/// launch: measured at **2137 ms** before the guide could show anything
/// (2026-09-15). A channel lineup changes rarely, so the saved copy is shown
/// at once and the network refresh lands underneath it.
public actor AppleIPTVChannelCache {
    public static let shared = AppleIPTVChannelCache()

    /// Past this the saved copy is still shown — it is the only thing that
    /// makes the tab instant — but it is clearly worth replacing.
    public static let staleAfter: TimeInterval = 12 * 60 * 60

    public struct Snapshot: Codable, Sendable, Equatable {
        public let channels: [AppleIPTVChannel]
        public let storedAt: Date

        public func isStale(now: Date = .now, after: TimeInterval = AppleIPTVChannelCache.staleAfter) -> Bool {
            now.timeIntervalSince(storedAt) >= after
        }
    }

    private let directory: URL?

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("OpenStream/LiveChannels", isDirectory: true)
    }

    public func snapshot(for sourceID: AppleSource.ID) -> Snapshot? {
        guard let url = fileURL(for: sourceID), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    public func store(_ channels: [AppleIPTVChannel], for sourceID: AppleSource.ID, now: Date = .now) {
        guard let directory, let url = fileURL(for: sourceID), !channels.isEmpty else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(Snapshot(channels: channels, storedAt: now)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public func remove(_ sourceID: AppleSource.ID) {
        guard let url = fileURL(for: sourceID) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Drops saved lists for sources that no longer exist, so a removed
    /// provider does not leave megabytes behind.
    public func retain(_ ids: Set<AppleSource.ID>) {
        guard let directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let keep = Set(ids.map { "\($0.uuidString).json" })
        for name in names where !keep.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private func fileURL(for sourceID: AppleSource.ID) -> URL? {
        directory?.appendingPathComponent("\(sourceID.uuidString).json")
    }
}
