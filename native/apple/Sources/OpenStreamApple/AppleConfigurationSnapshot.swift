import Foundation

struct AppleWatchedHistory {
    private struct Entry {
        let key: String
        let date: Date
        let isWatched: Bool
    }

    var watched: [String: Date] = [:]
    var tombstones: [String: Date] = [:]

    init(watched: [String: Date] = [:], tombstones: [String: Date] = [:]) {
        merge(watched: watched, tombstones: tombstones)
    }

    mutating func merge(watched incomingWatched: [String: Date], tombstones incomingTombstones: [String: Date]) {
        for (key, date) in incomingWatched {
            if let removed = tombstones[key], removed >= date { continue }
            if let previous = watched[key], previous >= date { continue }
            tombstones.removeValue(forKey: key)
            watched[key] = date
        }
        for (key, date) in incomingTombstones {
            if let previous = watched[key], previous > date { continue }
            if let previous = tombstones[key], previous >= date { continue }
            watched.removeValue(forKey: key)
            tombstones[key] = date
        }
    }

    func newest(_ limit: Int) -> Self {
        guard watched.count + tombstones.count > limit else { return self }
        let events = watched.map { Entry(key: $0.key, date: $0.value, isWatched: true) }
            + tombstones.map { Entry(key: $0.key, date: $0.value, isWatched: false) }
        let newest = events.sorted { $0.date == $1.date ? $0.key < $1.key : $0.date > $1.date }.prefix(limit)
        var result = Self()
        for entry in newest {
            if entry.isWatched { result.watched[entry.key] = entry.date }
            else { result.tombstones[entry.key] = entry.date }
        }
        return result
    }
}

public enum AppleConfigurationError: Error, Equatable, LocalizedError {
    case unsupportedVersion, passphraseRequired, wrongPassphrase, invalidFile, tooLarge
    /// A backup sealed with an iCloud Keychain key this device does not hold.
    case otherAppleAccount
    /// No iCloud Keychain backup key could be saved, so export needs a passphrase.
    case backupKeyUnavailable

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "Unsupported configuration version."
        case .passphraseRequired: "Passphrase required."
        case .wrongPassphrase: "Incorrect passphrase or damaged file."
        case .invalidFile: "Invalid configuration file."
        case .tooLarge: "Configuration exceeds the iCloud limit."
        case .otherAppleAccount: "This backup was made on another Apple Account."
        case .backupKeyUnavailable: "Add a passphrase to export."
        }
    }
}

/// Portable configuration only. Device bookmarks and Keychain references never cross devices.
public struct AppleConfigurationSnapshot: Codable, Equatable, Sendable {
    public static let maximumCloudBytes = 950_000 // Reserve room for the KVS key and overhead.
    public let formatVersion: Int
    public var savedAt: Date
    public var sources: [AppleSource]
    /// Removed identities stay removed when an offline device or old backup returns.
    /// Adding the provider again creates a new UUID; edits never clear a deletion.
    public var sourceTombstones: [UUID: Date]
    var preservedSourcePayloads: [ApplePreservedJSON] = []
    public var settings: [String: Data]
    public var playbackProgress: [String: ApplePlaybackProgress]
    /// Finished titles and when, keyed like `playbackProgress`. Snapshots
    /// written before this existed have none and import as empty.
    public var watchedHistory: [String: Date]
    /// Un-watch events are separate so older readers can still decode `watchedHistory`.
    public var watchedTombstones: [String: Date]
    public var watchlist: [AppleMediaRecord]
    public var ratings: [String: Int]
    /// Titles taken off Continue Watching, and when, keyed like
    /// `playbackProgress`. Older snapshots have none.
    public var continueWatchingRemovals: [String: Date]

    private enum CodingKeys: String, CodingKey {
        case formatVersion, savedAt, sources, settings, playbackProgress, watchedHistory, watchedTombstones, watchlist, ratings
        case continueWatchingRemovals, sourceTombstones
    }

