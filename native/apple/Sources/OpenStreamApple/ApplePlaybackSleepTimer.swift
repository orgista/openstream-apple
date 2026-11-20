import Foundation
import Observation

@MainActor @Observable
public final class ApplePlaybackSleepTimer {
    public private(set) var deadline: Date?
    public var stillWatching = false
    private var expiry: (@MainActor () -> Void)?
    private var task: Task<Void, Never>?

    public init() {}

    public func arm(minutes: Int, now: Date = .now, onExpiry: @escaping @MainActor () -> Void) {
        arm(deadline: AppleSleepTimerPolicy.deadline(minutes: minutes, now: now), now: now, onExpiry: onExpiry)
    }

    public func arm(deadline: Date?, now: Date = .now, onExpiry: @escaping @MainActor () -> Void) {
        cancel()
        guard let deadline, deadline > now else { return }
        self.deadline = deadline
        expiry = onExpiry
        task = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(deadline.timeIntervalSince(now))) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.expireIfNeeded()
        }
    }

    public func expireIfNeeded(now: Date = .now) {
        guard let deadline, now >= deadline else { return }
        let action = expiry
        cancel()
        stillWatching = true
        action?()
    }

    public func cancel() {
        task?.cancel()
        task = nil
        deadline = nil
        expiry = nil
        stillWatching = false
    }

    isolated deinit { task?.cancel() }
}
