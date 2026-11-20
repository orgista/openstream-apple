import Foundation

public struct ApplePlaybackProgress: Codable, Equatable, Sendable {
    public static let completionFraction = AppleCompletionPolicy.fraction
    public static let completionRemainingSeconds = AppleCompletionPolicy.remainingSeconds

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
        AppleCompletionPolicy.isComplete(position: position, duration: duration)
    }
}

/// Monotonic per-title barriers. Keep each kind independently: a later row
/// removal must not discard the completion/reset that blocks stale resumes.
public struct ApplePlaybackTerminalEvents: Codable, Equatable, Sendable {
    public var completedAt: Date?
    public var resetAt: Date?
    public var removedAt: Date?
    public var playedAt: Date?

    public init(completedAt: Date? = nil, resetAt: Date? = nil, removedAt: Date? = nil, playedAt: Date? = nil) {
        self.completedAt = completedAt
        self.resetAt = resetAt
        self.removedAt = removedAt
        self.playedAt = playedAt
    }

    var progressBarrier: Date? { [completedAt, resetAt].compactMap { $0 }.max() }

    func merging(_ other: Self) -> Self {
        Self(completedAt: [completedAt, other.completedAt].compactMap { $0 }.max(),
             resetAt: [resetAt, other.resetAt].compactMap { $0 }.max(),
             removedAt: [removedAt, other.removedAt].compactMap { $0 }.max(),
             playedAt: [playedAt, other.playedAt].compactMap { $0 }.max())
    }
}