    public init(savedAt: Date = .now, sources: [AppleSource] = [], sourceTombstones: [UUID: Date] = [:], settings: [String: Data] = [:],
                playbackProgress: [String: ApplePlaybackProgress] = [:],
                watchedHistory: [String: Date] = [:],
                watchedTombstones: [String: Date] = [:],
                watchlist: [AppleMediaRecord] = [], ratings: [String: Int] = [:],
                continueWatchingRemovals: [String: Date] = [:]) {
        formatVersion = 1
        self.savedAt = savedAt
        self.sourceTombstones = sourceTombstones
        self.sources = sources.filter { sourceTombstones[$0.id] == nil }.map(Self.portableSource)
        self.settings = settings
        self.playbackProgress = playbackProgress
        let history = AppleWatchedHistory(watched: watchedHistory, tombstones: watchedTombstones)
        self.watchedHistory = history.watched
        self.watchedTombstones = history.tombstones
        self.watchlist = watchlist.map { record in
            var copy = record
            copy.artworkURL = nil
            copy.availability = []
            return copy
        }
        self.ratings = ratings
        self.continueWatchingRemovals = continueWatchingRemovals
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        savedAt = try container.decode(Date.self, forKey: .savedAt)
        sourceTombstones = try container.decodeIfPresent([UUID: Date].self, forKey: .sourceTombstones) ?? [:]
        sources = []
        for payload in try container.decode([ApplePreservedJSON].self, forKey: .sources) {
            let data = try JSONEncoder().encode(payload)
            if let source = try? JSONDecoder().decode(AppleSource.self, from: data) { sources.append(source) }
            else {
                guard case .object(let fields) = payload, case .string(let kind) = fields["kind"],
                      AppleSourceKind(rawValue: kind) == nil, let id = payload.sourceID,
                      UUID(uuidString: id) != nil else { throw AppleConfigurationError.invalidFile }
                preservedSourcePayloads.append(payload)
            }
        }
        settings = try container.decode([String: Data].self, forKey: .settings)
        playbackProgress = try container.decode([String: ApplePlaybackProgress].self, forKey: .playbackProgress)
        let history = AppleWatchedHistory(
            watched: try container.decodeIfPresent([String: Date].self, forKey: .watchedHistory) ?? [:],
            tombstones: try container.decodeIfPresent([String: Date].self, forKey: .watchedTombstones) ?? [:])
        watchedHistory = history.watched
        watchedTombstones = history.tombstones
        watchlist = try container.decode([AppleMediaRecord].self, forKey: .watchlist)
        ratings = try container.decode([String: Int].self, forKey: .ratings)
        continueWatchingRemovals = try container.decodeIfPresent([String: Date].self,
                                                                 forKey: .continueWatchingRemovals) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(savedAt, forKey: .savedAt)
        if !sourceTombstones.isEmpty { try container.encode(sourceTombstones, forKey: .sourceTombstones) }
        let sourcePayloads = try sources.map { source in
            try JSONDecoder().decode(ApplePreservedJSON.self, from: JSONEncoder().encode(source))
        }
        try container.encode(sourcePayloads + preservedSourcePayloads, forKey: .sources)
        try container.encode(settings, forKey: .settings)
        try container.encode(playbackProgress, forKey: .playbackProgress)
        try container.encode(watchedHistory, forKey: .watchedHistory)
        if !watchedTombstones.isEmpty { try container.encode(watchedTombstones, forKey: .watchedTombstones) }
        try container.encode(watchlist, forKey: .watchlist)
        try container.encode(ratings, forKey: .ratings)
        if !continueWatchingRemovals.isEmpty {
            try container.encode(continueWatchingRemovals, forKey: .continueWatchingRemovals)
        }
    }

    public func validate() throws {
        guard formatVersion == 1 else { throw AppleConfigurationError.unsupportedVersion }
        let sourceIDs = sources.map(\.id) + preservedSourcePayloads.compactMap { $0.sourceID.flatMap(UUID.init(uuidString:)) }
        guard Set(sourceIDs).count == sourceIDs.count,
              Set(watchlist.map(\.id)).count == watchlist.count else { throw AppleConfigurationError.invalidFile }
    }

    public func merging(_ incoming: Self) -> Self {
        var result = incoming
        var combined = sources
        for source in incoming.sources {
            if let index = combined.firstIndex(where: { $0.id == source.id }) { combined[index] = source }
            else { combined.append(source) }
        }
        result.sourceTombstones = sourceTombstones.merging(incoming.sourceTombstones) { max($0, $1) }
        result.sources = combined.filter { result.sourceTombstones[$0.id] == nil }
        result.preservedSourcePayloads = Self.mergedPayloads(preservedSourcePayloads, incoming.preservedSourcePayloads)
            .filter { payload in
                guard let id = payload.sourceID.flatMap(UUID.init(uuidString:)) else { return true }
                return result.sourceTombstones[id] == nil
            }
        // Resume position: the freshest of the two per title, so a snapshot
        // written before this device's last play never winds it back (V6).
        result.playbackProgress = playbackProgress.merging(incoming.playbackProgress) { mine, theirs in
            theirs.updatedAt >= mine.updatedAt ? theirs : mine
        }
        var history = AppleWatchedHistory(watched: watchedHistory, tombstones: watchedTombstones)
        history.merge(watched: incoming.watchedHistory, tombstones: incoming.watchedTombstones)
        result.watchedHistory = history.watched
        result.watchedTombstones = history.tombstones
        result.continueWatchingRemovals = AppleContinueWatchingRemovalPolicy.merged(
            continueWatchingRemovals, incoming.continueWatchingRemovals)
        return result
    }

