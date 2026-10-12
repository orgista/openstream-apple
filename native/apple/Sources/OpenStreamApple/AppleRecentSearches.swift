import Foundation

/// The last few things typed into Search, newest first, kept on this device
/// only (not synced, not in a backup: a search is not configuration).
///
/// Shown under "Recent Searches" while the field is empty, the way the TV app
/// and the App Store do it, with one "Clear Recent Searches" row.
public enum AppleRecentSearchPolicy {
    public static let limit = 10
    /// Shorter than this is a keystroke, not a search.
    public static let minimumLength = 2

    /// `query` cleaned for storage: trimmed, inner runs of whitespace
    /// collapsed; `nil` when there is nothing worth keeping.
    public static func normalized(_ query: String) -> String? {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        let value = String(words.joined(separator: " ").prefix(120))
        return value.count >= minimumLength ? value : nil
    }

    /// `recents` with `query` moved to the front. A previous entry that is the
    /// same text (case-folded) or a prefix of it — "mat", "matr" from the
    /// debounce while "matrix" was being typed — is dropped, so the list
    /// holds searches, not keystrokes. Never more than `limit` entries.
    public static func recording(_ query: String, in recents: [String]) -> [String] {
        guard let value = normalized(query) else { return recents }
        let key = value.lowercased()
        var result = recents.filter { entry in
            let existing = entry.lowercased()
            return existing != key && !key.hasPrefix(existing)
        }
        result.insert(value, at: 0)
        return Array(result.prefix(limit))
    }
}

/// `UserDefaults`-backed recents for the Search page.
@MainActor
@Observable
public final class AppleRecentSearchStore {
    public static let storageKey = "openstream.search.recent.v1"
    private let defaults: UserDefaults
    public private(set) var recents: [String]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        recents = (defaults.stringArray(forKey: Self.storageKey) ?? []).prefix(AppleRecentSearchPolicy.limit).map { $0 }
    }

    public func record(_ query: String) {
        let next = AppleRecentSearchPolicy.recording(query, in: recents)
        guard next != recents else { return }
        recents = next
        defaults.set(next, forKey: Self.storageKey)
    }

    public func clear() {
        guard !recents.isEmpty else { return }
        recents = []
        defaults.removeObject(forKey: Self.storageKey)
    }
}
