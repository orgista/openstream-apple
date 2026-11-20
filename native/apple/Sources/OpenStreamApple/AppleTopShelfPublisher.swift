import Foundation
import OSLog

/// Updates the shared system-surface snapshot when its published content changes.
@MainActor
public final class AppleTopShelfPublisher {
    public static let shared = AppleTopShelfPublisher()
    private static let logger = Logger(subsystem: "com.orgista.openstream.topshelf", category: "publisher")
    private static let playbackBatchSize = 32

    nonisolated static func supportsPublishing(on platform: AppleUIPlatform) -> Bool {
        platform == .tvOS || platform == .iOS
    }

    /// Private titles (files, shares) may reach the Apple TV Top Shelf, seen
    /// only inside the app's own row on the TV. The same snapshot feeds the
    /// iPhone and iPad widgets, on the Home and Lock Screen, so not there.
    nonisolated public static var privateTitlesAllowed: Bool {
        #if os(tvOS)
        true
        #else
        false
        #endif
    }

    private let writer: AppleTopShelfSnapshotWriter
    private let platform: AppleUIPlatform

    public convenience init(writer: AppleTopShelfSnapshotWriter = .shared) {
        self.init(writer: writer, platform: .current)
    }

    init(writer: AppleTopShelfSnapshotWriter, platform: AppleUIPlatform) {
        self.writer = writer
        self.platform = platform
    }

    /// The writer rejects unchanged inputs before artwork or trailer work.
    ///
    /// `sources` decide which Continue Watching titles can open, exactly as
    /// Discover's row decides it, and playback progress supplies the
    /// most-recent-first order (N52).
    ///
    /// `libraryContinueWatching` is Discover's own row for files and shares
    /// (`AppleDiscoverView.localContinueWatching`): those records stay out of
    /// system search, so the index alone never put a NAS title on the shelf.
    /// They are private, so they go out only where `privateTitlesAllowed`.
    @discardableResult
    public func publish(
        records: [AppleMediaRecord],
        sources: [AppleSource],
        libraryContinueWatching: [AppleMediaRecord] = [],
        privateTitlesAllowed: Bool = AppleTopShelfPublisher.privateTitlesAllowed,
        heroes: [AppleTopShelfHero] = [],
        enabled: Bool,
        playbackStore: ApplePlaybackStore = ApplePlaybackStore()
    ) async -> Bool {
        guard Self.supportsPublishing(on: platform) else { return false }
        // Match the writer's eligibility gate before resolving playback across the full index.
        let indexed = records.filter { !$0.availability.isEmpty && !$0.isPrivate }
        let indexedIDs = Set(indexed.map(\.id))
        let library = libraryContinueWatching.filter {
            !$0.availability.isEmpty && !indexedIDs.contains($0.id) && (privateTitlesAllowed || !$0.isPrivate)
        }
        let records = indexed + library
        let episodesByKey = await playbackStore.availableEpisodes()
        guard !Task.isCancelled else { return false }
        let reads = await Self.playbackReads(records, state: playbackStore.readState())
        guard !Task.isCancelled else { return false }
        var successorAvailable = Set<String>()
        let completionProgress = playbackStore.completionProgress()
        let series = records.filter { $0.kind == .series }
        for (index, record) in series.enumerated() {
            // Completion reads need the main actor; let keyboard events run between batches.
            if index.isMultiple(of: Self.playbackBatchSize) {
                await Task.yield()
                guard !Task.isCancelled else { return false }
            }
            guard let key = ApplePlaybackIdentity.storageKey(for: record.id),
                  let episodes = episodesByKey[key], !episodes.isEmpty else { continue }
            if AppleCompletionPolicy.successor(after: reads.activity[record.id]?.partID, episodes: episodes,
                completedIDs: playbackStore.completedMediaIDs(among: episodes.map(\.id), progress: completionProgress)) != nil {
                successorAvailable.insert(record.id)
            }
        }
        guard !Task.isCancelled else { return false }
        let live = AppleLiveSystemChannels.shared
        let sourceIDs = Set(sources.filter { $0.kind == .liveTV && $0.isEnabled }.map(\.id))
        let favorites = AppleLiveSystemChannels.supported(live.favorites, sourceIDs: sourceIDs)
        let recents = AppleLiveSystemChannels.supported(live.recents, sourceIDs: sourceIDs)
        do {
            return try await writer.write(records: indexed, sources: sources, libraryContinueWatching: library,
                                   watchedAt: reads.saved.mapValues(\.updatedAt), savedProgress: reads.saved,
                                   activity: reads.activity, successorAvailable: successorAvailable, removedAt: reads.removals,
                                   favoriteChannels: favorites, recentChannels: recents, heroes: heroes, enabled: enabled)
        } catch is CancellationError {
            // A newer publish replaced this one.
        } catch {
            let failure: String
            if error is AppleTopShelfSnapshotWriter.WriteError {
                failure = "Top Shelf snapshot publish failed: no app-group container"
            } else {
                // Error descriptions can include paths or payloads; codes are enough to diagnose I/O.
                let error = error as NSError
                failure = "Top Shelf snapshot \(enabled ? "write" : "removal") failed: \(error.domain) code=\(error.code)"
            }
            AppleInteractionTrace.record(.failure, failure)
            Self.logger.error("\(failure, privacy: .public)")
        }
        return false
    }

    struct PlaybackReads: Sendable {
        var saved: [String: ApplePlaybackProgress] = [:]
        var activity: [String: ApplePlaybackProgress] = [:]
        var removals: [String: Date] = [:]
    }

    /// Every record's saved position, last activity and removal, off the
    /// main actor: the index can hold thousands of records.
    @concurrent nonisolated static func playbackReads(_ records: [AppleMediaRecord],
                                                      state: ApplePlaybackReadState) async -> PlaybackReads {
        var reads = PlaybackReads()
        for record in records {
            if Task.isCancelled { break }
            reads.activity[record.id] = state.lastActivity(for: record.id)
            if state.isRemovedFromContinueWatching(mediaID: record.id) { reads.removals[record.id] = .distantFuture }
            reads.saved[record.id] = state.progress(for: record.id)
        }
        return reads
    }
}
