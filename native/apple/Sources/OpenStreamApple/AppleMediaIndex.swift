import Foundation
import Observation

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
    case gateway
}

public enum AppleMediaIndexError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(version):
            "This media index was created by a newer OpenStream version (\(version))."
        }
    }
}

public struct AppleMediaAvailability: Codable, Equatable, Sendable {
    public let instanceID: AppleSource.ID
    public let capability: AppleMediaPlaybackCapability
    /// Opaque lookup key only. It is never a URL, SMB path, or credential.
    public let itemReference: String
    public let lastVerified: Date

    public init(
        instanceID: AppleSource.ID,
        capability: AppleMediaPlaybackCapability,
        itemReference: String,
        lastVerified: Date = .now
    ) {
        self.instanceID = instanceID
        self.capability = capability
        self.itemReference = ApplePlaybackIdentity.digest(for: itemReference)
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
        availability: [AppleMediaAvailability],
        isFavorite: Bool = false,
        progress: Double? = nil,
        isPrivate: Bool = false,
        lastVerified: Date = .now
    ) {
        let cleanTitle = Self.clean(title, limit: 200)
        let cleanCanonical = canonicalID.map { Self.clean($0, limit: 200).lowercased() }.flatMap { $0.isEmpty ? nil : $0 }
        let fallback = "\(kind.rawValue)|\(Self.normalizedTitle(cleanTitle))|\(year.map(String.init) ?? "")"
        id = ApplePlaybackIdentity.digest(for: cleanCanonical.map { "canonical|\($0)" } ?? fallback)
        self.canonicalID = cleanCanonical
        self.kind = kind
        self.title = cleanTitle
        self.aliases = Array(Set(aliases.map { Self.clean($0, limit: 200) }.filter { !$0.isEmpty })).sorted()
        self.year = year.flatMap { (1_880 ... 2_200).contains($0) ? $0 : nil }
        self.summary = summary.map { Self.clean($0, limit: 4_000) }.flatMap { $0.isEmpty ? nil : $0 }
        self.artworkURL = Self.safeArtworkURL(artworkURL)
        self.availability = Self.deduplicate(availability)
        self.isFavorite = isFavorite
        self.progress = progress.flatMap { $0.isFinite && (0 ... 1).contains($0) ? $0 : nil }
        self.isPrivate = isPrivate
        self.lastVerified = lastVerified
    }

    fileprivate static func merged(_ lhs: AppleMediaRecord, _ rhs: AppleMediaRecord) -> AppleMediaRecord {
        var result = rhs
        result.availability = deduplicate(lhs.availability + rhs.availability)
        result.aliases = Array(Set(lhs.aliases + rhs.aliases)).sorted()
        result.isFavorite = lhs.isFavorite || rhs.isFavorite
        result.progress = lhs.progress ?? rhs.progress
        result.isPrivate = lhs.isPrivate || rhs.isPrivate
        return result
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
    }

    private var recordsByID: [String: AppleMediaRecord]
    private var searchTextByID: [String: String]
    private var orderedRecordIDs: [String]
    private let fileURL: URL
    private let blockedVersion: Int?

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultURL()
        guard FileManager.default.fileExists(atPath: self.fileURL.path) else {
            recordsByID = [:]
            searchTextByID = [:]
            orderedRecordIDs = []
            blockedVersion = nil
            return
        }

