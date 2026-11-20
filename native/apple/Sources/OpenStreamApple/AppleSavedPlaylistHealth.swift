import Foundation

struct AppleSavedPlaylistHealth: Codable, Equatable, Sendable {
    var failureCount = 0
    var requiresAttention = false
    let firstFailedAt: Date
    var storedAt: Date

    mutating func recordFailure(at now: Date, authenticationFailed: Bool) {
        failureCount = min(3, failureCount + 1)
        requiresAttention = requiresAttention || authenticationFailed || failureCount >= 3
            || now.timeIntervalSince(firstFailedAt) >= 24 * 60 * 60
    }

    var summary: String {
        "Showing saved channels · last updated \(storedAt.formatted(date: .abbreviated, time: .shortened))"
    }
}
