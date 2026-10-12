import Foundation

public struct ApplePlaybackProgress: Codable, Equatable, Sendable {
    public static let completionFraction = 0.95
    public static let completionRemainingSeconds = 30.0

    public let position: Double
    public let duration: Double
    public let updatedAt: Date
    /// Which part of the title this position belongs to: the episode's media
    /// id for a series, the resolved id for a film, `nil` for a local file.
    /// A series keeps one entry under the show — that is what Continue
    /// Watching lists — so without this a viewer who finished episode 1 and
    /// opened episode 2 would be dropped 40 minutes into it.
    public let partID: String?

    public init(position: Double, duration: Double, updatedAt: Date = .now, partID: String? = nil) {
        self.position = position
        self.duration = duration
        self.updatedAt = updatedAt
        self.partID = partID
    }

    public var resumePosition: Double? {
        guard duration > 0, position >= 15, !isComplete else { return nil }
        return position
    }

    /// The resume point for `partID`, or nil when the stored position belongs
    /// to a different episode. Entries saved before this field existed carry
    /// no part and only resume something that also names none.
    public func resumePosition(for partID: String?) -> Double? {
        guard self.partID == partID else { return nil }
        return resumePosition
    }

    public var isComplete: Bool {
        guard duration.isFinite, position.isFinite, duration > 0, position >= 0 else { return false }
        let clampedPosition = min(position, duration)
        return clampedPosition >= duration * Self.completionFraction
            || duration - clampedPosition <= Self.completionRemainingSeconds
    }
}

/// Where a title starts when the viewer presses Play: the position the store
/// holds for that exact part, or nil to start at the beginning. One place, so
/// every play path in the detail page agrees — they all passed `nil` before,
/// which is why a Continue Watching title restarted from zero (owner
/// 2026-09-14: "continue watching does not actually have placement of where
/// you left off").
@MainActor
public enum AppleDetailResume {
    public static func position(
        mediaID: String,
        partID: String?,
        store: ApplePlaybackStore = ApplePlaybackStore()
    ) -> Double? {
        store.progress(for: mediaID)?.resumePosition(for: partID)
    }

    /// Only a series has parts. A film has one, so tying its position to the
    /// resolved media id would drop the resume point whenever metadata
    /// resolution answered differently between two launches.
    nonisolated public static func partID(type: String?, mediaID: String?) -> String? {
        type == "series" ? mediaID : nil
    }
}

@MainActor
public final class ApplePlaybackStore {
    private let defaults: UserDefaults
    private let key = "openstream.playback.progress.v1"

    /// In-memory copy of the progress map. UserDefaults stays the backing
    /// store (write-through), but reads and each per-tick save no longer
    /// decode + re-encode the whole dictionary. `nil` means not yet loaded.
    private var cache: [String: ApplePlaybackProgress]?
    private var cachedData: Data?

    /// What has been finished, keyed like the progress map, valued by when.
    /// A finished title leaves the progress map (that is how it leaves
    /// Continue Watching), so without this nothing remembered it: no episode
    /// ever showed its tick and "next episode" always meant the first one.
    /// Watching a finished episode again does not take it off this list.
    private let watchedKey = "openstream.playback.watched.v1"
    private let unwatchedKey = "openstream.playback.unwatched.v1"
    private var watchedCache: [String: Date]?
    private var watchedCachedData: Data?
    private var unwatchedCache: [String: Date]?
    private var unwatchedCachedData: Data?
    /// The newest this many finished titles are kept.
    nonisolated public static let watchedHistoryLimit = 5_000
    /// Titles the viewer took off Continue Watching, and when. The progress
    /// stays; the row leaves the title out until it is played again.
    private let continueWatchingRemovedKey = "openstream.playback.continueWatchingRemoved.v1"
    private var removedCache: [String: Date]?
    private var removedCachedData: Data?
    /// The newest this many removals are kept.
    nonisolated public static let continueWatchingRemovalLimit = 500

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Saved entries for library adapters; avoids scanning every provider title on each save.
    func savedProgress() -> [String: ApplePlaybackProgress] { entries() }

