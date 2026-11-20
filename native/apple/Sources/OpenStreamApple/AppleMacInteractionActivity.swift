#if os(macOS)
import Foundation

struct AppleMacInteractionActivity: Equatable, Sendable {
    static let holdInterval: TimeInterval = 3
    private(set) var expiresAt: Date?

    var isActive: Bool { expiresAt != nil }

    mutating func record(at now: Date) {
        expiresAt = now.addingTimeInterval(Self.holdInterval)
    }

    mutating func expire(deadline: Date) {
        guard expiresAt == deadline else { return }
        expiresAt = nil
    }
}
#endif