/// Shared by local restore and cloud merge; equal clocks must yield the same
/// result regardless of device or restore order.
enum ApplePlaybackConvergence {
    static func freshest(_ a: ApplePlaybackProgress, _ b: ApplePlaybackProgress) -> ApplePlaybackProgress {
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt ? a : b }
        if a.isComplete != b.isComplete { return a.isComplete ? a : b }
        if a.position != b.position { return a.position > b.position ? a : b }
        if a.duration != b.duration { return a.duration > b.duration ? a : b }
        if a.partID == nil { return b.partID == nil ? a : b }
        if b.partID == nil { return a }
        return (a.partID ?? "") >= (b.partID ?? "") ? a : b
    }

    static func terminals(_ explicit: [String: ApplePlaybackTerminalEvents],
                          watched: [String: Date], unwatched: [String: Date],
                          removals: [String: Date], activity: [String: ApplePlaybackProgress]) -> [String: ApplePlaybackTerminalEvents] {
        var result = explicit
        func add(_ key: String, _ event: ApplePlaybackTerminalEvents) {
            result[key] = (result[key] ?? .init()).merging(event)
        }
        for (key, date) in watched { add(key, .init(completedAt: date)) }
        for (key, date) in unwatched { add(key, .init(resetAt: date)) }
        for (key, date) in removals { add(key, .init(removedAt: date)) }
        for (key, progress) in activity where progress.isComplete {
            let finished = progress.partID.flatMap(ApplePlaybackIdentity.storageKey(for:)) ?? key
            add(finished, .init(completedAt: progress.updatedAt))
        }
        // Retain every title's playback clock even when the ordinary cloud
        // resume/activity lists trim its offset.
        for (key, progress) in activity {
            add(key, .init(playedAt: progress.updatedAt))
            if let part = progress.partID.flatMap(ApplePlaybackIdentity.storageKey(for:)) {
                add(part, .init(playedAt: progress.updatedAt))
            }
        }
        return result
    }

    static func history(_ history: AppleWatchedHistory, terminals: [String: ApplePlaybackTerminalEvents]) -> AppleWatchedHistory {
        var result = history
        // Only upgrade known watched identities: show-level completion
        // barriers must not turn a finished episode into a watched show.
        for key in history.watched.keys {
            if let date = terminals[key]?.completedAt { result.merge(watched: [key: date], tombstones: [:]) }
        }
        result.merge(watched: [:], tombstones: terminals.compactMapValues(\.resetAt))
        return result
    }

    /// A legacy show-level completion has no episode identity. Only the
    /// finished part's barrier can retire an episodic resume.
    static func eventKeys(_ key: String, _ value: ApplePlaybackProgress) -> [String] {
        guard let partID = value.partID else { return [key] }
        return [partID, ApplePlaybackIdentity.storageKey(for: partID)].compactMap { $0 }
    }

    static func activityIsCurrent(key: String, value: ApplePlaybackProgress,
                                  terminals: [String: ApplePlaybackTerminalEvents]) -> Bool {
        let keys = eventKeys(key, value)
        if value.isComplete {
            let reset = ([key] + keys).compactMap { terminals[$0]?.resetAt }.max()
            if reset.map({ value.updatedAt <= $0 }) == true { return false }
        }
        let played = keys.compactMap { terminals[$0]?.playedAt }.max()
        return played.map { value.updatedAt >= $0 } ?? true
    }

    static func reconciled(_ progress: [String: ApplePlaybackProgress], terminals: [String: ApplePlaybackTerminalEvents]) -> [String: ApplePlaybackProgress] {
        progress.filter { key, value in
            let keys = eventKeys(key, value)
            let completion = keys.compactMap { terminals[$0]?.completedAt }.max()
            if completion.map({ value.updatedAt <= $0 }) == true { return false }
            return activityIsCurrent(key: key, value: value, terminals: terminals)
        }
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
    private let blobs: ApplePlaybackBlobStorage
    private let aliases: AppleIdentityAliasStore
    private let key: String

    /// Decoded copies of the stored maps, each kept with the bytes it came
    /// from. Shared by every store on the standard storage, so a view that
    /// makes a store per redraw no longer decodes everything again.
    private let decoded: DecodedState

    /// What has been finished, keyed like the progress map, valued by when.
    /// A finished title leaves the progress map (that is how it leaves
    /// Continue Watching), so without this nothing remembered it: no episode
    /// ever showed its tick and "next episode" always meant the first one.
    /// Watching a finished episode again does not take it off this list.
    private let watchedKey: String
    private let unwatchedKey: String
    /// The newest this many finished titles are kept.
    nonisolated public static let watchedHistoryLimit = 5_000
    /// Titles the viewer took off Continue Watching, and when. The progress
    /// stays; the row leaves the title out until it is played again.
    private let continueWatchingRemovedKey: String
    /// The newest this many removals are kept.
    nonisolated public static let continueWatchingRemovalLimit = 500

    public let namespace: String

    public init(defaults: UserDefaults = .standard, namespace: String = AppleTasteNamespace.local, blobDirectory: URL? = nil) {
        self.defaults = defaults
        blobs = ApplePlaybackBlobStorage.storage(defaults: defaults, directory: blobDirectory)
        aliases = AppleIdentityAliasStore(defaults: defaults, namespace: namespace, blobDirectory: blobDirectory)
        self.namespace = namespace
        decoded = blobDirectory == nil && defaults === UserDefaults.standard ? .shared(namespace: namespace) : DecodedState()
        key = AppleTasteNamespace.key("openstream.playback.progress.v1", namespace: namespace)
        watchedKey = AppleTasteNamespace.key("openstream.playback.watched.v1", namespace: namespace)
        unwatchedKey = AppleTasteNamespace.key("openstream.playback.unwatched.v1", namespace: namespace)
        continueWatchingRemovedKey = AppleTasteNamespace.key("openstream.playback.continueWatchingRemoved.v1", namespace: namespace)
        terminalKey = AppleTasteNamespace.key("openstream.playback.terminals.v1", namespace: namespace)
        activityKey = AppleTasteNamespace.key("openstream.playback.activity.v1", namespace: namespace)
        episodesKey = AppleTasteNamespace.key("openstream.playback.availableEpisodes.v1", namespace: namespace)
        migrateLegacyPlaybackStateIfNeeded()
    }

    private let terminalKey: String

    private let activityKey: String
    private let episodesKey: String

    private func rawActivities() -> [String: ApplePlaybackProgress] {
        let data = blobs.data(forKey: activityKey)
        if let activityCache = decoded.activityCache, data == decoded.activityData { return activityCache }
        let values = data.flatMap { try? JSONDecoder().decode([String: ApplePlaybackProgress].self, from: $0) } ?? [:]
        decoded.activityData = data
        decoded.activityCache = values
        return values
    }

    func activities() -> [String: ApplePlaybackProgress] {
        let fingerprint = derivedStateFingerprint()
        if let filteredActivityCache = decoded.filteredActivityCache, decoded.filteredActivityFingerprint == fingerprint { return filteredActivityCache }
        let terminals = configurationPlaybackTerminals()
        let values = rawActivities().filter { key, value in
            ApplePlaybackConvergence.activityIsCurrent(key: key, value: value, terminals: terminals)
        }
        decoded.filteredActivityCache = values
        decoded.filteredActivityFingerprint = derivedStateFingerprint()
        return values
    }

    public func lastActivity(for mediaID: String) -> ApplePlaybackProgress? {
        guard let key = ApplePlaybackIdentity.storageKey(for: mediaID) else { return nil }
        // The terminals cache is rebuilt at most once per stored change.
        return ApplePlaybackReadState.lastActivity(key: key, keys: classKeys(key), entries: entries(),
            activities: activities(), terminals: configurationPlaybackTerminals())
    }

    /// The maps the per-title reads use, as they stand now.
    func readState() -> ApplePlaybackReadState {
        ApplePlaybackReadState(entries: entries(), activities: activities(),
            terminals: configurationPlaybackTerminals(), aliases: aliases.index())
    }

    func availableEpisodes() async -> [String: [AppleMediaEpisode]] {
        await Self.decodeEpisodes(blobs.data(forKey: episodesKey))
    }

    @concurrent nonisolated private static func decodeEpisodes(_ data: Data?) async -> [String: [AppleMediaEpisode]] {
        data.flatMap { try? JSONDecoder().decode([String: [AppleMediaEpisode]].self, from: $0) } ?? [:]
    }

    @concurrent nonisolated private static func updatedEpisodes(_ data: Data?, episodes: [AppleMediaEpisode], key: String, activity: [String: ApplePlaybackProgress]) async -> Data? {
        var values = await decodeEpisodes(data)
        values[key] = episodes.map { AppleMediaEpisode(id: $0.id, title: "", season: $0.season,
            episode: $0.episode, releaseInfo: $0.releaseInfo.map { String($0.prefix(64)) }) }
        // Availability is rebuildable metadata, not playback history. Keep the
        // current title plus the 199 most recently active shows. Preserve full ISO
        // release timestamps so trimming never advances a future episode's release.
        let active = activity.keys.filter { $0 != key }.sorted {
            let a = activity[$0]?.updatedAt ?? .distantPast
            let b = activity[$1]?.updatedAt ?? .distantPast
            return a == b ? $0 < $1 : a > b
        }
        let retained = Set([key] + active.prefix(199))
        values = values.filter { retained.contains($0.key) }
        return try? JSONEncoder().encode(values)
    }

    func recordEpisodes(_ episodes: [AppleMediaEpisode], mediaID: String) async {
        guard let key = ApplePlaybackIdentity.storageKey(for: mediaID) else { return }
        // Retry if another title arrived while encoding off the main actor.
        while !Task.isCancelled {
            let previous = blobs.data(forKey: episodesKey)
            let data = await Self.updatedEpisodes(previous, episodes: episodes, key: key, activity: activities())
            guard previous == blobs.data(forKey: episodesKey) else { continue }
            if data != previous {
                blobs.set(data, forKey: episodesKey)
                ApplePlaybackProgressFeed.shared.storeDidChange()
            }
            return
        }
    }

    /// Saved entries for library adapters; avoids scanning every provider title on each save.
    func savedProgress() -> [String: ApplePlaybackProgress] { entries() }

    public func progress(for mediaID: String) -> ApplePlaybackProgress? {
        guard let storageKey = ApplePlaybackIdentity.storageKey(for: mediaID) else { return nil }
        let keys = classKeys(storageKey)
        return ApplePlaybackReadState.progress(keys: keys, entries: entries(),
            terminals: keys.count > 1 ? configurationPlaybackTerminals() : [:])
    }

    /// The finished titles among `mediaIDs`, from one read of the watched
    /// history: callers that check a whole episode list during a redraw stay
    /// O(1) reads. A progress entry that is itself complete (one restored
    /// from an older backup) counts too.
    func completionProgress() -> [String: ApplePlaybackProgress] {
        entries().merging(activities().filter { key, value in
            value.partID == nil || value.partID.flatMap(ApplePlaybackIdentity.storageKey(for:)) == key
        }, uniquingKeysWith: ApplePlaybackConvergence.freshest)
    }

    public func completedMediaIDs(among mediaIDs: [String]) -> Set<String> {
        guard !mediaIDs.isEmpty else { return [] }
        return completedMediaIDs(among: mediaIDs, progress: completionProgress())
    }

    func completedMediaIDs(among mediaIDs: [String], progress all: [String: ApplePlaybackProgress]) -> Set<String> {
        guard !mediaIDs.isEmpty else { return [] }
        let watched = watchedEntries()
        let tombstones = storedWatchedTombstones()
        let terminals = configurationPlaybackTerminals()
        return Set(mediaIDs.filter { mediaID in
            guard let storageKey = ApplePlaybackIdentity.storageKey(for: mediaID) else { return false }
            #if DEBUG
            if AppleWatchedHistoryFixture.isSeeded(mediaID: mediaID, storageKey: storageKey) { return true }
            #endif
            let keys = classKeys(storageKey)
            if keys.count == 1, tombstones[storageKey] != nil { return false }
            let history = AppleIdentityAliasResolution.history(keys: keys, watched: watched, tombstones: tombstones)
            if history.tombstone != nil { return false }
            if let reset = AppleIdentityAliasResolution.terminals(keys: keys, in: terminals)?.resetAt {
                let completion = ([history.watched] + keys.map { all[$0].flatMap { $0.isComplete ? $0.updatedAt : nil } })
                    .compactMap { $0 }.max()
                if completion.map({ $0 <= reset }) ?? true { return false }
            }
            return history.watched != nil || keys.contains { all[$0]?.isComplete == true }
        })
    }

    public func isWatched(mediaID: String) -> Bool {
        !completedMediaIDs(among: [mediaID]).isEmpty
    }

    /// "Mark as Watched": records `mediaID` as finished now.
    public func markWatched(mediaID: String, at date: Date? = nil) {
        guard let storageKey = ApplePlaybackIdentity.storageKey(for: mediaID) else { return }
        let date = date ?? nextLocalEventDate(storageKey: storageKey)
        var history = AppleWatchedHistory(watched: watchedEntries(), tombstones: storedWatchedTombstones())
        history.merge(watched: [storageKey: date], tombstones: [:])
        #if DEBUG
        AppleWatchedHistoryFixture.unwatched.remove(storageKey)
        #endif
        recordTerminal(storageKey, .init(completedAt: date))
        persistWatched(history.watched, tombstones: history.tombstones)
        reconcileStoredProgress()
        NotificationCenter.default.post(name: ApplePlaybackProgressFeed.continueWatchingChangeNotification, object: nil)
    }

    /// "Mark as Unwatched": removes watched state and completed activity.
    /// An unfinished rewatch keeps its resume position.
    public func markUnwatched(mediaID: String, at date: Date? = nil) {
        guard let storageKey = ApplePlaybackIdentity.storageKey(for: mediaID) else { return }
        let date = date ?? nextLocalEventDate(storageKey: storageKey)
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
        recordTerminal(storageKey, .init(resetAt: date))
        persistWatched(history.watched, tombstones: history.tombstones)
        reconcileStoredProgress()
        var progress = entries()
        if progress[storageKey]?.isComplete == true {
            progress.removeValue(forKey: storageKey)
            persist(progress)
        }
    }

    /// "Remove from Continue Watching": leaves the progress and the watched
    /// history alone, and hides the title from the row until it is played
    /// again (a later progress save).
    public func removeFromContinueWatching(mediaID: String, at date: Date? = nil) {
        guard let storageKey = ApplePlaybackIdentity.storageKey(for: mediaID) else { return }
        let date = date ?? nextLocalEventDate(storageKey: storageKey)
        recordTerminal(storageKey, .init(removedAt: date))
        var removed = continueWatchingRemovals()
        removed[storageKey] = max(removed[storageKey] ?? .distantPast, date)
        persistRemovals(removed)
        NotificationCenter.default.post(name: ApplePlaybackProgressFeed.continueWatchingChangeNotification, object: nil)
    }

    /// Whether the viewer took `mediaID` off Continue Watching and has not
    /// played it since.
    public func isRemovedFromContinueWatching(mediaID: String) -> Bool {
        guard let storageKey = ApplePlaybackIdentity.storageKey(for: mediaID) else { return false }
        return ApplePlaybackReadState.isRemoved(keys: classKeys(storageKey), entries: entries(),
            activities: activities(), terminals: configurationPlaybackTerminals())
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

    /// One file's own position, outside its alias class: a stack part played
    /// without a measured timeline must not read the title's cumulative position.
    func fileProgress(for mediaID: String) -> ApplePlaybackProgress? {
        ApplePlaybackIdentity.storageKey(for: mediaID).flatMap { entries()[$0] }
    }

    private var versionProgressKey: String { AppleTasteNamespace.key("openstream.playback.versionProgress.v1", namespace: namespace) }
    private var preferredVersionKey: String { AppleTasteNamespace.key("openstream.playback.preferredVersion.v1", namespace: namespace) }

    private func versionEntries() -> [String: [String: ApplePlaybackProgress]] {
        let data = blobs.data(forKey: versionProgressKey)
        if let versionCache = decoded.versionCache, data == decoded.versionData { return versionCache }
        let values = data.flatMap { try? JSONDecoder().decode([String: [String: ApplePlaybackProgress]].self, from: $0) } ?? [:]
        decoded.versionData = data
        decoded.versionCache = values
        return values
    }

    private func persistVersionEntries(_ values: [String: [String: ApplePlaybackProgress]]) {
        decoded.versionCache = values
        decoded.versionData = try? JSONEncoder().encode(values)
        blobs.set(decoded.versionData, forKey: versionProgressKey)
    }

    public func versionProgress(itemID: String, versionID: String) -> ApplePlaybackProgress? {
        guard let key = ApplePlaybackIdentity.storageKey(for: itemID) else { return nil }
        guard let progress = versionEntries()[key]?[versionID] else { return nil }
        let terminal = AppleIdentityAliasResolution.terminals(keys: classKeys(key), in: configurationPlaybackTerminals())
        if !progress.isComplete, let completion = terminal?.completedAt, completion >= (terminal?.resetAt ?? .distantPast), progress.updatedAt <= completion { return nil }
        if progress.isComplete, let reset = terminal?.resetAt, progress.updatedAt <= reset { return nil }
        return progress
    }

    /// Read raw Stage-A keys before joining their alias classes. Never rewrite or delete them.
    public func migrateVersionProgress(itemID: String, versions: [String: [String]], timelines: [String: AppleMediaVersion] = [:], recordAliases: Bool = true) {
        guard let itemKey = ApplePlaybackIdentity.storageKey(for: itemID) else { return }
        var scopes = versionEntries()
        let raw = entries().merging(rawActivities(), uniquingKeysWith: ApplePlaybackConvergence.freshest)
        var item = raw[itemKey]
        for (versionID, legacyIDs) in versions {
            let timeline = timelines[versionID]
            let candidates = legacyIDs.enumerated().compactMap { index, legacyID -> ApplePlaybackProgress? in
                guard let key = ApplePlaybackIdentity.storageKey(for: legacyID), let old = raw[key] else { return nil }
                guard let timeline, timeline.parts.count > 1 else { return old }
                guard index < timeline.parts.count, let duration = timeline.duration,
                      let position = timeline.cumulativePosition(ordinal: timeline.parts[index].ordinal, offset: old.position) else { return nil }
                return ApplePlaybackProgress(position: position, duration: duration, updatedAt: old.updatedAt, partID: old.partID)
            }
            if let old = candidates.reduce(nil as ApplePlaybackProgress?, { result, value in
                result.map { ApplePlaybackConvergence.freshest($0, value) } ?? value
            }) {
                let existing = scopes[itemKey]?[versionID]
                scopes[itemKey, default: [:]][versionID] = existing.map { ApplePlaybackConvergence.freshest($0, old) } ?? old
            }
            if let value = scopes[itemKey]?[versionID] {
                item = item.map { ApplePlaybackConvergence.freshest($0, value) } ?? value
            }
        }
        if scopes != versionEntries() { persistVersionEntries(scopes) }
        if let item, !item.isComplete, entries()[itemKey] != item {
            var values = entries()
            values[itemKey] = item
            persist(values)
        }
        // A lone file is its own item: there is nothing to join.
        let members = Set([itemID] + versions.values.flatMap { $0 }.filter { !$0.isEmpty })
        if recordAliases, members.count > 1 { recordIdentityAlias(classID: itemID, mediaIDs: Array(members).sorted()) }
    }

    public func save(request: ApplePlaybackRequest, position: Double, duration: Double) {
        let partID = request.hints.progressPartID ?? AppleDetailResume.partID(type: request.hints.titleMediaType, mediaID: request.hints.titleMediaID)
        if let version = request.hints.versionID {
            saveVersion(itemID: request.mediaID, versionID: version,
                position: request.hints.versionOffset + position,
                duration: request.hints.versionDuration ?? duration, partID: partID)
        } else {
            save(mediaID: request.mediaID, position: position, duration: duration, partID: partID)
        }
        if let parent = request.hints.progressParentID {
            save(mediaID: parent, position: position, duration: duration, partID: partID)
        }
    }

    public func saveVersion(itemID: String, versionID: String, position: Double, duration: Double, partID: String? = nil) {
        guard let key = ApplePlaybackIdentity.storageKey(for: itemID), position.isFinite, position >= 0,
              duration.isFinite, duration > 0 else { return }
        save(mediaID: itemID, position: position, duration: duration, partID: partID)
        // Completion removes ordinary resume state, but the version retains its own timeline.
        guard let value = rawActivities()[key] else { return }
        var scopes = versionEntries()
        scopes[key, default: [:]][versionID] = value
        persistVersionEntries(scopes)
    }

    /// The last played version of an item (owner rule 2026-10-15), stored in
    /// `preferredVersion.v1`: written when a version really starts playing.
    public func preferVersion(_ versionID: String, itemID: String) {
        guard let key = ApplePlaybackIdentity.storageKey(for: itemID) else { return }
        var values = preferredVersions()
        guard values[key] != versionID else { return }
        values[key] = versionID
        blobs.set(try? JSONEncoder().encode(values), forKey: preferredVersionKey)
    }

    /// First frame of a versioned request: that copy becomes the resume copy.
    public func notePlaybackStarted(_ request: ApplePlaybackRequest) {
        guard let versionID = request.hints.versionID else { return }
        preferVersion(versionID, itemID: request.mediaID)
    }

    private func preferredVersions() -> [String: String] {
        blobs.data(forKey: preferredVersionKey).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    /// The recorded last played version, even while its file is unavailable
    /// (an unmounted share must not erase it); callers fall back per play.
    public func preferredVersion(itemID: String) -> String? {
        ApplePlaybackIdentity.storageKey(for: itemID).flatMap { preferredVersions()[$0] }
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
        var terminals = configurationPlaybackTerminals()
        let partKey = partID.flatMap(ApplePlaybackIdentity.storageKey(for:))
        let clockKeys = classKeys(storageKey) + (partKey.map { classKeys($0) } ?? [])
        let clocks = clockKeys.compactMap { terminals[$0] }
            .flatMap { [$0.playedAt, $0.completedAt, $0.resetAt, $0.removedAt].compactMap { $0 } }
        let previous = (clocks + [current[storageKey]?.updatedAt].compactMap { $0 }).max()
        let updatedAt = max(Date.now, previous?.addingTimeInterval(1) ?? .distantPast)
        let progress = ApplePlaybackProgress(position: min(position, duration), duration: duration,
            updatedAt: updatedAt, partID: partID)
        var activity = activities()
        activity[storageKey] = progress
        if activity.count > Self.watchedHistoryLimit {
            terminals = ApplePlaybackConvergence.terminals(terminals, watched: [:], unwatched: [:],
                removals: [:], activity: activity)
            activity = Dictionary(uniqueKeysWithValues: activity.sorted { $0.value.updatedAt == $1.value.updatedAt ? $0.key < $1.key : $0.value.updatedAt > $1.value.updatedAt }
                .prefix(Self.watchedHistoryLimit).map { ($0.key, $0.value) })
        }
        decoded.activityCache = activity
        decoded.activityData = try? JSONEncoder().encode(activity)
        blobs.set(decoded.activityData, forKey: activityKey)
        terminals[storageKey] = (terminals[storageKey] ?? .init()).merging(.init(playedAt: progress.updatedAt))
        let finishedKey = partKey ?? storageKey
        terminals[finishedKey] = (terminals[finishedKey] ?? .init()).merging(.init(
            completedAt: progress.isComplete ? progress.updatedAt : nil, playedAt: progress.updatedAt))
        persistTerminals(terminals)
        if progress.isComplete {
            current.removeValue(forKey: storageKey)
            // A series keeps its entry under the show and names the episode
            // in `partID`; the episode is what was finished, not the show.
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
        // This save already materialized its new clocks before writing progress.
        decoded.terminalsFingerprint = derivedStateFingerprint()
    }

    private func clear(storageKey: String) {
        let previous = configurationPlaybackTerminals()[storageKey]?.playedAt
        let date = max(Date.now, previous?.addingTimeInterval(1) ?? .distantPast)
        if let part = entries()[storageKey]?.partID.flatMap(ApplePlaybackIdentity.storageKey(for:)) {
            recordTerminal(part, .init(resetAt: date, playedAt: date))
        }
        recordTerminal(storageKey, .init(resetAt: date, playedAt: date))
        var activity = activities()
        activity.removeValue(forKey: storageKey)
        decoded.activityCache = activity
        decoded.activityData = try? JSONEncoder().encode(activity)
        blobs.set(decoded.activityData, forKey: activityKey)
        var current = entries()
        current.removeValue(forKey: storageKey)
        persist(current)
    }

    private func entries() -> [String: ApplePlaybackProgress] {
        // One read of the stored blob: it is compared, decoded and kept from
        // the same value (it was read three times on a miss, N47).
        let storedData = blobs.data(forKey: key)
        if let cache = decoded.cache, decoded.cachedData == storedData { return cache }
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
                blobs.set(rewritten, forKey: key)
                keptData = rewritten
            }
        } else {
            loaded = [:]
        }
        decoded.cache = loaded
        decoded.cachedData = keptData
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
        let storedData = blobs.data(forKey: watchedKey)
        if let watchedCache = decoded.watchedCache, decoded.watchedCachedData == storedData { return watchedCache }
        let values = storedData.flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) } ?? [:]
        decoded.watchedCache = values
        decoded.watchedCachedData = storedData
        return values
    }

    private func storedWatchedTombstones() -> [String: Date] {
        let storedData = blobs.data(forKey: unwatchedKey)
        if let unwatchedCache = decoded.unwatchedCache, decoded.unwatchedCachedData == storedData { return unwatchedCache }
        let values = storedData.flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) } ?? [:]
        decoded.unwatchedCache = values
        decoded.unwatchedCachedData = storedData
        return values
    }

    private func storedWatchedHistory() -> AppleWatchedHistory {
        AppleWatchedHistory(watched: storedWatchedEntries(), tombstones: storedWatchedTombstones())
    }

    private func persistStoredWatched(_ history: AppleWatchedHistory, notify: Bool) {
        let barriers = ApplePlaybackConvergence.terminals(configurationPlaybackTerminals(), watched: history.watched,
            unwatched: history.tombstones, removals: [:], activity: [:])
        persistTerminals(barriers)
        let bounded = ApplePlaybackConvergence.history(history, terminals: barriers).newest(Self.watchedHistoryLimit)
        decoded.watchedCache = bounded.watched
        decoded.watchedCachedData = try? JSONEncoder().encode(bounded.watched)
        decoded.unwatchedCache = bounded.tombstones
        decoded.unwatchedCachedData = try? JSONEncoder().encode(bounded.tombstones)
        blobs.set(decoded.watchedCachedData, forKey: watchedKey)
        blobs.set(decoded.unwatchedCachedData, forKey: unwatchedKey)
        decoded.terminalsFingerprint = derivedStateFingerprint()
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

    func configurationContinueWatchingRemovals() -> [String: Date] {
        configurationPlaybackTerminals().compactMapValues { event in
            guard let removed = event.removedAt,
                  AppleContinueWatchingRemovalPolicy.isRemoved(removedAt: removed, lastPlayedAt: event.playedAt) else { return nil }
            return removed
        }
    }

    /// Merges a backup's or another device's removals into this one: the
    /// newest removal per title wins.
    func restoreConfigurationContinueWatchingRemovals(_ incoming: [String: Date]) {
        guard !incoming.isEmpty else { return }
        var normalized: [String: Date] = [:]
        for (key, date) in incoming {
            guard let storageKey = ApplePlaybackIdentity.storageKey(for: key) else { continue }
            normalized[storageKey] = max(normalized[storageKey] ?? date, date)
        }
        restoreConfigurationPlaybackTerminals(ApplePlaybackConvergence.terminals([:], watched: [:], unwatched: [:],
            removals: normalized, activity: [:]))
        let current = continueWatchingRemovals()
        let merged = AppleContinueWatchingRemovalPolicy.merged(current, normalized)
        guard merged != current else { return }
        persistRemovals(merged)
    }

    private func continueWatchingRemovals() -> [String: Date] {
        let storedData = blobs.data(forKey: continueWatchingRemovedKey)
        if let removedCache = decoded.removedCache, decoded.removedCachedData == storedData { return removedCache }
        let values = storedData.flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) } ?? [:]
        decoded.removedCache = values
        decoded.removedCachedData = storedData
        return values
    }

    private func persistRemovals(_ removals: [String: Date], notify: Bool = true) {
        let terminals = ApplePlaybackConvergence.terminals(configurationPlaybackTerminals(), watched: [:], unwatched: [:],
            removals: removals, activity: [:])
        persistTerminals(terminals)
        let bounded = Self.boundedWatchedHistory(removals, limit: Self.continueWatchingRemovalLimit)
        decoded.removedCache = bounded
        decoded.removedCachedData = bounded.isEmpty ? nil : try? JSONEncoder().encode(bounded)
        if let removedCachedData = decoded.removedCachedData { blobs.set(removedCachedData, forKey: continueWatchingRemovedKey) }
        else { blobs.removeObject(forKey: continueWatchingRemovedKey) }
        decoded.terminalsFingerprint = derivedStateFingerprint()
        if notify { ApplePlaybackProgressFeed.shared.storeDidChange() }
    }

    /// Merges a backup's or another device's resume positions into this one:
    /// per title the freshest `updatedAt` wins, so a snapshot written before
    /// this device's last play never winds it back (V6).
    func restoreConfigurationProgress(_ incoming: [String: ApplePlaybackProgress]) {
        var normalized: [String: ApplePlaybackProgress] = [:]
        for (key, value) in incoming {
            guard let storageKey = ApplePlaybackIdentity.storageKey(for: key) else { continue }
            normalized[storageKey] = normalized[storageKey].map { ApplePlaybackConvergence.freshest($0, value) } ?? value
        }
        // Preserve complete legacy entries as activity before their resume is removed.
        let completions = normalized.filter { $0.value.isComplete }
        restoreConfigurationPlaybackActivity(completions)
        var watched: [String: Date] = [:]
        for (key, value) in completions {
            let finished = value.partID.flatMap(ApplePlaybackIdentity.storageKey(for:)) ?? key
            watched[finished] = max(watched[finished] ?? .distantPast, value.updatedAt)
        }
        restoreConfigurationWatchedHistory(watched)
        persist(ApplePlaybackConvergence.reconciled(entries().merging(normalized, uniquingKeysWith: ApplePlaybackConvergence.freshest),
            terminals: configurationPlaybackTerminals()))
    }

    /// Backups and iCloud always read and write the stored history, never a
    /// review build's in-memory fixture.
    func configurationWatchedHistory() -> [String: Date] {
        let history = storedWatchedHistory()
        return ApplePlaybackConvergence.history(history, terminals: configurationPlaybackTerminals()).watched
    }

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
        restoreConfigurationPlaybackTerminals(ApplePlaybackConvergence.terminals([:], watched: normalized.watched,
            unwatched: normalized.tombstones, removals: [:], activity: [:]))
        guard merged.watched != current.watched || merged.tombstones != current.tombstones else { return }
        persistStoredWatched(merged, notify: true)
    }

    /// The additive terminal key is also the migration marker. Preserve a
    /// legacy completed episode's part/activity before reconciling its resume,
    /// and do this once so constructing stores during rendering stays cheap.
    private func migrateLegacyPlaybackStateIfNeeded() {
        guard blobs.data(forKey: terminalKey) == nil else { return }
        let progress = entries()
        var activity: [String: ApplePlaybackProgress] = [:]
        for (key, value) in rawActivities() {
            guard let key = ApplePlaybackIdentity.storageKey(for: key) else { continue }
            activity[key] = activity[key].map { ApplePlaybackConvergence.freshest($0, value) } ?? value
        }
        func dates(_ values: [String: Date]) -> [String: Date] {
            var normalized: [String: Date] = [:]
            for (key, date) in values {
                guard let key = ApplePlaybackIdentity.storageKey(for: key) else { continue }
                normalized[key] = max(normalized[key] ?? .distantPast, date)
            }
            return normalized
        }
        var history = AppleWatchedHistory(watched: dates(storedWatchedEntries()), tombstones: dates(storedWatchedTombstones()))
        for (key, value) in progress where value.isComplete {
            activity[key] = activity[key].map { ApplePlaybackConvergence.freshest($0, value) } ?? value
            let finished = value.partID.flatMap(ApplePlaybackIdentity.storageKey(for:)) ?? key
            history.merge(watched: [finished: value.updatedAt], tombstones: [:])
        }
        let terminals = ApplePlaybackConvergence.terminals([:], watched: history.watched, unwatched: history.tombstones,
            removals: dates(continueWatchingRemovals()), activity: activity.merging(progress, uniquingKeysWith: ApplePlaybackConvergence.freshest))
        blobs.set(try? JSONEncoder().encode(terminals), forKey: terminalKey)
        // Fresh installs need only the marker; leave absent legacy blobs absent.
        guard !progress.isEmpty || !activity.isEmpty || !history.watched.isEmpty || !history.tombstones.isEmpty else { return }
        decoded.activityCache = activity
        decoded.activityData = try? JSONEncoder().encode(activity)
        blobs.set(decoded.activityData, forKey: activityKey)
        persistStoredWatched(history, notify: false)
        let reconciled = ApplePlaybackConvergence.reconciled(progress, terminals: terminals)
        decoded.cache = reconciled
        decoded.cachedData = try? JSONEncoder().encode(reconciled)
        blobs.set(decoded.cachedData, forKey: key)
    }

    func configurationPlaybackActivity() -> [String: ApplePlaybackProgress] { activities() }

    func configurationPlaybackTerminals() -> [String: ApplePlaybackTerminalEvents] {
        // Rebuilding this decodes and merges every stored map; per-title
        // callers (Top Shelf, Continue Watching) ran it several times per
        // record and pinned the CPU on large libraries (e2e 2026-10-12).
        let fingerprint = derivedStateFingerprint()
        if let terminalsCache = decoded.terminalsCache, decoded.terminalsFingerprint == fingerprint { return terminalsCache }
        let explicit = blobs.data(forKey: terminalKey).flatMap {
            try? JSONDecoder().decode([String: ApplePlaybackTerminalEvents].self, from: $0)
        } ?? [:]
        let values = ApplePlaybackConvergence.terminals(explicit, watched: storedWatchedEntries(),
            unwatched: storedWatchedTombstones(), removals: continueWatchingRemovals(),
            activity: rawActivities().merging(entries(), uniquingKeysWith: ApplePlaybackConvergence.freshest))
        // `entries()` may normalize and rewrite its blob, so fingerprint after.
        decoded.terminalsCache = values
        decoded.terminalsFingerprint = derivedStateFingerprint()
        return values
    }

    private func classKeys(_ storageKey: String) -> [String] { aliases.members(of: storageKey) }

    func canReadLegacyEpisodeAlias(current: String, legacy: String) -> Bool {
        guard let currentKey = ApplePlaybackIdentity.storageKey(for: current),
              let legacyKey = ApplePlaybackIdentity.storageKey(for: legacy) else { return false }
        let keys = classKeys(legacyKey)
        return keys.count == 1 || keys.contains(currentKey)
    }

    func recordIdentityAlias(classID: String, mediaIDs: [String]) {
        recordIdentityAliases([(classID: classID, mediaIDs: mediaIDs)])
    }

    func recordIdentityAliases(_ entries: [(classID: String, mediaIDs: [String])]) {
        aliases.record(entries.map { entry in
            (classID: entry.classID, members: entry.mediaIDs.compactMap { ApplePlaybackIdentity.storageKey(for: $0) })
        })
    }

    /// Changes whenever a stored blob every derived map is built from may
    /// have. Comparing the blobs themselves was most of a Top Shelf publish
    /// on an Apple TV 4K (copying and comparing seven maps per query, 2026-10-16).
    private func derivedStateFingerprint() -> [Int] {
        [blobs.revision, aliases.storageRevision]
    }

    func hasLocalPlaybackState(mediaID: String) -> Bool {
        guard let key = ApplePlaybackIdentity.storageKey(for: mediaID) else { return false }
        let progress = entries()
        let activity = activities()
        let terminals = configurationPlaybackTerminals()
        return classKeys(key).contains { progress[$0] != nil || activity[$0] != nil || terminals[$0] != nil }
    }

    private func recordTerminal(_ key: String, _ event: ApplePlaybackTerminalEvents) {
        var values = configurationPlaybackTerminals()
        values[key] = (values[key] ?? .init()).merging(event)
        persistTerminals(values)
    }

    private func persistTerminals(_ values: [String: ApplePlaybackTerminalEvents]) {
        guard let data = try? JSONEncoder().encode(values) else { return }
        blobs.set(data, forKey: terminalKey)
        decoded.terminalsCache = values
        decoded.terminalsFingerprint = derivedStateFingerprint()
    }

    /// Local user actions must follow a playback stamp advanced to survive
    /// another device's clock skew. Explicit imported/test dates stay exact.
    private func nextLocalEventDate(storageKey: String) -> Date {
        max(Date.now, localPlaybackUpdatedAt(mediaID: storageKey)?.addingTimeInterval(1) ?? .distantPast)
    }

    func localPlaybackUpdatedAt(mediaID: String) -> Date? {
        guard let key = ApplePlaybackIdentity.storageKey(for: mediaID) else { return nil }
        let keys = classKeys(key)
        let event = AppleIdentityAliasResolution.terminals(keys: keys, in: configurationPlaybackTerminals())
        let progress = entries()
        let activity = activities()
        return (keys.flatMap { [progress[$0]?.updatedAt, activity[$0]?.updatedAt] } + [event?.playedAt,
            event?.completedAt, event?.resetAt, event?.removedAt]).compactMap { $0 }.max()
    }

    func restoreConfigurationPlaybackTerminals(_ incoming: [String: ApplePlaybackTerminalEvents]) {
        var values = configurationPlaybackTerminals()
        for (key, event) in incoming {
            guard let key = ApplePlaybackIdentity.storageKey(for: key) else { continue }
            values[key] = (values[key] ?? .init()).merging(event)
        }
        persistTerminals(values)
        reconcileStoredProgress()
    }

    func restoreConfigurationPlaybackActivity(_ incoming: [String: ApplePlaybackProgress]) {
        var values = activities()
        for (key, value) in incoming {
            guard let key = ApplePlaybackIdentity.storageKey(for: key) else { continue }
            values[key] = values[key].map { ApplePlaybackConvergence.freshest($0, value) } ?? value
        }
        // Materialize barriers before activity's ordinary size limit can retire them.
        restoreConfigurationPlaybackTerminals(ApplePlaybackConvergence.terminals([:], watched: [:], unwatched: [:], removals: [:], activity: values))
        values = Dictionary(uniqueKeysWithValues: values.sorted {
            $0.value.updatedAt == $1.value.updatedAt ? $0.key < $1.key : $0.value.updatedAt > $1.value.updatedAt
        }.prefix(Self.watchedHistoryLimit).map { ($0.key, $0.value) })
        decoded.activityCache = values
        decoded.activityData = try? JSONEncoder().encode(values)
        blobs.set(decoded.activityData, forKey: activityKey)
    }

    private func reconcileStoredProgress() {
        let current = entries()
        let reconciled = ApplePlaybackConvergence.reconciled(current, terminals: configurationPlaybackTerminals())
        if current != reconciled { persist(reconciled) }
    }

    private func persist(_ entries: [String: ApplePlaybackProgress]) {
        decoded.cache = entries
        decoded.cachedData = try? JSONEncoder().encode(entries)
        blobs.set(decoded.cachedData, forKey: key)
        ApplePlaybackProgressFeed.shared.storeDidChange()
    }

    /// Every cache is checked against the stored bytes before use, so one copy
    /// can serve any number of stores on the same storage.
    @MainActor final class DecodedState {
        private static var byNamespace: [String: DecodedState] = [:]

        static func shared(namespace: String) -> DecodedState {
            if let state = byNamespace[namespace] { return state }
            let state = DecodedState()
            byNamespace[namespace] = state
            return state
        }

        /// The progress map. The storage stays the backing store (write-through);
        /// reads and per-tick saves do not decode and re-encode the dictionary.
        var cache: [String: ApplePlaybackProgress]?
        var cachedData: Data?
        var watchedCache: [String: Date]?
        var watchedCachedData: Data?
        var unwatchedCache: [String: Date]?
        var unwatchedCachedData: Data?
        var removedCache: [String: Date]?
        var removedCachedData: Data?
        var activityData: Data?
        var activityCache: [String: ApplePlaybackProgress]?
        var versionData: Data?
        var versionCache: [String: [String: ApplePlaybackProgress]]?
        var terminalsCache: [String: ApplePlaybackTerminalEvents]?
        var terminalsFingerprint: [Int]?
        var filteredActivityCache: [String: ApplePlaybackProgress]?
        var filteredActivityFingerprint: [Int]?
    }
}