    public func progress(for mediaID: String) -> ApplePlaybackProgress? {
        guard let storageKey = ApplePlaybackIdentity.storageKey(for: mediaID) else { return nil }
        return entries()[storageKey]
    }

    /// The finished titles among `mediaIDs`, from one read of the watched
    /// history: callers that check a whole episode list during a redraw stay
    /// O(1) reads. A progress entry that is itself complete (one restored
    /// from an older backup) counts too.
    public func completedMediaIDs(among mediaIDs: [String]) -> Set<String> {
        let watched = watchedEntries()
        let tombstones = storedWatchedTombstones()
        let all = entries()
        return Set(mediaIDs.filter { mediaID in
            guard let storageKey = ApplePlaybackIdentity.storageKey(for: mediaID) else { return false }
            #if DEBUG
            if AppleWatchedHistoryFixture.isSeeded(mediaID: mediaID, storageKey: storageKey) { return true }
            #endif
            if tombstones[storageKey] != nil { return false }
            return watched[storageKey] != nil || all[storageKey]?.isComplete == true
        })
    }

    public func isWatched(mediaID: String) -> Bool {
        !completedMediaIDs(among: [mediaID]).isEmpty
    }

    /// "Mark as Watched": records `mediaID` as finished now.
    public func markWatched(mediaID: String, at date: Date = .now) {
        guard let storageKey = ApplePlaybackIdentity.storageKey(for: mediaID) else { return }
        var history = AppleWatchedHistory(watched: watchedEntries(), tombstones: storedWatchedTombstones())
        history.merge(watched: [storageKey: date], tombstones: [:])
        #if DEBUG
        AppleWatchedHistoryFixture.unwatched.remove(storageKey)
        #endif
        persistWatched(history.watched, tombstones: history.tombstones)
    }

    /// "Mark as Unwatched": records a deletion event. A resumable
    /// position for it, if any, stays.
    public func markUnwatched(mediaID: String, at date: Date = .now) {
        guard let storageKey = ApplePlaybackIdentity.storageKey(for: mediaID) else { return }
        var watched = watchedEntries()
        #if DEBUG
        if AppleWatchedHistoryFixture.isEnabled {
            AppleWatchedHistoryFixture.unwatched.insert(storageKey)
            watched.removeValue(forKey: storageKey)
            persistWatched(watched)
            return
        }
        #endif
        var history = AppleWatchedHistory(watched: watched, tombstones: storedWatchedTombstones())
        history.merge(watched: [:], tombstones: [storageKey: date])
        persistWatched(history.watched, tombstones: history.tombstones)
        var progress = entries()
        if progress[storageKey]?.isComplete == true {
            progress.removeValue(forKey: storageKey)
            persist(progress)
        }
    }

    /// "Remove from Continue Watching": leaves the progress and the watched
    /// history alone, and hides the title from the row until it is played
    /// again (a later progress save).
    public func removeFromContinueWatching(mediaID: String, at date: Date = .now) {
        guard let storageKey = ApplePlaybackIdentity.storageKey(for: mediaID) else { return }
        var removed = continueWatchingRemovals()
        removed[storageKey] = date
        persistRemovals(removed)
    }

    /// Whether the viewer took `mediaID` off Continue Watching and has not
    /// played it since.
    public func isRemovedFromContinueWatching(mediaID: String) -> Bool {
        guard let storageKey = ApplePlaybackIdentity.storageKey(for: mediaID) else { return false }
        return AppleContinueWatchingRemovalPolicy.isRemoved(
            removedAt: continueWatchingRemovals()[storageKey], lastPlayedAt: entries()[storageKey]?.updatedAt)
    }

    public func progress(for url: URL) -> ApplePlaybackProgress? {
        entries()[ApplePlaybackIdentity.storageKey(for: url)]
    }