        do {
            let data = try Data(contentsOf: self.fileURL)
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.version == 1 else {
                recordsByID = [:]
                searchTextByID = [:]
                orderedRecordIDs = []
                blockedVersion = envelope.version
                return
            }
            let records = Dictionary(uniqueKeysWithValues: envelope.records.map { ($0.id, $0) })
            recordsByID = records
            searchTextByID = Self.makeSearchTextByID(records)
            orderedRecordIDs = Self.makeOrderedRecordIDs(records)
            blockedVersion = nil
        } catch {
            recordsByID = [:]
            searchTextByID = [:]
            orderedRecordIDs = []
            blockedVersion = nil
            let quarantineURL = self.fileURL
                .appendingPathExtension("corrupt-\(UUID().uuidString)")
            try? FileManager.default.moveItem(at: self.fileURL, to: quarantineURL)
        }
    }

    public func records() -> [AppleMediaRecord] {
        orderedRecordIDs.compactMap { recordsByID[$0] }
    }

    /// A visited search result may not occur in a provider's bounded shelves.
    public func upsert(_ record: AppleMediaRecord) throws {
        var next = recordsByID
        next[record.id] = next[record.id].map { AppleMediaRecord.merged($0, record) } ?? record
        try persist(next)
        recordsByID = next
        searchTextByID = Self.makeSearchTextByID(next)
        orderedRecordIDs = Self.makeOrderedRecordIDs(next)
    }

    /// Catalog shelves are a partial listing, unlike complete local-file scans.
    public func replaceCatalog(instanceID: AppleSource.ID, with incoming: [AppleMediaRecord]) throws {
        let incomingIDs = Set(incoming.map(\.id))
        let missing = recordsByID.values.filter { record in
            !incomingIDs.contains(record.id) && record.availability.contains {
                $0.instanceID == instanceID && $0.capability == .resolvable
            }
        }
        let saved = missing.filter { $0.isFavorite || ($0.progress ?? 0) > 0 }
            .sorted { $0.lastVerified > $1.lastVerified }.prefix(5_000)
        let recent = missing.filter { !$0.isFavorite && ($0.progress ?? 0) == 0 }
            .sorted { $0.lastVerified > $1.lastVerified }.prefix(200)
        let retained = Array(saved) + recent
        try replace(instanceID: instanceID, with: Array(incoming.prefix(10_000 - retained.count)) + retained)
    }

    /// Replaces one instance's projection only after its adapter produced a
    /// complete bounded snapshot. Other instances and user state are kept.
    public func replace(instanceID: AppleSource.ID, with incoming: [AppleMediaRecord]) throws {
        let previous = recordsByID
        var next = recordsByID
        for (id, record) in next {
            var updated = record
            updated.availability.removeAll { $0.instanceID == instanceID }
            if updated.availability.isEmpty { next.removeValue(forKey: id) }
            else { next[id] = updated }
        }
        for record in incoming.prefix(10_000) {
            guard record.availability.contains(where: { $0.instanceID == instanceID }) else { continue }
            var refreshed = record
            if let old = previous[record.id] {
                refreshed.aliases = Array(Set(old.aliases + refreshed.aliases)).sorted()
                refreshed.isFavorite = old.isFavorite || refreshed.isFavorite
                refreshed.progress = old.progress ?? refreshed.progress
                refreshed.isPrivate = old.isPrivate || refreshed.isPrivate
            }
            if let existing = next[record.id] {
                next[record.id] = AppleMediaRecord.merged(existing, refreshed)
            } else {
                next[record.id] = refreshed
            }
        }
        try persist(next)
        recordsByID = next
        searchTextByID = Self.makeSearchTextByID(next)
        orderedRecordIDs = Self.makeOrderedRecordIDs(next)
    }

    public func remove(instanceID: AppleSource.ID) throws {
        try replace(instanceID: instanceID, with: [])
    }

    /// Removes availability owned by instances that are no longer enabled.
    /// This is intentionally repository-wide so a disabled or deleted source
    /// cannot leave stale Search, Siri, Spotlight, or Top Shelf results behind.
    public func retainAvailability(for activeInstanceIDs: Set<AppleSource.ID>) throws {
        var next: [String: AppleMediaRecord] = [:]
        for (id, record) in recordsByID {
            var updated = record
            updated.availability.removeAll { !activeInstanceIDs.contains($0.instanceID) }
            if !updated.availability.isEmpty { next[id] = updated }
        }
        guard next != recordsByID else { return }
        try persist(next)
        recordsByID = next
        searchTextByID = Self.makeSearchTextByID(next)
        orderedRecordIDs = Self.makeOrderedRecordIDs(next)
    }

    public func updateProgress(_ progressByID: [String: Double]) throws {
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

    public func setFavorite(_ isFavorite: Bool, recordID: String) throws {
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
        let data = try JSONEncoder().encode(Envelope(version: 1, records: Array(values.values)))
        #if os(iOS) || os(tvOS) || os(visionOS)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        #else
        try data.write(to: fileURL, options: .atomic)
        #endif
    }

    private static func defaultURL() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appending(path: "OpenStream", directoryHint: .isDirectory)
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
    public static func catalogRecords(section: AppleCatalogSection, verifiedAt: Date = .now) -> [AppleMediaRecord] {
        section.items.map { catalogRecord(instanceID: section.sourceID, item: $0, verifiedAt: verifiedAt) }
    }

    public static func catalogRecord(
        instanceID: AppleSource.ID,
        item: AppleCatalogItem,
        verifiedAt: Date = .now
    ) -> AppleMediaRecord {
        AppleMediaRecord(
            canonicalID: AppleStremioMetadataClient.isIMDBIdentifier(item.mediaID) ? item.mediaID : nil,
            kind: item.type == "series" ? .series : .movie,
            title: item.name,
            year: item.releaseInfo.flatMap { Int($0.prefix(4)) },
            summary: item.summary,
            artworkURL: item.posterURL,
            availability: [.init(
                instanceID: instanceID,
                capability: .resolvable,
                itemReference: "\(item.type)|\(item.mediaID)",
                lastVerified: verifiedAt
            )],
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
        AppleMediaRecord(
            canonicalID: ApplePlaybackIdentity.digest(
                for: "library|\(source.id.uuidString)|\(item.relativePath)"
            ),
            kind: .video,
            title: AppleLibraryTitleParser.parse(item).title,
            year: AppleLibraryTitleParser.parse(item).year,
            availability: [.init(
                instanceID: source.id,
                capability: item.url.pathExtension.lowercased() == "mkv" ? .gateway : .direct,
                itemReference: item.id,
                lastVerified: verifiedAt
            )],
            isPrivate: true,
            lastVerified: verifiedAt
        )
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
            title: channel.name,
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

    public static func arrRecords(
        instanceID: AppleSource.ID,
        values: [AppleArrLibraryRecord],
        verifiedAt: Date = .now
    ) -> [AppleMediaRecord] {
        values.map { value in
            AppleMediaRecord(
                canonicalID: value.canonicalID,
                kind: value.kind,
                title: value.title,
                year: value.year,
                summary: value.summary,
                artworkURL: value.artworkURL,
                availability: [.init(
                    instanceID: instanceID,
                    capability: .gateway,
                    itemReference: value.id,
                    lastVerified: verifiedAt
                )],
                isPrivate: true,
                lastVerified: verifiedAt
            )
        }
    }
}

@MainActor
@Observable
public final class AppleMediaIndexStore {
    public private(set) var records: [AppleMediaRecord] = []
    /// Same records keyed by id. `record(id:)` was a linear scan over the
    /// whole index — about 220 ms on the owner's library — on the content
    /// page's critical path. Not observed: it is a lookup table, and the
    /// array beside it is what views watch.
    @ObservationIgnored private var recordsByID: [String: AppleMediaRecord] = [:]
    private let repository: AppleMediaIndexRepository

    public init(repository: AppleMediaIndexRepository = AppleMediaIndexRepository()) {
        self.repository = repository
    }

    public func load() async { setRecords(await repository.records()) }

    /// One record by id, without touching the array.
    public func record(id: String) -> AppleMediaRecord? { recordsByID[id] }

    private func setRecords(_ values: [AppleMediaRecord]) {
        records = values
        recordsByID = Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    public func upsert(_ record: AppleMediaRecord) async throws {
        try await repository.upsert(record)
        setRecords(await repository.records())
    }

    public func replaceCatalog(instanceID: AppleSource.ID, with values: [AppleMediaRecord]) async throws {
        try await repository.replaceCatalog(instanceID: instanceID, with: values)
        setRecords(await repository.records())
    }

    public func replace(instanceID: AppleSource.ID, with values: [AppleMediaRecord]) async throws {
        try await repository.replace(instanceID: instanceID, with: values)
        setRecords(await repository.records())
    }

    public func retainAvailability(for activeInstanceIDs: Set<AppleSource.ID>) async throws {
        try await repository.retainAvailability(for: activeInstanceIDs)
        setRecords(await repository.records())
    }

    public func synchronizePlaybackProgress(store: ApplePlaybackStore = ApplePlaybackStore()) async throws {
        var progressByID: [String: Double] = [:]
        for record in records {
            guard let progress = store.progress(for: record.id), progress.duration > 0 else { continue }
            progressByID[record.id] = min(max(progress.position / progress.duration, 0), 1)
        }
        try await repository.updateProgress(progressByID)
        setRecords(await repository.records())
    }

    public func setFavorite(_ isFavorite: Bool, recordID: String) async throws {
        try await repository.setFavorite(isFavorite, recordID: recordID)
        setRecords(await repository.records())
    }

    public func search(_ query: String) async -> [AppleMediaRecord] {
        await repository.search(query)
    }
}
