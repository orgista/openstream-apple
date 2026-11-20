import Foundation
import Observation
import Synchronization

public enum AppleMediaKind: String, Codable, CaseIterable, Sendable {
    case movie
    case series
    case episode
    case channel
    case video
}

public enum AppleMediaPlaybackCapability: String, Codable, Sendable {
    case direct
    case resolvable

    /// Older indexes tagged MKV files with a value no build reads any more;
    /// any unknown value decodes as `direct`.
    public init(from decoder: any Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: rawValue) ?? .direct
    }
}

public enum AppleMediaIndexError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(version):
            "This media index was created by a newer oStream version (\(version))."
        }
    }
}

public struct AppleMediaAvailability: Codable, Equatable, Sendable {
    /// The one fixed source of titles known only from TMDB (a Top 10 row, a
    /// shared link). It is in no source list, and `retainAvailability` keeps
    /// it, so a favourite added from such a page survives the next launch.
    static let metadataOnlyInstanceID = UUID(uuid: (0x6F, 0x53, 0x74, 0x72, 0x65, 0x61, 0x6D, 0x00,
                                                    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01))

    public let instanceID: AppleSource.ID
    public let capability: AppleMediaPlaybackCapability
    /// Opaque lookup key only. It is never a URL, SMB path, or credential.
    public let itemReference: String
    /// The server's opaque item id, independent of its playback URL or session credentials.
    public let serverItemID: String?
    public var isStale: Bool?
    public let lastVerified: Date

    public init(
        instanceID: AppleSource.ID,
        capability: AppleMediaPlaybackCapability,
        itemReference: String,
        serverItemID: String? = nil,
        lastVerified: Date = .now
    ) {
        self.instanceID = instanceID
        self.capability = capability
        self.itemReference = ApplePlaybackIdentity.digest(for: itemReference)
        self.serverItemID = serverItemID
        self.lastVerified = lastVerified
    }

    init(reindexing previous: Self, serverItemID: String?, lastVerified: Date = .now) {
        instanceID = previous.instanceID
        capability = previous.capability
        itemReference = previous.itemReference
        self.serverItemID = serverItemID
        isStale = serverItemID == nil ? true : nil
        self.lastVerified = lastVerified
    }
}