    public func save(mediaID: String, position: Double, duration: Double, partID: String? = nil) {
        guard let storageKey = ApplePlaybackIdentity.storageKey(for: mediaID) else { return }
        AppleInteractionTrace.record(.playback,
            "progress save key=\(storageKey) pos=\(Int(position.isFinite ? position : -1)) dur=\(Int(duration.isFinite ? duration : -1)) part=\(partID ?? "-")")
        save(storageKey: storageKey, position: position, duration: duration, partID: partID)
    }

    public func save(url: URL, position: Double, duration: Double, partID: String? = nil) {
        save(storageKey: ApplePlaybackIdentity.storageKey(for: url), position: position, duration: duration, partID: partID)
    }

    public func clear(mediaID: String) {
        guard let storageKey = ApplePlaybackIdentity.storageKey(for: mediaID) else { return }
        clear(storageKey: storageKey)
    }

    public func clear(url: URL) {
        clear(storageKey: ApplePlaybackIdentity.storageKey(for: url))
    }

    private func save(storageKey: String, position: Double, duration: Double, partID: String?) {
        guard position.isFinite, position >= 0, duration.isFinite, duration > 0 else { return }
        var current = entries()
        // A save that names no episode never replaces a series' episode
        // progress (a stray play of the whole show wiped S1E2's Resume).
        guard AppleSeriesProgressGuard.mayOverwrite(existing: current[storageKey], with: partID) else {
            AppleInteractionTrace.record(.playback, "progress save dropped key=\(storageKey): no episode over episode progress")
            return
        }
        let progress = ApplePlaybackProgress(position: min(position, duration), duration: duration, partID: partID)
        if progress.isComplete {
            current.removeValue(forKey: storageKey)
            // A series keeps its entry under the show and names the episode
            // in `partID`; the episode is what was finished, not the show.
            let finishedKey = partID.flatMap(ApplePlaybackIdentity.storageKey(for:)) ?? storageKey
            var history = AppleWatchedHistory(watched: watchedEntries(), tombstones: storedWatchedTombstones())
            // The last half-minute saves "complete" several times; one
            // record per viewing is enough.
            if history.watched[finishedKey].map({ progress.updatedAt.timeIntervalSince($0) > 600 }) ?? true {
                history.merge(watched: [finishedKey: progress.updatedAt], tombstones: [:])
                persistWatched(history.watched, tombstones: history.tombstones, notify: false)
            }
        } else {
            current[storageKey] = progress
        }
        // Playing it again brings a removed title back to Continue Watching.
        var removed = continueWatchingRemovals()
        if removed.removeValue(forKey: storageKey) != nil { persistRemovals(removed, notify: false) }
        persist(current)
    }

    private func clear(storageKey: String) {
        var current = entries()
        current.removeValue(forKey: storageKey)
        persist(current)
    }

    private func entries() -> [String: ApplePlaybackProgress] {
        // One read of the stored blob: it is compared, decoded and kept from
        // the same value (it was read three times on a miss, N47).
        let storedData = defaults.data(forKey: key)
        if let cache, cachedData == storedData { return cache }
        let loaded: [String: ApplePlaybackProgress]
        var keptData = storedData
        if let data = storedData {
            let decoded = (try? JSONDecoder().decode([String: ApplePlaybackProgress].self, from: data)) ?? [:]
            var normalized: [String: ApplePlaybackProgress] = [:]
            for (mediaID, progress) in decoded {
                if let storageKey = ApplePlaybackIdentity.storageKey(for: mediaID) {
                    normalized[storageKey] = progress
                }
            }
            loaded = normalized
            if loaded.keys.sorted() != decoded.keys.sorted() {
                let rewritten = try? JSONEncoder().encode(loaded)
                defaults.set(rewritten, forKey: key)
                keptData = rewritten
            }
        } else {
            loaded = [:]
        }
        cache = loaded
        cachedData = keptData
        return loaded
    }

    private func watchedEntries() -> [String: Date] {
        #if DEBUG
        if AppleWatchedHistoryFixture.isEnabled { return AppleWatchedHistoryFixture.memory }
        #endif
        return storedWatchedHistory().watched
    }

