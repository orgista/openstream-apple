import Foundation
import Observation

/// In-memory cooldown shared by title pages and player sessions. URLs never go to logs or disk.
@MainActor
@Observable
public final class ApplePlaybackFailureHistory {
    public static let shared = ApplePlaybackFailureHistory()
    private var failures: [URL: Date] = [:]
    public init() {}

    public func record(_ url: URL, now: Date = Date()) {
        failures = failures.filter { now.timeIntervalSince($0.value) < 600 }
        failures[url] = now
    }

    public func contains(_ url: URL, now: Date = Date()) -> Bool {
        guard let failed = failures[url] else { return false }
        return now.timeIntervalSince(failed) < 600
    }
}
