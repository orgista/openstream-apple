import Foundation

/// A title page or the player is opening: background server work waits.
///
/// On the owner's Apple TV, a title opened while media-server rows were
/// loading took 870–1100 ms to its first frame instead of ~280 ms
/// (scan-1107). Row loading checks `waitUntilQuiet()` before each new request;
/// a request already on the wire finishes. A hold always ends by itself, so a
/// page that never reports back cannot stop the rows for good.
@MainActor
enum AppleForegroundOpening {
    static let titleHold: Duration = .seconds(3)
    static let playerHold: Duration = .seconds(5)

    private static var quietAt: ContinuousClock.Instant?
    private static var expiry: Task<Void, Never>?
    private static var waiters: [CheckedContinuation<Void, Never>] = []

    static var isOpening: Bool { quietAt.map { ContinuousClock.now < $0 } ?? false }

    static func hold(for duration: Duration) {
        let end = ContinuousClock.now + duration
        if let quietAt, quietAt >= end { return }
        quietAt = end
        expiry?.cancel()
        expiry = Task {
            try? await Task.sleep(until: end, clock: .continuous)
            guard !Task.isCancelled else { return }
            release()
        }
    }

    static func release() {
        quietAt = nil
        expiry?.cancel()
        expiry = nil
        let resumed = waiters
        waiters.removeAll()
        for waiter in resumed { waiter.resume() }
    }

    static func waitUntilQuiet() async {
        guard isOpening else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