/// A copy of the playback maps for reading many titles off the main actor
/// (the Top Shelf reads every record in the index). The store's own
/// per-title reads use the same rules below.
struct ApplePlaybackReadState: Sendable {
    let entries: [String: ApplePlaybackProgress]
    let activities: [String: ApplePlaybackProgress]
    let terminals: [String: ApplePlaybackTerminalEvents]
    let aliases: AppleIdentityAliasIndex

    func progress(for mediaID: String) -> ApplePlaybackProgress? {
        guard let key = ApplePlaybackIdentity.storageKey(for: mediaID) else { return nil }
        return Self.progress(keys: aliases.members(of: key), entries: entries, terminals: terminals)
    }

    func lastActivity(for mediaID: String) -> ApplePlaybackProgress? {
        guard let key = ApplePlaybackIdentity.storageKey(for: mediaID) else { return nil }
        return Self.lastActivity(key: key, keys: aliases.members(of: key), entries: entries,
                                 activities: activities, terminals: terminals)
    }

    func isRemovedFromContinueWatching(mediaID: String) -> Bool {
        guard let key = ApplePlaybackIdentity.storageKey(for: mediaID) else { return false }
        return Self.isRemoved(keys: aliases.members(of: key), entries: entries, activities: activities, terminals: terminals)
    }