public struct AppleMediaRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let canonicalID: String?
    public let kind: AppleMediaKind
    public var title: String
    public var aliases: [String]
    public var year: Int?
    public var summary: String?
    public var artworkURL: URL?
    /// The title's 16:9 backdrop, saved with the record so a landscape card —
    /// Continue Watching, the Top Shelf — still has a still to draw once no
    /// loaded shelf lists the title (N52). Records written before this field
    /// decode it as nil.
    public var backdropURL: URL?
    public var availability: [AppleMediaAvailability]
    public var isFavorite: Bool
    public var progress: Double?
    public var isPrivate: Bool
    public var lastVerified: Date

    public init(
        canonicalID: String? = nil,
        kind: AppleMediaKind,
        title: String,
        aliases: [String] = [],
        year: Int? = nil,
        summary: String? = nil,
        artworkURL: URL? = nil,
        backdropURL: URL? = nil,
        availability: [AppleMediaAvailability],
        isFavorite: Bool = false,
        progress: Double? = nil,
        isPrivate: Bool = false,
        lastVerified: Date = .now
    ) {
        let cleanTitle = Self.clean(title, limit: 200)
        let cleanCanonical = canonicalID.map { Self.clean($0, limit: 200).lowercased() }.flatMap { $0.isEmpty ? nil : $0 }
        id = ApplePlaybackIdentity.digest(for: cleanCanonical.map { "canonical|\($0)" }
            ?? "\(kind.rawValue)|\(Self.normalizedTitle(cleanTitle))|\(year.map(String.init) ?? "")")
        self.canonicalID = cleanCanonical
        self.kind = kind
        self.title = cleanTitle
        self.aliases = Array(Set(aliases.map { Self.clean($0, limit: 200) }.filter { !$0.isEmpty })).sorted()
        self.year = year.flatMap { (1_880 ... 2_200).contains($0) ? $0 : nil }
        self.summary = summary.map { Self.clean($0, limit: 4_000) }.flatMap { $0.isEmpty ? nil : $0 }
        self.artworkURL = Self.safeArtworkURL(artworkURL)
        self.backdropURL = Self.safeArtworkURL(backdropURL)
        self.availability = Self.deduplicate(availability)
        self.isFavorite = isFavorite
        self.progress = progress.flatMap { $0.isFinite && (0 ... 1).contains($0) ? $0 : nil }
        self.isPrivate = isPrivate
        self.lastVerified = lastVerified
    }

    fileprivate static func merged(_ lhs: AppleMediaRecord, _ rhs: AppleMediaRecord) -> AppleMediaRecord {
        var result = rhs
        result.backdropURL = rhs.backdropURL ?? lhs.backdropURL
        result.availability = deduplicate(lhs.availability + rhs.availability)
        result.aliases = Array(Set(lhs.aliases + rhs.aliases)).sorted()
        result.isFavorite = lhs.isFavorite || rhs.isFavorite
        result.progress = lhs.progress ?? rhs.progress
        result.isPrivate = lhs.isPrivate || rhs.isPrivate
        return result
    }

    /// Equal apart from when it was last verified.
    fileprivate func hasSameContent(as other: AppleMediaRecord) -> Bool {
        func undated(_ value: AppleMediaAvailability) -> String {
            "\(value.instanceID)|\(value.capability.rawValue)|\(value.itemReference)|\(value.serverItemID ?? "")|\(value.isStale.map(String.init) ?? "")"
        }
        var dated = self
        dated.lastVerified = other.lastVerified
        dated.availability = other.availability
        return dated == other && availability.map(undated) == other.availability.map(undated)
    }

    private static func deduplicate(_ values: [AppleMediaAvailability]) -> [AppleMediaAvailability] {
        Dictionary(grouping: values, by: { $0.instanceID }).compactMap { _, entries in
            entries.max { $0.lastVerified < $1.lastVerified }
        }.sorted { $0.instanceID.uuidString < $1.instanceID.uuidString }
    }

    private static func clean(_ value: String, limit: Int) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }

    private static func normalizedTitle(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func safeArtworkURL(_ value: URL?) -> URL? {
        guard let value else { return nil }
        if value.isFileURL { return nil }
        guard ["https", "http"].contains(value.scheme?.lowercased()),
              value.user == nil, value.password == nil else { return nil }
        return value
    }
}

