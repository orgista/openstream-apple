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
    /// Retired sources (`AppleRetiredSource`) this copy carried and dropped
    /// on reading, tombstoning their ids; more than none means the copy
    /// should be written again.
    private(set) var retiredSourceCount = 0
    public var lineup: Data?
    /// The import clock; an unrelated setting can advance `savedAt`.
    public var lineupUpdatedAt: Date?
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

    public var playbackTerminals: [String: ApplePlaybackTerminalEvents]
    public var playbackActivity: [String: ApplePlaybackProgress]

    private enum CodingKeys: String, CodingKey {
        case formatVersion, savedAt, sources, settings, playbackProgress, watchedHistory, watchedTombstones, watchlist, ratings
        case continueWatchingRemovals, sourceTombstones, playbackTerminals, playbackActivity, lineup, lineupUpdatedAt
    }

    public init(savedAt: Date = .now, sources: [AppleSource] = [], sourceTombstones: [UUID: Date] = [:], settings: [String: Data] = [:],
                playbackProgress: [String: ApplePlaybackProgress] = [:],
                watchedHistory: [String: Date] = [:],
                watchedTombstones: [String: Date] = [:],
                watchlist: [AppleMediaRecord] = [], ratings: [String: Int] = [:],
                continueWatchingRemovals: [String: Date] = [:],
                playbackTerminals: [String: ApplePlaybackTerminalEvents] = [:],
                playbackActivity: [String: ApplePlaybackProgress] = [:], lineup: Data? = nil, lineupUpdatedAt: Date? = nil) {
        formatVersion = 1
        self.savedAt = savedAt
        self.sourceTombstones = sourceTombstones
        self.sources = sources.filter { sourceTombstones[$0.id] == nil }.map(Self.portableSource)
        self.lineup = lineup
        self.lineupUpdatedAt = lineupUpdatedAt
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
        self.playbackActivity = playbackActivity.merging(playbackProgress.filter { $0.value.isComplete },
            uniquingKeysWith: ApplePlaybackConvergence.freshest)
        self.playbackTerminals = ApplePlaybackConvergence.terminals(playbackTerminals, watched: watchedHistory,
            unwatched: watchedTombstones, removals: continueWatchingRemovals,
            activity: playbackActivity.merging(playbackProgress, uniquingKeysWith: ApplePlaybackConvergence.freshest))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        savedAt = try container.decode(Date.self, forKey: .savedAt)
        sourceTombstones = try container.decodeIfPresent([UUID: Date].self, forKey: .sourceTombstones) ?? [:]
        sources = []
        for payload in try container.decode([AppleJSONValue].self, forKey: .sources) {
            let data = try JSONEncoder().encode(payload)
            if let source = try? JSONDecoder().decode(AppleSource.self, from: data) { sources.append(source) }
            else {
                guard let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let retired = AppleRetiredSource(fields: fields) else { throw AppleConfigurationError.invalidFile }
                if sourceTombstones[retired.id] == nil { sourceTombstones[retired.id] = savedAt }
                retiredSourceCount += 1
            }
        }
        lineup = try container.decodeIfPresent(Data.self, forKey: .lineup)
        lineupUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .lineupUpdatedAt)
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
        playbackActivity = (try container.decodeIfPresent([String: ApplePlaybackProgress].self, forKey: .playbackActivity) ?? [:])
            .merging(playbackProgress.filter { $0.value.isComplete }, uniquingKeysWith: ApplePlaybackConvergence.freshest)
        playbackTerminals = ApplePlaybackConvergence.terminals(
            try container.decodeIfPresent([String: ApplePlaybackTerminalEvents].self, forKey: .playbackTerminals) ?? [:],
            watched: watchedHistory, unwatched: watchedTombstones, removals: continueWatchingRemovals,
            activity: playbackActivity.merging(playbackProgress, uniquingKeysWith: ApplePlaybackConvergence.freshest))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(savedAt, forKey: .savedAt)
        if !sourceTombstones.isEmpty { try container.encode(sourceTombstones, forKey: .sourceTombstones) }
        try container.encode(sources, forKey: .sources)
        try container.encodeIfPresent(lineup, forKey: .lineup)
        if lineup != nil { try container.encodeIfPresent(lineupUpdatedAt, forKey: .lineupUpdatedAt) }
        try container.encode(settings, forKey: .settings)
        try container.encode(playbackProgress, forKey: .playbackProgress)
        if !playbackTerminals.isEmpty { try container.encode(playbackTerminals, forKey: .playbackTerminals) }
        if !playbackActivity.isEmpty { try container.encode(playbackActivity, forKey: .playbackActivity) }
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
        if let lineup { _ = try AppleChannelLineupFile.decode(lineup) }
        let sourceIDs = sources.map(\.id)
        guard Set(sourceIDs).count == sourceIDs.count,
              Set(watchlist.map(\.id)).count == watchlist.count else { throw AppleConfigurationError.invalidFile }
    }

    public func merging(_ incoming: Self) -> Self {
        var result = incoming
        if lineup != nil, AppleConfigurationSyncPolicy.lineupsEqual(lineup, incoming.lineup) {
            result.lineupUpdatedAt = max(lineupUpdatedAt ?? savedAt, incoming.lineupUpdatedAt ?? incoming.savedAt)
        } else if let lineup, incoming.lineup == nil || (lineupUpdatedAt ?? savedAt) > (incoming.lineupUpdatedAt ?? incoming.savedAt) {
            result.lineup = lineup
            result.lineupUpdatedAt = lineupUpdatedAt ?? savedAt
        }
        var combined: [AppleSource] = []
        for source in sources + incoming.sources {
            if let index = combined.firstIndex(where: { $0.id == source.id }) {
                var updated = source
                updated.connection = source.connection?.fillingMissingFields(from: combined[index].connection) ?? combined[index].connection
                if source.connection == nil, source.needsSignIn, source.url == Self.publicAddress(source.url),
                   source.url == Self.publicAddress(combined[index].url) {
                    updated.url = combined[index].url
                    updated.epgURL = source.epgURL ?? combined[index].epgURL
                }
                combined[index] = updated
            } else { combined.append(source) }
        }
        result.sourceTombstones = sourceTombstones.merging(incoming.sourceTombstones) { max($0, $1) }
        var selected: [AppleSource] = []
        for source in Array(incoming.sources.reversed()) + Array(combined.reversed()) {
            guard result.sourceTombstones[source.id] == nil, !selected.contains(where: { $0.id == source.id }) else { continue }
            if AppleSourceStore.matchingConfigurationMediaServer(source, in: selected) != nil {
                result.sourceTombstones[source.id] = max(savedAt, incoming.savedAt)
            } else { selected.append(combined.first { $0.id == source.id } ?? source) }
        }
        result.sources = selected.reversed()
        // Resume position: the freshest of the two per title, so a snapshot
        // written before this device's last play never winds it back (V6).
        result.playbackTerminals = playbackTerminals.merging(incoming.playbackTerminals) { $0.merging($1) }
        result.playbackActivity = playbackActivity.merging(incoming.playbackActivity, uniquingKeysWith: ApplePlaybackConvergence.freshest)
        result.playbackProgress = ApplePlaybackConvergence.reconciled(
            playbackProgress.merging(incoming.playbackProgress, uniquingKeysWith: ApplePlaybackConvergence.freshest),
            terminals: result.playbackTerminals)
        var history = AppleWatchedHistory(watched: watchedHistory, tombstones: watchedTombstones)
        history.merge(watched: incoming.watchedHistory, tombstones: incoming.watchedTombstones)
        history = ApplePlaybackConvergence.history(history, terminals: result.playbackTerminals)
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
        copy.playbackTerminals = ApplePlaybackConvergence.terminals(playbackTerminals, watched: watchedHistory,
            unwatched: watchedTombstones, removals: continueWatchingRemovals,
            activity: playbackActivity.merging(playbackProgress, uniquingKeysWith: ApplePlaybackConvergence.freshest))
        copy.playbackProgress = Self.newestCloudProgress(ApplePlaybackConvergence.reconciled(playbackProgress,
            terminals: copy.playbackTerminals))
        copy.playbackActivity = Self.newestCloudProgress(playbackActivity.filter { key, value in
            ApplePlaybackConvergence.activityIsCurrent(key: key, value: value, terminals: copy.playbackTerminals)
        })
        let history = ApplePlaybackConvergence.history(AppleWatchedHistory(watched: watchedHistory, tombstones: watchedTombstones),
            terminals: copy.playbackTerminals).newest(Self.cloudEntryLimit)
        copy.watchedHistory = history.watched
        copy.watchedTombstones = history.tombstones
        copy.continueWatchingRemovals = ApplePlaybackStore.boundedWatchedHistory(continueWatchingRemovals, limit: Self.cloudEntryLimit)

        let links = CloudStateLinks(snapshot: copy)
        let terminalEntries: [CloudTerminalEntry] = copy.playbackTerminals.map { key, value in
            let dates: [Date?] = [value.completedAt, value.resetAt, value.removedAt, value.playedAt]
            let eventDate: Date = dates.compactMap { $0 }.max() ?? .distantPast
            return CloudTerminalEntry(key: key, date: eventDate)
        }
        let entries: [CloudTerminalEntry] = terminalEntries.sorted { lhs, rhs in
            lhs.date == rhs.date ? lhs.key < rhs.key : lhs.date > rhs.date
        }
        let activityDates: [Date] = Array(copy.playbackProgress.values).map { $0.updatedAt }
            + Array(copy.playbackActivity.values).map { $0.updatedAt }
        let oldestActivity: Date? = activityDates.min()
        let linked = Set(links.progress.keys).union(links.activity.keys)
        var retained = Set(entries.prefix(Self.cloudTerminalLimit).map { $0.key }).union(linked)
        if let oldestActivity { retained.formUnion(entries.filter { $0.date > oldestActivity }.map { $0.key }) }
        for entry in entries where !retained.contains(entry.key) {
            _ = copy.retireCloudTerminal(entry, links: links, estimateBytes: false)
        }

        var data = try Self.encoder.encode(copy)
        // Retire the oldest item bundles first, including any stale state
        // that could recreate a retired barrier during decoding. Estimate
        // batches from individual rows, then verify the actual payload size;
        // a large history never requires one full encode per retired title.
        var oldestFirst = entries.reversed().filter { copy.playbackTerminals[$0.key] != nil }[...]
        while data.count > Self.maximumCloudBytes, !oldestFirst.isEmpty {
            var excess = data.count - Self.maximumCloudBytes
            while excess > 0, let entry = oldestFirst.popFirst() {
                // An individual newest item or the unrelated configuration
                // payload cannot fit: surface the existing quota error.
                if copy.playbackTerminals.count == 1 {
                    data = try Self.encoder.encode(copy)
                    guard data.count <= Self.maximumCloudBytes else { throw AppleConfigurationError.tooLarge }
                    return data
                }
                excess -= copy.retireCloudTerminal(entry, links: links)
            }
            data = try Self.encoder.encode(copy)
        }
        guard data.count <= Self.maximumCloudBytes else { throw AppleConfigurationError.tooLarge }
        return data
    }

    private static func newestCloudProgress(_ values: [String: ApplePlaybackProgress]) -> [String: ApplePlaybackProgress] {
        Dictionary(uniqueKeysWithValues: values.sorted {
            $0.value.updatedAt == $1.value.updatedAt ? $0.key < $1.key : $0.value.updatedAt > $1.value.updatedAt
        }.prefix(cloudEntryLimit).map { ($0.key, $0.value) })
    }

    private struct CloudTerminalEntry {
        let key: String
        let date: Date
    }

    private struct CloudStateLinks {
        let progress: [String: Set<String>]
        let activity: [String: Set<String>]
        let history: [String: Set<String>]

        init(snapshot: AppleConfigurationSnapshot) {
            func keys(_ values: [String: ApplePlaybackProgress]) -> [String: Set<String>] {
                var result: [String: Set<String>] = [:]
                for (key, value) in values {
                    var identities = Set([key])
                    if let normalized = ApplePlaybackIdentity.storageKey(for: key) { identities.insert(normalized) }
                    if let part = value.partID {
                        identities.insert(part)
                        if let normalized = ApplePlaybackIdentity.storageKey(for: part) { identities.insert(normalized) }
                    }
                    for identity in identities { result[identity, default: []].insert(key) }
                }
                return result
            }
            progress = keys(snapshot.playbackProgress)
            activity = keys(snapshot.playbackActivity)
            var histories: [String: Set<String>] = [:]
            let allKeys = Set(snapshot.watchedHistory.keys).union(snapshot.watchedTombstones.keys).union(snapshot.continueWatchingRemovals.keys)
            for key in allKeys {
                histories[key, default: []].insert(key)
                if let normalized = ApplePlaybackIdentity.storageKey(for: key) { histories[normalized, default: []].insert(key) }
            }
            history = histories
        }
    }

    private static func cloudEntryBytes<Value: Encodable>(_ key: String, _ value: Value) -> Int {
        max(1, ((try? encoder.encode([key: value]).count) ?? 2) - 1)
    }

    @discardableResult
    private mutating func retireCloudTerminal(_ entry: CloudTerminalEntry, links: CloudStateLinks, estimateBytes: Bool = true) -> Int {
        var bytes = 0
        if let value = playbackTerminals.removeValue(forKey: entry.key), estimateBytes {
            bytes += Self.cloudEntryBytes(entry.key, value)
        }
        for key in links.progress[entry.key] ?? [] {
            if let value = playbackProgress[key], value.updatedAt <= entry.date {
                if estimateBytes { bytes += Self.cloudEntryBytes(key, value) }
                playbackProgress.removeValue(forKey: key)
            }
        }
        for key in links.activity[entry.key] ?? [] {
            if let value = playbackActivity[key], value.updatedAt <= entry.date {
                if estimateBytes { bytes += Self.cloudEntryBytes(key, value) }
                playbackActivity.removeValue(forKey: key)
            }
        }
        for key in links.history[entry.key] ?? [] {
            if let date = watchedHistory[key], date <= entry.date {
                if estimateBytes { bytes += Self.cloudEntryBytes(key, date) }
                watchedHistory.removeValue(forKey: key)
            }
            if let date = watchedTombstones[key], date <= entry.date {
                if estimateBytes { bytes += Self.cloudEntryBytes(key, date) }
                watchedTombstones.removeValue(forKey: key)
            }
            if let date = continueWatchingRemovals[key], date <= entry.date {
                if estimateBytes { bytes += Self.cloudEntryBytes(key, date) }
                continueWatchingRemovals.removeValue(forKey: key)
            }
        }
        return max(1, bytes)
    }

    /// The cloud horizon retains these newest barriers as well as clocks
    /// linked to retained activity; local storage and backups remain complete.
    static let cloudTerminalLimit = 2_000

    /// Newest entries of each history the iCloud copy keeps.
    static let cloudEntryLimit = 500

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static let unavailableSourceURL = URL(string: "https://source.invalid/")!

    static func publicAddress(_ url: URL) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["https", "http", "smb"].contains(parts.scheme?.lowercased() ?? "") else {
            return unavailableSourceURL
        }
        parts.user = nil
        parts.password = nil
        parts.query = nil
        parts.fragment = nil
        parts.path = "/"
        return parts.url ?? unavailableSourceURL
    }

    static func portableSource(_ source: AppleSource) -> AppleSource {
        var copy = source
        let isLocal = source.kind == .library || source.url.isFileURL || AppleLocalPlaylistStore.isLocal(source.url)
        let address = isLocal ? nil : AppleSourceConnectionConfiguration.publicURL(source.url)
        copy.url = address ?? unavailableSourceURL
        copy.epgURL = isLocal ? nil : source.epgURL.flatMap(AppleSourceConnectionConfiguration.publicURL)
        if isLocal { copy.connection = nil }
        let isGuestShare = source.kind == .nas && (source.usesGuestAccess || source.connection?.requiresCredentials == false)
        copy.usesGuestAccess = isGuestShare
        copy.needsSignIn = source.needsSignIn || (source.credentialReference != nil && !isGuestShare)
            || source.kind == .mediaServer || address == nil
        copy.needsSourceAddress = source.needsSourceAddress || address == nil || source.epgURL != copy.epgURL
        if copy.needsSignIn || copy.needsSourceAddress {
            copy.isEnabledAfterSignIn = source.isEnabledAfterSignIn ?? source.isEnabled
            copy.isEnabled = false
        } else { copy.isEnabledAfterSignIn = nil }
        copy.credentialReference = nil
        copy.transportReference = nil
        copy.bookmarkData = nil
        copy.legacyUsername = nil
        copy.legacyPassword = nil
        copy.validationSummary = nil
        copy.validationFailureSummary = nil
        return copy
    }
}

/// Any JSON value, so each saved source can be read on its own and a retired
/// one skipped instead of failing the whole list.
indirect enum AppleJSONValue: Codable, Equatable, Sendable {
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
}