    public func cloudData() throws -> Data {
        try validate()
        var copy = self
        copy.sources = sources.map(Self.portableSource)
        let newest = playbackProgress.sorted {
            $0.value.updatedAt == $1.value.updatedAt ? $0.key < $1.key : $0.value.updatedAt > $1.value.updatedAt
        }.prefix(Self.cloudEntryLimit)
        copy.playbackProgress = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        let newestWatched = AppleWatchedHistory(watched: watchedHistory, tombstones: watchedTombstones)
            .newest(Self.cloudEntryLimit)
        copy.watchedHistory = newestWatched.watched
        copy.watchedTombstones = newestWatched.tombstones
        copy.continueWatchingRemovals = ApplePlaybackStore.boundedWatchedHistory(
            continueWatchingRemovals, limit: Self.cloudEntryLimit)
        var data = try Self.encoder.encode(copy)
        // Large episode identifiers can still exceed the quota with fewer
        // than 500 entries. The oldest entry of either list goes first.
        let progressEntries: [CloudTrimEntry] = newest.map { CloudTrimEntry(key: $0.key, date: $0.value.updatedAt, isWatched: false) }
        let watchedEntries: [CloudTrimEntry] = newestWatched.watched.map { CloudTrimEntry(key: $0.key, date: $0.value, isWatched: true) }
            + newestWatched.tombstones.map { CloudTrimEntry(key: $0.key, date: $0.value, isWatched: true) }
        var oldestFirst = (progressEntries + watchedEntries).sorted(by: CloudTrimEntry.isOlder)[...]
        while data.count > Self.maximumCloudBytes, let entry = oldestFirst.popFirst() {
            if entry.isWatched {
                copy.watchedHistory.removeValue(forKey: entry.key)
                copy.watchedTombstones.removeValue(forKey: entry.key)
            }
            else { copy.playbackProgress.removeValue(forKey: entry.key) }
            data = try Self.encoder.encode(copy)
        }
        guard data.count <= Self.maximumCloudBytes else { throw AppleConfigurationError.tooLarge }
        return data
    }

    private struct CloudTrimEntry {
        let key: String
        let date: Date
        let isWatched: Bool

        static func isOlder(_ lhs: Self, _ rhs: Self) -> Bool {
            lhs.date == rhs.date ? lhs.key > rhs.key : lhs.date < rhs.date
        }
    }

    /// Newest entries of each history the iCloud copy keeps.
    static let cloudEntryLimit = 500

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func publicAddress(_ url: URL) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["https", "http", "smb"].contains(parts.scheme?.lowercased() ?? "") else {
            return URL(string: "https://source.invalid/")!
        }
        parts.user = nil
        parts.password = nil
        parts.query = nil
        parts.fragment = nil
        parts.path = "/"
        return parts.url ?? URL(string: "https://source.invalid/")!
    }

    /// An unconfigured add-on's manifest URL is the same for everyone, so it
    /// travels whole and restores signed in (`AppleAddonURLSecretPolicy`).
    static func keepsFullAddress(_ source: AppleSource) -> Bool {
        #if OPENSTREAM_ADDONS

        source.isAddon && !source.needsSignIn && source.credentialReference == nil
            && source.epgURL == nil && !AppleAddonURLSecretPolicy.isSecret(source.url)

        #else
        false
        #endif
    }

    static func portableSource(_ source: AppleSource) -> AppleSource {
        var copy = source
        if keepsFullAddress(source) {
            copy.needsSignIn = false
        } else {
            copy.url = publicAddress(source.url)
            copy.needsSignIn = source.needsSignIn || source.credentialReference != nil
                || source.transportReference != nil || source.url != copy.url || source.epgURL != nil
        }
        copy.credentialReference = nil
        copy.transportReference = nil
        copy.bookmarkData = nil
        copy.legacyUsername = nil
        copy.legacyPassword = nil
        copy.epgURL = nil
        // The add-on's logo shows on the restored row; one served from under a
        // configured add-on's secret path stays behind.
        #if OPENSTREAM_ADDONS
        if let logo = source.logoURL, AppleAddonURLSecretPolicy.isSecretAsset(logo) { copy.logoURL = nil }
        #endif
        copy.validationSummary = nil
        copy.validationFailureSummary = nil
        return copy
    }
}

/// Round-trips source kinds this build cannot use, including future versions.
/// No interpretation of their protocol, catalogs or resource URLs takes place.
indirect enum ApplePreservedJSON: Codable, Equatable, Sendable {
    case object([String: Self]), array([Self]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode([String: Self].self) { self = .object(value) }
        else { self = .array(try c.decode([Self].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    func stringField(_ key: String) -> String? {
        guard case .object(let fields) = self, case .string(let value) = fields[key] else { return nil }
        return value
    }
    var sourceID: String? {
        guard case .object(let fields) = self, case .string(let id) = fields["id"] else { return nil }
        return id
    }
}

extension AppleConfigurationSnapshot {
    static func mergedPayloads(_ existing: [ApplePreservedJSON], _ incoming: [ApplePreservedJSON]) -> [ApplePreservedJSON] {
        var result = existing
        for payload in incoming {
            if let id = payload.sourceID, let index = result.firstIndex(where: { $0.sourceID == id }) { result[index] = payload }
            else if !result.contains(payload) { result.append(payload) }
        }
        return result
    }
}
