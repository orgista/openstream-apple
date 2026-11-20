import Foundation

/// Logical delivery state only. Credentials and server URLs are resolved from
/// the source store at delivery time, including after a relaunch.
@MainActor
final class AppleRemoteProgressOutbox {
    enum Event: String, Codable, Sendable { case started, progress, paused, stopped, scrobble }
    struct Entry: Codable, Equatable, Sendable {
        var id = UUID()
        let sourceID: UUID
        let itemID: String
        let playbackID: UUID
        let kind: AppleMediaServerKind
        let mediaSourceID: String
        let playSessionID: String?
        let event: Event
        let position: Double
        let duration: Double
        let targetPlayCount: Int?
        var observedPlayCount: Int? = nil
        var attempts = 0
        var nextAttemptAt = Date.distantPast
    }

    private let blobs: ApplePlaybackBlobStorage
    private let key = "openstream.remote-progress.outbox.v1"
    private(set) var entries: [Entry]
    private var completionTargets: [String: Int]
    private struct State: Codable {
        var entries: [Entry]
        var completionTargets: [String: Int]
    }
    private var inFlightID: UUID?
    private(set) var isDelivering = false

    init(defaults: UserDefaults = .standard, blobDirectory: URL? = nil) {
        blobs = ApplePlaybackBlobStorage.storage(defaults: defaults, directory: blobDirectory)
        let state = blobs.data(forKey: key).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
        entries = state?.entries ?? []
        completionTargets = state?.completionTargets ?? [:]
    }

    func enqueue(_ entry: Entry) { enqueue([entry]) }

    func enqueue(_ batch: [Entry]) {
        for entry in batch { append(entry) }
        persist()
    }

    private func append(_ entry: Entry) {
        guard entry.position.isFinite, entry.duration.isFinite else { return }
        if let target = entry.targetPlayCount {
            let key = AppleMediaServerItemReference(sourceID: entry.sourceID, itemID: entry.itemID).mediaID
            completionTargets[key] = max(target, completionTargets[key] ?? 0)
        }
        if entry.event == .progress || entry.event == .paused,
           let index = entries.lastIndex(where: { $0.playbackID == entry.playbackID && $0.sourceID == entry.sourceID && $0.itemID == entry.itemID }),
           entries[index].id != inFlightID,
           entries[index].event == .progress || entries[index].event == .paused {
            let last = entries[index]
            // Keep the retry deadline when a newer tick replaces a failed one.
            var replacement = entry
            replacement.attempts = last.attempts
            replacement.nextAttemptAt = last.nextAttemptAt
            entries[index] = replacement
        } else {
            entries.append(entry)
        }
    }

    func checkpointPlayCount(entryID: UUID, count: Int) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        entries[index].observedPlayCount = count
        persist()
    }

    func remove(sourceID: UUID) {
        entries.removeAll { $0.sourceID == sourceID }
        let prefix = "ms:\(sourceID.uuidString.lowercased()):"
        completionTargets = completionTargets.filter { !$0.key.hasPrefix(prefix) }
        persist()
    }

    func retainSources(_ sourceIDs: Set<UUID>) {
        entries.removeAll { !sourceIDs.contains($0.sourceID) }
        completionTargets = completionTargets.filter { key, _ in
            AppleMediaServerItemReference.parse(key).map { sourceIDs.contains($0.sourceID) } ?? false
        }
        persist()
    }

    func highestCompletionTarget(for reference: AppleMediaServerItemReference) -> Int {
        completionTargets[reference.mediaID] ?? 0
    }

    func nextAttemptAt(availableSources: Set<UUID>) -> Date? {
        var seen: Set<UUID> = []
        return entries.filter { availableSources.contains($0.sourceID) && seen.insert($0.sourceID).inserted }
            .map(\.nextAttemptAt).min()
    }

    /// One serial delivery per source; a failed final state blocks later
    /// episodes on that source. Other sources can continue independently.
    func drain(now: Date = .now, availableSources: Set<UUID>? = nil,
               send: @MainActor (Entry) async throws -> Void) async {
        guard !isDelivering else { return }
        isDelivering = true
        defer { isDelivering = false; inFlightID = nil }
        var blocked: Set<UUID> = []
        var delivered = 0
        while delivered < 32, !Task.isCancelled {
            var seen = blocked
            let candidate = entries.first { entry in
                guard seen.insert(entry.sourceID).inserted else { return false }
                return entry.nextAttemptAt <= now && (availableSources?.contains(entry.sourceID) ?? true)
            }
            guard let candidate else { return }
            inFlightID = candidate.id
            do {
                try await send(candidate)
                entries.removeAll { $0.id == candidate.id }
                delivered += 1
            } catch {
                if let index = entries.firstIndex(where: { $0.id == candidate.id }) {
                    if !(error is CancellationError) {
                        entries[index].attempts = min(entries[index].attempts + 1, 8)
                        let delay = min(pow(2, Double(entries[index].attempts)), 300)
                        entries[index].nextAttemptAt = now.addingTimeInterval(delay)
                    }
                }
                blocked.insert(candidate.sourceID)
            }
            inFlightID = nil
            persist()
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(State(entries: entries, completionTargets: completionTargets)) { blobs.set(data, forKey: key) }
    }
}