public actor AppleMediaIndexRepository {
    private struct Envelope: Codable {
        let version: Int
        let records: [AppleMediaRecord]
        var successfulScans: [String: Date]? = nil
        /// Stamped by `AppleCachedCredentialPolicy.metadata` on write.
        var credentialScrub: Int? = nil
    }

    private var successfulScans: [String: Date] = [:]

    public func lastSuccessfulScan(for sourceID: AppleSource.ID) -> Date? {
        loadIfNeeded()
        return successfulScans[sourceID.uuidString]
    }

    private var recordsByID: [String: AppleMediaRecord] = [:] { didSet { version &+= 1 } }
    /// Grows with every change to the records or their order, so a reader can
    /// tell which of two snapshots is newer.
    private var version: UInt64 = 0
    private var searchTextByID: [String: String] = [:]
    private var orderedRecordIDs: [String] = [] { didSet { version &+= 1 } }
    private let fileURL: URL
    private var blockedVersion: Int?
    private var isLoaded = false

    /// Reads nothing: the file is read on the first call, on the actor. The
    /// app makes its index in the root view's state, and reading and scrubbing
    /// it there held the main thread ~250 ms at launch on an Apple TV 4K (2026-10-16).
    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
    }

    private func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            var envelope = try JSONDecoder().decode(Envelope.self, from: data)
            let scrubbed = envelope.credentialScrub == AppleCachedCredentialPolicy.version
            let clean = scrubbed ? data : try AppleCachedCredentialPolicy.metadata(data)
            if !scrubbed { envelope = try JSONDecoder().decode(Envelope.self, from: clean) }
            guard envelope.version == 1 else {
                blockedVersion = envelope.version
                return
            }
            if !scrubbed {
                #if os(iOS) || os(tvOS) || os(visionOS)
                try clean.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
                #else
                try clean.write(to: fileURL, options: .atomic)
                #endif
            }
            successfulScans = envelope.successfulScans ?? [:]
            let records = Dictionary(uniqueKeysWithValues: envelope.records.map { ($0.id, $0) })
            recordsByID = records
            searchTextByID = Self.makeSearchTextByID(records)
            orderedRecordIDs = Self.makeOrderedRecordIDs(records)
        } catch {
            let quarantineURL = fileURL.appendingPathExtension("corrupt-\(UUID().uuidString)")
            try? FileManager.default.moveItem(at: fileURL, to: quarantineURL)
        }
    }

    public func records() -> [AppleMediaRecord] {
        loadIfNeeded()
        return orderedRecordIDs.compactMap { recordsByID[$0] }
    }

    struct Snapshot: Sendable {
        let version: UInt64
        let records: [AppleMediaRecord]
    }

    func snapshot() -> Snapshot {
        let values = records()
        return Snapshot(version: version, records: values)
    }

    /// A visited search result may not occur in a provider's bounded shelves.
    public func upsert(_ record: AppleMediaRecord) throws {
        try upsert([record], refreshesVerification: true)
    }

    /// A record already indexed with the same content keeps its stored
    /// dates, so a reload that finds nothing new writes nothing.
    public func upsert(_ records: [AppleMediaRecord]) throws {
        try upsert(records, refreshesVerification: false)
    }

    private func upsert(_ records: [AppleMediaRecord], refreshesVerification: Bool) throws {
        loadIfNeeded()
        var next = recordsByID
        for record in records {
            guard let current = next[record.id] else {
                next[record.id] = record
                continue
            }
            let merged = AppleMediaRecord.merged(current, record)
            if refreshesVerification || !merged.hasSameContent(as: current) { next[record.id] = merged }
        }
        guard next != recordsByID else { return }
        try persist(next)
        recordsByID = next
        searchTextByID = Self.makeSearchTextByID(next)
        orderedRecordIDs = Self.makeOrderedRecordIDs(next)
    }

    /// Replaces one instance's projection only after its adapter produced a
    /// complete bounded snapshot. Other instances and user state are kept.
    public func replace(instanceID: AppleSource.ID, with incoming: [AppleMediaRecord], scanStatus: AppleLibraryScanStatus = .complete) throws {
        loadIfNeeded()
        try commit(Self.projected(recordsByID, instanceID: instanceID, incoming: incoming, scanStatus: scanStatus),
                   completedScans: scanStatus == .complete ? [instanceID] : [])
    }

    private static func projected(_ previous: [String: AppleMediaRecord], instanceID: AppleSource.ID,
                                  incoming: [AppleMediaRecord], scanStatus: AppleLibraryScanStatus) -> [String: AppleMediaRecord] {
        var next = previous
        for (id, record) in next {
            var updated = record
            if scanStatus == .complete {
                updated.availability.removeAll { $0.instanceID == instanceID }
            } else {
                for index in updated.availability.indices where updated.availability[index].instanceID == instanceID {
                    updated.availability[index].isStale = true
                }
            }
            if updated.availability.isEmpty { next.removeValue(forKey: id) }
            else { next[id] = updated }
        }
        for record in incoming {
            guard record.availability.contains(where: { $0.instanceID == instanceID }) else { continue }
            var refreshed = record
            if let old = previous[record.id] {
                refreshed.aliases = Array(Set(old.aliases + refreshed.aliases)).sorted()
                refreshed.isFavorite = old.isFavorite || refreshed.isFavorite
                refreshed.progress = old.progress ?? refreshed.progress
                refreshed.isPrivate = old.isPrivate || refreshed.isPrivate
                refreshed.backdropURL = refreshed.backdropURL ?? old.backdropURL
            }
            if let existing = next[record.id] {
                next[record.id] = AppleMediaRecord.merged(existing, refreshed)
            } else {
                next[record.id] = refreshed
            }
        }
        return next
    }

    private func commit(_ next: [String: AppleMediaRecord], completedScans: [AppleSource.ID]) throws {
        let oldScans = successfulScans
        for instanceID in completedScans { successfulScans[instanceID.uuidString] = .now }
        do { try persist(next) } catch { successfulScans = oldScans; throw error }
        recordsByID = next
        searchTextByID = Self.makeSearchTextByID(next)
        orderedRecordIDs = Self.makeOrderedRecordIDs(next)
    }

    public func remove(instanceID: AppleSource.ID) throws {
        loadIfNeeded()
        try replace(instanceID: instanceID, with: [])
    }

    /// Removes availability owned by instances that are no longer enabled.
    /// This is intentionally repository-wide so a disabled or deleted source
    /// cannot leave stale Search, Siri, Spotlight, or Top Shelf results behind.
    /// The metadata-only source is never removed.
    public func retainAvailability(for activeInstanceIDs: Set<AppleSource.ID>) throws {
        loadIfNeeded()
        let kept = activeInstanceIDs.union([AppleMediaAvailability.metadataOnlyInstanceID])
        var next: [String: AppleMediaRecord] = [:]
        for (id, record) in recordsByID {
            var updated = record
            updated.availability.removeAll { !kept.contains($0.instanceID) }
            if !updated.availability.isEmpty { next[id] = updated }
        }
        guard next != recordsByID else { return }
        try persist(next)
        recordsByID = next
        searchTextByID = Self.makeSearchTextByID(next)
        orderedRecordIDs = Self.makeOrderedRecordIDs(next)
    }

    public func updateProgress(_ progressByID: [String: Double]) throws {
        loadIfNeeded()
        var next = recordsByID
        for (id, record) in next {
            var updated = record
            updated.progress = progressByID[id]
            next[id] = updated
        }
        guard next != recordsByID else { return }
        try persist(next)
        recordsByID = next
    }

    func restoreConfigurationWatchlist(_ watchlist: [AppleMediaRecord]) throws {
        loadIfNeeded()
        var next = recordsByID
        for id in next.keys { next[id]?.isFavorite = false }
        for record in watchlist {
            var restored = next[record.id] ?? record
            restored.isFavorite = true
            next[record.id] = restored
        }
        try persist(next)
        recordsByID = next
        searchTextByID = Self.makeSearchTextByID(next)
        orderedRecordIDs = Self.makeOrderedRecordIDs(next)
    }

    public func setFavorite(_ isFavorite: Bool, recordID: String) throws {
        loadIfNeeded()
        guard var record = recordsByID[recordID], record.isFavorite != isFavorite else { return }
        record.isFavorite = isFavorite
        var next = recordsByID
        next[recordID] = record
        try persist(next)
        recordsByID = next
    }

    public enum SearchEligibility: Sendable {
        case all, systemDiscovery, playableVideo

        func includes(_ record: AppleMediaRecord) -> Bool {
            switch self {
            case .all: return true
            case .systemDiscovery: return !record.isPrivate && !record.availability.isEmpty
            case .playableVideo:
                return !record.isPrivate && [.movie, .series, .episode].contains(record.kind)
                    && record.availability.contains { $0.capability == .resolvable }
            }
        }
    }

    public func search(_ query: String, limit: Int = 100, eligibility: SearchEligibility = .all) -> [AppleMediaRecord] {
        loadIfNeeded()
        let tokens = Self.normalizedSearchText(query)
            .split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return [] }
        let maximumResults = min(max(limit, 1), 500)
        var results: [AppleMediaRecord] = []
        results.reserveCapacity(maximumResults)
        for id in orderedRecordIDs {
            guard let record = recordsByID[id], eligibility.includes(record),
                  let haystack = searchTextByID[id],
                  tokens.allSatisfy(haystack.contains) else {
                continue
            }
            results.append(record)
            if results.count == maximumResults { break }
        }
        return results
    }

    private static func makeSearchTextByID(
        _ records: [String: AppleMediaRecord]
    ) -> [String: String] {
        records.mapValues { record in
            normalizedSearchText(
                ([record.title] + record.aliases + [record.canonicalID ?? ""])
                    .joined(separator: " ")
            )
        }
    }

    private static func makeOrderedRecordIDs(
        _ records: [String: AppleMediaRecord]
    ) -> [String] {
        records.values.sorted { lhs, rhs in
            let comparison = lhs.title.localizedStandardCompare(rhs.title)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return lhs.id < rhs.id
        }.map(\.id)
    }

    private static func normalizedSearchText(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func persist(_ values: [String: AppleMediaRecord]) throws {
        if let blockedVersion {
            throw AppleMediaIndexError.unsupportedVersion(blockedVersion)
        }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try AppleCachedCredentialPolicy.metadata(JSONEncoder().encode(Envelope(version: 1, records: Array(values.values), successfulScans: successfulScans)))
        #if os(iOS) || os(tvOS) || os(visionOS)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        #else
        try data.write(to: fileURL, options: .atomic)
        #endif
    }

    static var defaultFileURL: URL {
        AppleStorageLocation.applicationSupport.appending(path: "OpenStream", directoryHint: .isDirectory)
            .appending(path: "media-index-v1.json")
    }
}