    private func persistWatched(_ entries: [String: Date], tombstones: [String: Date] = [:], notify: Bool = true) {
        #if DEBUG
        if AppleWatchedHistoryFixture.isEnabled {
            AppleWatchedHistoryFixture.memory = Self.boundedWatchedHistory(entries)
            if notify { ApplePlaybackProgressFeed.shared.storeDidChange() }
            return
        }
        #endif
        persistStoredWatched(AppleWatchedHistory(watched: entries, tombstones: tombstones), notify: notify)
    }

    private func storedWatchedEntries() -> [String: Date] {
        let storedData = defaults.data(forKey: watchedKey)
        if let watchedCache, watchedCachedData == storedData { return watchedCache }
        let decoded = storedData.flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) } ?? [:]
        watchedCache = decoded
        watchedCachedData = storedData
        return decoded
    }

    private func storedWatchedTombstones() -> [String: Date] {
        let storedData = defaults.data(forKey: unwatchedKey)
        if let unwatchedCache, unwatchedCachedData == storedData { return unwatchedCache }
        let decoded = storedData.flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) } ?? [:]
        unwatchedCache = decoded
        unwatchedCachedData = storedData
        return decoded
    }

    private func storedWatchedHistory() -> AppleWatchedHistory {
        AppleWatchedHistory(watched: storedWatchedEntries(), tombstones: storedWatchedTombstones())
    }

    private func persistStoredWatched(_ history: AppleWatchedHistory, notify: Bool) {
        let bounded = history.newest(Self.watchedHistoryLimit)
        watchedCache = bounded.watched
        watchedCachedData = try? JSONEncoder().encode(bounded.watched)
        unwatchedCache = bounded.tombstones
        unwatchedCachedData = try? JSONEncoder().encode(bounded.tombstones)
        defaults.set(watchedCachedData, forKey: watchedKey)
        defaults.set(unwatchedCachedData, forKey: unwatchedKey)
        if notify { ApplePlaybackProgressFeed.shared.storeDidChange() }
    }

    /// The newest `watchedHistoryLimit` entries; ties keep the lower key so
    /// the trim is stable.
    nonisolated static func boundedWatchedHistory(_ entries: [String: Date], limit: Int = watchedHistoryLimit) -> [String: Date] {
        guard entries.count > limit else { return entries }
        let newest = entries.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(limit)
        return Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
    }

    func configurationProgress() -> [String: ApplePlaybackProgress] { entries() }

    func configurationContinueWatchingRemovals() -> [String: Date] { continueWatchingRemovals() }

    /// Merges a backup's or another device's removals into this one: the
    /// newest removal per title wins.
    func restoreConfigurationContinueWatchingRemovals(_ incoming: [String: Date]) {
        guard !incoming.isEmpty else { return }
        var normalized: [String: Date] = [:]
        for (key, date) in incoming {
            guard let storageKey = ApplePlaybackIdentity.storageKey(for: key) else { continue }
            normalized[storageKey] = max(normalized[storageKey] ?? date, date)
        }
        let current = continueWatchingRemovals()
        let merged = AppleContinueWatchingRemovalPolicy.merged(current, normalized)
        guard merged != current else { return }
        persistRemovals(merged)
    }

    private func continueWatchingRemovals() -> [String: Date] {
        let storedData = defaults.data(forKey: continueWatchingRemovedKey)
        if let removedCache, removedCachedData == storedData { return removedCache }
        let decoded = storedData.flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) } ?? [:]
        removedCache = decoded
        removedCachedData = storedData
        return decoded
    }

    private func persistRemovals(_ removals: [String: Date], notify: Bool = true) {
        let bounded = Self.boundedWatchedHistory(removals, limit: Self.continueWatchingRemovalLimit)
        removedCache = bounded
        removedCachedData = bounded.isEmpty ? nil : try? JSONEncoder().encode(bounded)
        if let removedCachedData { defaults.set(removedCachedData, forKey: continueWatchingRemovedKey) }
        else { defaults.removeObject(forKey: continueWatchingRemovedKey) }
        if notify { ApplePlaybackProgressFeed.shared.storeDidChange() }
    }

    /// Merges a backup's or another device's resume positions into this one:
    /// per title the freshest `updatedAt` wins, so a snapshot written before
    /// this device's last play never winds it back (V6).
    func restoreConfigurationProgress(_ incoming: [String: ApplePlaybackProgress]) {
        persist(entries().merging(incoming) { mine, theirs in theirs.updatedAt >= mine.updatedAt ? theirs : mine })
    }

    /// Backups and iCloud always read and write the stored history, never a
    /// review build's in-memory fixture.
    func configurationWatchedHistory() -> [String: Date] { storedWatchedHistory().watched }

    func configurationWatchedTombstones() -> [String: Date] { storedWatchedHistory().tombstones }

    /// Merges a backup's or another device's watched history into this one:
    /// the newest event per title wins, including un-watch events.
    func restoreConfigurationWatchedHistory(_ incoming: [String: Date], tombstones: [String: Date] = [:]) {
        guard !incoming.isEmpty || !tombstones.isEmpty else { return }
        let current = storedWatchedHistory()
        var normalized = AppleWatchedHistory()
        for (key, date) in incoming {
            guard let storageKey = ApplePlaybackIdentity.storageKey(for: key) else { continue }
            normalized.merge(watched: [storageKey: date], tombstones: [:])
        }
        for (key, date) in tombstones {
            guard let storageKey = ApplePlaybackIdentity.storageKey(for: key) else { continue }
            normalized.merge(watched: [:], tombstones: [storageKey: date])
        }
        var merged = current
        merged.merge(watched: normalized.watched, tombstones: normalized.tombstones)
        guard merged.watched != current.watched || merged.tombstones != current.tombstones else { return }
        persistStoredWatched(merged, notify: true)
    }

    private func persist(_ entries: [String: ApplePlaybackProgress]) {
        cache = entries
        cachedData = try? JSONEncoder().encode(entries)
        defaults.set(cachedData, forKey: key)
        ApplePlaybackProgressFeed.shared.storeDidChange()
    }
}

