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

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func progress(for mediaID: String) -> ApplePlaybackProgress? {
        guard let storageKey = ApplePlaybackIdentity.storageKey(for: mediaID) else { return nil }
        return entries()[storageKey]
    }

    public func progress(for url: URL) -> ApplePlaybackProgress? {
        entries()[ApplePlaybackIdentity.storageKey(for: url)]
    }

    public func save(mediaID: String, position: Double, duration: Double, partID: String? = nil) {
        guard let storageKey = ApplePlaybackIdentity.storageKey(for: mediaID) else { return }
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
        let progress = ApplePlaybackProgress(position: min(position, duration), duration: duration, partID: partID)
        if progress.isComplete {
            current.removeValue(forKey: storageKey)
        } else {
            current[storageKey] = progress
        }
        persist(current)
    }

    private func clear(storageKey: String) {
        var current = entries()
        current.removeValue(forKey: storageKey)
        persist(current)
    }

    private func entries() -> [String: ApplePlaybackProgress] {
        if let cache { return cache }
        let loaded: [String: ApplePlaybackProgress]
        if let data = defaults.data(forKey: key) {
            let decoded = (try? JSONDecoder().decode([String: ApplePlaybackProgress].self, from: data)) ?? [:]
            var normalized: [String: ApplePlaybackProgress] = [:]
            for (mediaID, progress) in decoded {
                if let storageKey = ApplePlaybackIdentity.storageKey(for: mediaID) {
                    normalized[storageKey] = progress
                }
            }
            loaded = normalized
            if loaded.keys.sorted() != decoded.keys.sorted() {
                defaults.set(try? JSONEncoder().encode(loaded), forKey: key)
            }
        } else {
            loaded = [:]
        }
        cache = loaded
        return loaded
    }

    private func persist(_ entries: [String: ApplePlaybackProgress]) {
        cache = entries
        defaults.set(try? JSONEncoder().encode(entries), forKey: key)
    }
}