public enum AppleMediaRecommendationPolicy {
    public static func popular(
        from records: [AppleMediaRecord],
        limit: Int = 10
    ) -> [AppleMediaRecord] {
        records
            .filter {
                !$0.availability.isEmpty &&
                    ($0.kind == .movie || $0.kind == .series)
            }
            .sorted { lhs, rhs in
                let lhsScore = popularityScore(lhs)
                let rhsScore = popularityScore(rhs)
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                if lhs.year != rhs.year { return (lhs.year ?? 0) > (rhs.year ?? 0) }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            .prefix(min(max(limit, 1), 100))
            .map { $0 }
    }

    public static func recommendations(
        from records: [AppleMediaRecord],
        limit: Int = 12
    ) -> [AppleMediaRecord] {
        let signals = records.filter { $0.isFavorite || ($0.progress ?? 0) > 0 }
        guard !signals.isEmpty else { return [] }

        let preferredKinds = Set(signals.map(\.kind))
        let preferredInstances = Set(signals.flatMap { $0.availability.map(\.instanceID) })
        return records
            .filter { record in
                !record.availability.isEmpty &&
                    preferredKinds.contains(record.kind) &&
                    !record.isFavorite &&
                    record.progress == nil
            }
            .sorted { lhs, rhs in
                let lhsOverlap = lhs.availability.filter { preferredInstances.contains($0.instanceID) }.count
                let rhsOverlap = rhs.availability.filter { preferredInstances.contains($0.instanceID) }.count
                if lhsOverlap != rhsOverlap { return lhsOverlap > rhsOverlap }
                if lhs.year != rhs.year { return (lhs.year ?? 0) > (rhs.year ?? 0) }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            .prefix(min(max(limit, 1), 100))
            .map { $0 }
    }

    public static func newReleases(
        from records: [AppleMediaRecord],
        currentYear: Int,
        limit: Int = 12
    ) -> [AppleMediaRecord] {
        records
            .filter { record in
                !record.availability.isEmpty &&
                    (record.kind == .movie || record.kind == .series) &&
                    (record.year ?? 0) >= currentYear - 1
            }
            .sorted { lhs, rhs in
                if lhs.year != rhs.year { return (lhs.year ?? 0) > (rhs.year ?? 0) }
                if lhs.lastVerified != rhs.lastVerified { return lhs.lastVerified > rhs.lastVerified }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            .prefix(min(max(limit, 1), 100))
            .map { $0 }
    }

    private static func popularityScore(_ record: AppleMediaRecord) -> Int {
        let favorite = record.isFavorite ? 100 : 0
        let engagement = record.progress.map { Int($0 * 50) + 10 } ?? 0
        let availability = min(record.availability.count, 10) * 5
        return favorite + engagement + availability
    }
}

public enum AppleMediaIngestion {
    public static func catalogRecord(
        instanceID: AppleSource.ID,
        item: AppleCatalogItem,
        verifiedAt: Date = .now
    ) -> AppleMediaRecord {
        AppleMediaRecord(
            canonicalID: AppleXtreamReference.parse(item.mediaID) != nil ? item.mediaID
                : AppleMediaIdentifier.isIMDBIdentifier(item.mediaID) ? item.mediaID : item.imdbID,
            kind: item.type == "series" ? .series : .movie,
            title: item.name,
            year: item.releaseInfo.flatMap { Int($0.prefix(4)) },
            summary: item.summary,
            artworkURL: item.posterURL,
            backdropURL: item.backgroundURL,
            availability: [.init(
                instanceID: instanceID,
                capability: .resolvable,
                itemReference: "\(item.type)|\(item.mediaID)",
                serverItemID: AppleMediaServerItemReference.parse(item.mediaID).flatMap {
                    $0.sourceID == instanceID ? $0.itemID : nil
                },
                lastVerified: verifiedAt
            )],
            isPrivate: AppleXtreamReference.parse(item.mediaID) != nil,
            lastVerified: verifiedAt
        )
    }

    public static func libraryRecords(
        source: AppleSource,
        items: [AppleLibraryItem],
        verifiedAt: Date = .now
    ) -> [AppleMediaRecord] {
        items.map { libraryRecord(source: source, item: $0, verifiedAt: verifiedAt) }
    }

    public static func libraryRecord(
        source: AppleSource,
        item: AppleLibraryItem,
        verifiedAt: Date = .now
    ) -> AppleMediaRecord {
        let parsed = AppleLibraryTitleParser.parse(item)
        return AppleMediaRecord(
            canonicalID: libraryCanonicalID(sourceID: source.id, relativePath: item.relativePath),
            kind: .video,
            title: parsed.title,
            year: parsed.year,
            availability: [.init(
                instanceID: source.id,
                capability: .direct,
                itemReference: item.id,
                lastVerified: verifiedAt
            )],
            isPrivate: true,
            lastVerified: verifiedAt
        )
    }

    static func libraryPlaybackID(sourceID: AppleSource.ID, relativePath: String) -> String {
        ApplePlaybackIdentity.digest(for: "canonical|\(libraryCanonicalID(sourceID: sourceID, relativePath: relativePath))")
    }

    private static func libraryCanonicalID(sourceID: AppleSource.ID, relativePath: String) -> String {
        ApplePlaybackIdentity.digest(for: "library|\(sourceID.uuidString)|\(relativePath)")
    }

    public static func channelRecords(
        source: AppleSource,
        channels: [AppleIPTVChannel],
        verifiedAt: Date = .now
    ) -> [AppleMediaRecord] {
        channels.map { channelRecord(source: source, channel: $0, verifiedAt: verifiedAt) }
    }

    public static func channelRecord(
        source: AppleSource,
        channel: AppleIPTVChannel,
        verifiedAt: Date = .now
    ) -> AppleMediaRecord {
        AppleMediaRecord(
            canonicalID: ApplePlaybackIdentity.digest(
                for: "channel|\(source.id.uuidString)|\(channel.id)"
            ),
            kind: .channel,
            title: channel.displayName,
            aliases: channel.group.isEmpty ? [] : [channel.group],
            artworkURL: channel.logoURL,
            availability: [.init(
                instanceID: source.id,
                capability: .direct,
                itemReference: channel.id,
                lastVerified: verifiedAt
            )],
            isPrivate: true,
            lastVerified: verifiedAt
        )
    }
}

@MainActor
@Observable
public final class AppleMediaIndexStore {
    /// Cheap invalidation for derived snapshots, including same-count edits.
    public private(set) var revision: UInt64 = 0
    public private(set) var records: [AppleMediaRecord] = []
    /// Same records keyed by id. `record(id:)` was a linear scan over the
    /// whole index — about 220 ms on the owner's library — on the content
    /// page's critical path. Not observed: it is a lookup table, and the
    /// array beside it is what views watch.
    @ObservationIgnored private var recordsByID: [String: AppleMediaRecord] = [:]
    /// Where each id first occurs in `records`, so a prefix lookup can still
    /// answer with the earliest match the way `records.first` did.
    @ObservationIgnored private var recordOffsetByID: [String: Int] = [:]
    /// The repository version `records` was last published from.
    @ObservationIgnored private var publishedVersion: UInt64?
    private let repository: AppleMediaIndexRepository
    @ObservationIgnored private var playbackProgressWrite: Task<Void, Error>?
    @ObservationIgnored private var playbackProgressWriteRevision: UInt64 = 0

    public init(repository: AppleMediaIndexRepository = AppleMediaIndexRepository()) {
        self.repository = repository
    }

    public func load() async { await publishLatest() }

    /// One record by id, without scanning the array. Reads `records` so a
    /// view that looks a record up still redraws when the index changes.
    public func record(id: String) -> AppleMediaRecord? {
        _ = records
        return recordsByID[id]
    }

    /// The record a download belongs to: the one whose id is the download's
    /// media id, or a leading `id:` part of it (an episode download is
    /// `<record id>:<episode id>`). Looks up each such prefix instead of
    /// scanning the index once per download; with several matches, the one
    /// earliest in `records` wins, as the scan it replaces did.
    public func record(matchingMediaID mediaID: String) -> AppleMediaRecord? {
        _ = records
        var best = recordOffsetByID[mediaID]
        for index in mediaID.indices where mediaID[index] == ":" {
            guard let offset = recordOffsetByID[String(mediaID[..<index])] else { continue }
            best = min(best ?? offset, offset)
        }
        return best.map { records[$0] }
    }

    /// `recordsByID` and `recordOffsetByID` for one set of records.
    private struct Lookup: Sendable {
        let byID: [String: AppleMediaRecord]
        let offsetByID: [String: Int]

        init(_ values: [AppleMediaRecord]) {
            byID = Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            offsetByID = Dictionary(values.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    private func apply(_ values: [AppleMediaRecord], lookup: Lookup) {
        revision &+= 1
        records = values
        recordsByID = lookup.byID
        recordOffsetByID = lookup.offsetByID
    }

    private func publishLatest() async {
        await publish(await repository.snapshot())
    }

    /// Tries before a snapshot is put up without the unchanged check.
    private static let publishAttempts = 3
    /// Runs after each off-main compare; tests move `revision` here.
    @ObservationIgnored var afterOffMainCompare: (@MainActor () async -> Void)?

    /// Compares and indexes off the main actor. A snapshot older than the one
    /// already published is dropped: two writes can read the repository in
    /// one order and finish in the other. Every launch's rescan writes the
    /// same records back; an unchanged set must not redraw every view that
    /// reads them. If `records` moved during the compare, it is redone against
    /// the new records; the last try indexes without comparing.
    func publish(_ snapshot: AppleMediaIndexRepository.Snapshot) async {
        for attempt in 1...Self.publishAttempts {
            let current = records
            let currentRevision = revision
            let compares = attempt < Self.publishAttempts
            let lookup = await Task.detached(priority: .userInitiated) {
                compares && snapshot.records == current ? nil : Lookup(snapshot.records)
            }.value
            await afterOffMainCompare?()
            if let publishedVersion, snapshot.version < publishedVersion { return }
            guard revision == currentRevision || !compares else { continue }
            publishedVersion = snapshot.version
            guard let lookup else { return }
            appleTraceStep("media index publish \(snapshot.records.count)") { apply(snapshot.records, lookup: lookup) }
            return
        }
    }

    public func upsert(_ record: AppleMediaRecord) async throws {
        try await repository.upsert(record)
        await publishLatest()
    }

    public func upsert(_ records: [AppleMediaRecord]) async throws {
        guard !records.isEmpty else { return }
        try await repository.upsert(records)
        await publishLatest()
    }

    public func replace(instanceID: AppleSource.ID, with values: [AppleMediaRecord], scanStatus: AppleLibraryScanStatus = .complete) async throws {
        try await repository.replace(instanceID: instanceID, with: values, scanStatus: scanStatus)
        await publishLatest()
        appleTraceMainQueueSettle("media index replace publish")
    }

    public func retainAvailability(for activeInstanceIDs: Set<AppleSource.ID>) async throws {
        try await repository.retainAvailability(for: activeInstanceIDs)
        await publishLatest()
    }

    public func synchronizePlaybackProgress(store: ApplePlaybackStore = ApplePlaybackStore()) async throws {
        await load()
        try await beginSynchronizingPlaybackProgress(store: store).value
    }

    /// Saved playback is authoritative; Discover can draw its index projection before the file copy finishes.
    @discardableResult
    func beginSynchronizingPlaybackProgress(store: ApplePlaybackStore = ApplePlaybackStore()) -> Task<Void, Error> {
        var progressByID: [String: Double] = [:]
        for record in records {
            guard let progress = store.progress(for: record.id), progress.duration > 0 else { continue }
            progressByID[record.id] = min(max(progress.position / progress.duration, 0), 1)
        }
        applyPlaybackProgress(progressByID)
        let projectedRevision = revision
        playbackProgressWriteRevision &+= 1
        let generation = playbackProgressWriteRevision
        let previous = playbackProgressWrite
        let write = Task<Void, Error> { [repository, progressByID] in
            _ = await previous?.result
            try await repository.updateProgress(progressByID)
            guard generation == playbackProgressWriteRevision, revision != projectedRevision else { return }
            await publishLatest()
        }
        playbackProgressWrite = write
        return write
    }

    func waitForPlaybackProgressSynchronization() async throws {
        try await playbackProgressWrite?.value
    }

    /// Puts saved progress onto the published records in place: ids and order
    /// stay, so neither a full compare nor a new lookup is needed, and the
    /// published repository version still describes everything but progress.
    private func applyPlaybackProgress(_ progressByID: [String: Double]) {
        var projected = records
        var changed: [Int] = []
        for index in projected.indices {
            let progress = progressByID[projected[index].id]
            guard projected[index].progress != progress else { continue }
            projected[index].progress = progress
            changed.append(index)
        }
        guard !changed.isEmpty else { return }
        revision &+= 1
        records = projected
        // In order, so a duplicate id keeps its last record, as `Lookup` does.
        for index in changed { recordsByID[projected[index].id] = projected[index] }
    }

    func restoreConfigurationWatchlist(_ watchlist: [AppleMediaRecord]) async throws {
        try await repository.restoreConfigurationWatchlist(watchlist)
        await publishLatest()
    }

    public func setFavorite(_ isFavorite: Bool, recordID: String) async throws {
        try await repository.setFavorite(isFavorite, recordID: recordID)
        await publishLatest()
    }

    public func search(_ query: String) async -> [AppleMediaRecord] {
        await repository.search(query)
    }
}
