struct AppleArtworkRequestQueue {
    enum Priority: Int, Sendable, Comparable {
        case prefetch
        case visible
        /// Title-page and hero art: first in line and never held back by a
        /// concurrency cap, so row prefetch cannot delay what is on screen.
        case foreground

        static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private struct Entry {
        let key: String
        var priority: Priority
    }

    private var entries: [Entry] = []

    mutating func enqueue(_ key: String, priority: Priority) {
        if let index = entries.firstIndex(where: { $0.key == key }) {
            if priority > entries[index].priority { entries[index].priority = priority }
        } else {
            entries.append(Entry(key: key, priority: priority))
        }
    }

    /// The oldest entry of the highest priority allowed to start now.
    mutating func next(prefetchAllowed: Bool, visibleAllowed: Bool = true) -> String? {
        let index = entries.firstIndex { $0.priority == .foreground }
            ?? (visibleAllowed ? entries.firstIndex { $0.priority == .visible } : nil)
            ?? (prefetchAllowed && visibleAllowed ? entries.indices.first : nil)
        guard let index else { return nil }
        return entries.remove(at: index).key
    }

    mutating func cancel(_ key: String) {
        entries.removeAll { $0.key == key }
    }
}
