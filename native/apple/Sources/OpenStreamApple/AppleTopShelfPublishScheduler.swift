import Foundation

@MainActor
final class AppleTopShelfPublishScheduler {
    static let debounceInterval: Duration = .seconds(5)
    private let clock: any AppleClock
    private var pending: Task<Void, Never>?
    private var triggers: Set<String> = []

    init(clock: any AppleClock = AppleSystemClock()) {
        self.clock = clock
    }

    @discardableResult
    func schedule(_ trigger: String, immediately: Bool = false, delay: Duration = debounceInterval,
                  publish: @escaping @MainActor ([String]) async -> Void) -> Task<Void, Never> {
        pending?.cancel()
        triggers.insert(trigger)
        let deadline = clock.now.advanced(by: max(Self.debounceInterval, delay))
        let work = Task {
            if !immediately {
                do { try await clock.sleep(until: deadline) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            let reasons = triggers.sorted()
            triggers.removeAll()
            await publish(reasons)
        }
        pending = work
        return work
    }
}