    /// `terminals` is only read for a title with aliases (`keys.count > 1`):
    /// rebuilding it is the costly part of a read, so the store skips it.
    static func progress(keys: [String], entries: [String: ApplePlaybackProgress],
                         terminals: [String: ApplePlaybackTerminalEvents]) -> ApplePlaybackProgress? {
        guard let progress = AppleIdentityAliasResolution.progress(keys: keys, in: entries) else { return nil }
        if keys.count > 1 {
            let terminal = AppleIdentityAliasResolution.terminals(keys: keys, in: terminals)
            if let completion = terminal?.completedAt, completion >= (terminal?.resetAt ?? .distantPast), progress.updatedAt <= completion { return nil }
            if progress.isComplete, let reset = terminal?.resetAt, progress.updatedAt <= reset { return nil }
        }
        return progress
    }

    static func lastActivity(key: String, keys: [String], entries: [String: ApplePlaybackProgress],
                             activities: [String: ApplePlaybackProgress],
                             terminals allTerminals: [String: ApplePlaybackTerminalEvents]) -> ApplePlaybackProgress? {
        let saved = AppleIdentityAliasResolution.progress(keys: keys, in: entries)
        let activity = AppleIdentityAliasResolution.progress(keys: keys, in: activities).map { value in saved.map { ApplePlaybackConvergence.freshest(value, $0) } ?? value } ?? saved
        guard let activity else { return nil }
        var relevant: [String: ApplePlaybackTerminalEvents] = [:]
        for needed in [key] + ApplePlaybackConvergence.eventKeys(key, activity) {
            relevant[needed] = allTerminals[needed]
        }
        relevant[key] = AppleIdentityAliasResolution.terminals(keys: keys, in: allTerminals)
        guard ApplePlaybackConvergence.activityIsCurrent(key: key, value: activity, terminals: relevant) else { return nil }
        return activity
    }

    static func isRemoved(keys: [String], entries: [String: ApplePlaybackProgress],
                          activities: [String: ApplePlaybackProgress],
                          terminals: [String: ApplePlaybackTerminalEvents]) -> Bool {
        let terminal = AppleIdentityAliasResolution.terminals(keys: keys, in: terminals)
        return AppleContinueWatchingRemovalPolicy.isRemoved(
            removedAt: terminal?.removedAt,
            lastPlayedAt: (keys.flatMap { [activities[$0]?.updatedAt, entries[$0]?.updatedAt] } + [terminal?.playedAt]).compactMap { $0 }.max())
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
              let identity = AppleMediaIdentifier.episodeIdentity(mediaID) else { return false }
        return seeds.contains("\(identity.season):\(identity.episode)")
    }
}
#endif