/// Continue Watching's "Remove" rule: a removed title stays off the row
/// until it is played after the removal. Progress and history are untouched.
enum AppleContinueWatchingRemovalPolicy {
    static func isRemoved(removedAt: Date?, lastPlayedAt: Date?) -> Bool {
        guard let removedAt else { return false }
        return (lastPlayedAt ?? .distantPast) <= removedAt
    }

    /// The newest removal per title, from two devices or a backup.
    static func merged(_ current: [String: Date], _ incoming: [String: Date]) -> [String: Date] {
        current.merging(incoming) { max($0, $1) }
    }
}

#if DEBUG
/// Review builds only: `-OpenStreamDebugWatchedFixture 1:1,1:2` marks those
/// season:episode numbers watched on whichever show is open, so a simulator
/// with no history can photograph the ticks, the Up Next button and the
/// episode menu without playing anything. While it is on, the watched
/// history lives in memory — nothing is read from or written to the store,
/// backups or iCloud.
@MainActor
enum AppleWatchedHistoryFixture {
    static let launchKey = "OpenStreamDebugWatchedFixture"
    static var memory: [String: Date] = [:]
    /// Seeded episodes the viewer has since marked as unwatched.
    static var unwatched: Set<String> = []

    private static let seeds: Set<String> = Set(
        (UserDefaults.standard.string(forKey: launchKey) ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    )

    static var isEnabled: Bool { !seeds.isEmpty }

    static func isSeeded(mediaID: String, storageKey: String) -> Bool {
        guard isEnabled, !unwatched.contains(storageKey),
              let identity = AppleStremioMetadataClient.episodeIdentity(mediaID) else { return false }
        return seeds.contains("\(identity.season):\(identity.episode)")
    }
}
#endif
